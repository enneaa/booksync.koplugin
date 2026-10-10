-- cloudapi.lua — provider-agnostic cloud access.
--
-- Two problems this solves:
--
-- 1. KOReader moved its cloud backends. Up to 2024.x they lived at
--      apps/cloudstorage/webdavapi   / apps/cloudstorage/dropboxapi
--    and were called with explicit credentials:
--      api:downloadFile(url, user, pass, local_path, cb)
--    From 2024.x they live at
--      plugins/cloudstorage.koplugin/providers/webdav / dropbox
--    with a different convention that reads credentials from the module's own
--    configured "base" and does not export getJoinedPath or getAccessToken at
--    all. The plugin only knew the old paths, so on a current KOReader every
--    sync silently reported "Unsupported cloud service".
--
-- 2. The plugin supports a *separate* book cloud with its own address/credentials.
--    The modern modules cannot express that (they always use their own base), so
--    for WebDAV we talk to the server directly over socket.http. That also
--    removes the dependency on KOReader's private API entirely.
--
-- Everything here returns a plain HTTP status number, or nil when the call
-- itself failed. Nothing throws: callers treat nil as "failed" and fall through
-- to their own error reporting.

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = package.loaded["booksync.gettext_shim"]
if not _ then
    local dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")
    _ = dofile(dir .. "gettext_shim.lua")
    package.loaded["booksync.gettext_shim"] = _
end

local M = {}

-- Every raw socket call goes through this. socket.http raises on DNS failure,
-- connection refused, timeout and malformed URLs -- all routine on a mobile
-- network, and all fatal if they escape into UIManager's event loop.
--
-- Returns the function's full result list. An earlier single-value version of
-- this helper silently dropped the response headers, which is where the WebDAV
-- "Link: ...; mk=<cursor>" paging header lives -- so paged listings stopped
-- after the first 750 entries no matter what the server said.
-- cloudapi.lua is deliberately self-contained: it has no dofile-based module
-- loader, because it is also reached from code paths that load it directly.
-- utils is always in package.loaded by the time any cloud call happens (main.lua
-- loads it first), so look it up rather than dofile-ing a second copy, which
-- would be a different table with different state.
local function report_crash(what, err)
    local u = package.loaded["booksync.utils"]
    if u and type(u.log_crash) == "function" then
        u.log_crash("cloudapi " .. tostring(what), err)
    else
        pcall(function()
            logger.err("booksync: cloudapi " .. tostring(what) .. " failed: " .. tostring(err)
                .. "\n" .. debug.traceback("", 2))
        end)
    end
end

local function guarded(what, fn, ...)
    local results, n
    local ok, err = pcall(function(...)
        local function collect(...)
            n = select("#", ...)
            return ...
        end
        results = { collect(fn(...)) }
    end, ...)
    if not ok then
        report_crash(what, err)
        return nil
    end
    -- results may have lost trailing nils during construction, so trust the
    -- count select() gave us rather than #results.
    local unpack_ = table.unpack or unpack
    return unpack_(results, 1, n)
end
M.guarded = guarded

--------------------------------------------------------------------- path join
-- Mirrors WebDavAPI.getJoinedPath: collapse duplicate/trailing slashes.
--
-- The scheme must survive: a naive gsub("//+", "/") turns
-- "https://host" into "https:/host" and every request then fails to resolve.
function M.join(parent, child)
    parent = tostring(parent or "")
    child = tostring(child or "")
    if child == "" then
        return (parent:gsub("/+$", ""))
    end
    if parent == "" then
        return child
    end
    local scheme = parent:match("^(%a[%w+.-]*://)") or ""
    local rest = parent:sub(#scheme + 1)
    rest = rest:gsub("/+$", "") .. "/" .. child:gsub("^/+", "")
    rest = rest:gsub("/+", "/")
    return scheme .. rest
end

------------------------------------------------------------------- WebDAV (native)
-- Native WebDAV client. Works against any address/user/pass, which the modern
-- KOReader modules cannot do.
local WebDav = {}
WebDav.__index = WebDav

local function new_webdav(server)
    return setmetatable({
        address = tostring(server.address or ""):gsub("/+$", ""),
        user = server.username,
        pass = server.password,
    }, WebDav)
end

function WebDav:url(cloud_path)
    local util = require("util")
    local p = tostring(cloud_path or "")

    -- Callers hand us EITHER an absolute URL ("https://host/a/b.epub", which
    -- is what remote.get_cloud_path builds) OR a path relative to
    -- self.address ("Books/b.epub", which is what list() is called with).
    --
    -- Treating the absolute form as relative pasted it onto the address and
    -- encoded it, producing
    --   https://host/https%3A%2F%2Fhost%2F...%E4%B9%A6.epub
    -- which every WebDAV server answers with 400 Bad Request. Listing kept
    -- working, so the connection check passed while every single transfer
    -- failed. Detect the absolute form and encode only its path.
    local scheme, rest = p:match("^(https?://)(.*)$")
    if scheme then
        local authority, path = rest:match("^([^/]*)(/.*)$")
        if not authority then
            return scheme .. rest
        end
        path = path:gsub("^/+", ""):gsub("/+$", "")
        if path == "" then
            return scheme .. authority .. "/"
        end
        return scheme .. authority .. "/" .. util.urlEncode(path, "/")
    end

    -- Relative form: callers may or may not use a leading slash, and the
    -- address may or may not carry a trailing slash. Concatenating naively
    -- produced "https://host//books/a.epub", which some WebDAV servers treat
    -- as a different (empty) first path segment.
    local path = p:gsub("^/+", "")
    local base = self.address
    if path == "" then
        if base:sub(-1) ~= "/" then
            base = base .. "/"
        end
        return base
    end
    return base .. "/" .. util.urlEncode(path, "/")
end

function WebDav:list(cloud_path, include_folders)
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local util = require("util")
    local ffiUtil = require("ffi/util")
    local datetime = require("datetime")
    local DocumentRegistry = require("document/documentregistry")

    local body = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop>]]
        -- getetag is what makes a conditional upload possible: If-Match
        -- against a stale etag answers 412, which is how we find out another
        -- device wrote to the same file since we last looked. This is the same
        -- mechanism KOReader's own WebDAV provider uses, so it needs nothing
        -- from the server that a plain PUT does not.
        .. [[<a:resourcetype/><a:getcontentlength/><a:getlastmodified/><a:getetag/>]]
        .. [[</a:prop></a:propfind>]]
    local show_unsupported = G_reader_settings:isTrue("show_unsupported")

    local path = tostring(cloud_path or ""):gsub("^/+", ""):gsub("/+$", "")
    local base_url = self:url(path)
    if base_url:sub(-1) ~= "/" then
        base_url = base_url .. "/"
    end
    -- Compare the "is this me?" href against our own path in the same shape.
    -- hrefs come back with a leading slash ("/books/") while the request path
    -- does not ("books"), so a raw comparison never matched and the folder
    -- being listed showed up in its own results.
    local function norm(p)
        return (tostring(p or ""):gsub("^/+", ""):gsub("/+$", ""))
    end
    local self_path = norm(base_url:match("^https?://[^/]*(.*)$") or base_url)
    local request_path = path

    local items = {}
    local next_mk = nil
    local page = 0

    repeat
        page = page + 1
        if page > 50 then break end   -- hard cap; a misbehaving server must not loop forever

        local request_url = base_url .. (next_mk and ("?mk=" .. next_mk) or "")
        local sink = {}

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, headers = guarded("webdav list", function()
            return socket.skip(1, http.request {
                url      = request_url,
                method   = "PROPFIND",
                headers  = {
                    ["Content-Type"]   = "application/xml",
                    ["Depth"]          = "1",
                    ["Content-Length"] = #body,
                },
                source   = ltn12.source.string(body),
                sink     = ltn12.sink.table(sink),
                user     = self.user,
                password = self.pass,
            })
        end)
        socketutil:reset_timeout()

        if not code or code < 200 or code > 299 then
            -- Distinguish "the request blew up / was rejected" from "this
            -- directory really is empty": callers must be able to tell them
            -- apart, otherwise a failed listing silently looks like success
            -- with zero books.
            if not code then
                return nil
            end
            break
        end

        for item in table.concat(sink):gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
            local href = item:match("<[^:]*:href[^>]*>(.*)</[^:]*:href>")
            if href then
                local full = util.urlDecode(href)
                local name = ffiUtil.basename(util.htmlEntitiesToUtf8(full))
                local is_collection = item:find("<[^:]*:collection[%s/>]") ~= nil
                    or item:find("<[^:]*:resourcetype>%s*<[^:]*:collection") ~= nil
                local is_plain = item:find("<[^:]*:resourcetype%s*/>") ~= nil
                    or item:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>") ~= nil

                if is_plain and name ~= "" and not is_collection then
                    if show_unsupported or DocumentRegistry:hasProvider(name) then
                        local etag
                        do
                            -- <D:getetag>"abc"</D:getetag> -- the quotes are
                            -- part of the value and If-Match wants them.
                            local raw = item:match(
                                "<[^:]*:getetag[^>]*>(.-)</[^:]*:getetag>")
                            if raw then
                                raw = util.htmlEntitiesToUtf8(raw):gsub("^%s+", ""):gsub("%s+$", "")
                                if raw ~= "" and raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
                                    etag = raw
                                end
                            end
                        end
                        table.insert(items, {
                            is_file = true,
                            text = name,
                            url = request_path .. "/" .. name,
                            filesize = tonumber(item:match(
                                "<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")),
                            etag = etag,
                        })
                    end
                elseif is_collection and include_folders then
                    if norm(full) ~= self_path then
                        table.insert(items, {
                            is_folder = true,
                            text = name .. "/",
                            url = request_path .. "/" .. name,
                        })
                    end
                end
            end
        end

        next_mk = nil
        if headers then
            local link = headers.link or headers.Link
            if link then
                next_mk = link:match("mk=([^>&]+)")
            end
        end
    until not next_mk

    return items
end

-- A transfer can report success and still leave nothing usable on disk: a
-- 200 carrying an empty body, an error page served with 200, or a connection
-- cut after the last full buffer. Any of those used to be recorded as a
-- successful download, and because the next run sees the file exists it skips
-- the book forever. Verify the bytes actually landed, and throw the file away
-- if they did not.
local function file_size(path)
    -- one stat, not two: the old form asked for "size", then re-asked with no
    -- field when the first came back nil, on a path called once per downloaded
    -- file.
    local lfs = require("libs/libkoreader-lfs")
    local a = lfs.attributes(path)
    if type(a) == "table" then return tonumber(a.size) or 0 end
    return tonumber(a) or 0
end

local function finish_download(local_path, code, expected_size)
    local written = file_size(local_path)

    if code ~= 200 then
        pcall(os.remove, local_path)
        return code
    end
    if written <= 0 then
        logger.err("booksync: download reported success but wrote 0 bytes: " .. tostring(local_path))
        pcall(os.remove, local_path)
        return nil
    end
    -- A size mismatch is NOT a failure. The listing's size comes from
    -- <getcontentlength> in a PROPFIND, and servers, proxies and
    -- compression can legitimately make that differ from the bytes a GET
    -- returns -- deleting a book that is 99% there because a hint disagreed
    -- is a much worse outcome than a slightly short file the user can
    -- inspect. Record it and move on.
    if type(expected_size) == "number" and expected_size > 0 and written < expected_size then
        logger.warn(string.format(
            "booksync: downloaded %d bytes but the cloud listing reported %d: %s",
            written, expected_size, tostring(local_path)))
    end
    return code
end

function WebDav:download(cloud_path, local_path, progress_callback, expected_size)
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")

    local f = io.open(local_path, "w")
    if not f then
        logger.err("booksync: cannot open " .. tostring(local_path) .. " for writing")
        return nil
    end
    local sink = ltn12.sink.file(f)
    if progress_callback then
        sink = socketutil.chainSinkWithProgressCallback(sink, progress_callback)
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = guarded("webdav download", function()
        return socket.skip(1, http.request {
            url      = self:url(cloud_path),
            method   = "GET",
            sink     = sink,
            user     = self.user,
            password = self.pass,
        })
    end)
    socketutil:reset_timeout()
    -- Do NOT close this unconditionally. LuaSocket's ltn12.sink.file() closes
    -- the handle itself when luasocket signals end-of-transfer by calling the
    -- sink with a nil chunk, so a second f:close() raises
    -- "attempt to use a closed file". That error escaped the download and the
    -- batch runner reported a FAILED download for bytes that were already on
    -- disk. Close defensively: a no-op if the sink got there first, but still
    -- closes the handle on paths where the sink never ran.
    pcall(function() f:close() end)

    return finish_download(local_path, code, expected_size)
end

-- expected_etag, when known, is sent as If-Match so a file another device has
-- changed since we read it comes back as 412 instead of being silently
-- overwritten. A nil etag (server did not report one, or this is a first
-- write) falls back to an unconditional PUT, exactly like before.
function WebDav:upload(cloud_path, local_path, expected_etag)
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local sha2 = require("ffi/sha2")

    local f = io.open(local_path, "r")
    if not f then
        return nil
    end
    local size = lfs.attributes(local_path, "size") or 0

    local headers = {
        ["User-Agent"]      = "KOReader-BookSync",
        ["Authorization"]   = "Basic " .. sha2.bin_to_base64(
            tostring(self.user) .. ":" .. tostring(self.pass)),
        ["Content-Length"]  = tostring(size),
    }
    -- NO If-None-Match. RFC 7232 3.2 requires a server to answer 412 when
    -- that header is present and the resource already exists, so it made every
    -- metadata upload after the first one fail -- and the cloud copy stayed
    -- frozen at whatever was uploaded the very first time, which is the worst
    -- possible state for a sync tool.
    --
    -- If-Match is the opposite question, and it is the one worth asking: "only
    -- overwrite if the file is still the one I read". A 412 means another
    -- device wrote in between, so the caller merges and retries instead of
    -- silently discarding that device's work. Same mechanism KOReader's own
    -- provider uses, so it needs no server support a plain PUT does not.
    if type(expected_etag) == "string" and expected_etag ~= "" then
        headers["If-Match"] = expected_etag
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = guarded("webdav upload", function()
        return socket.skip(1, http.request {
            url      = self:url(cloud_path),
            method   = "PUT",
            headers  = headers,
            source   = ltn12.source.file(f),
        })
    end)
    socketutil:reset_timeout()
    -- Same reasoning as WebDav:download -- never assume the handle is still open.
    pcall(function() f:close() end)

    return code
end

function WebDav:delete(cloud_path)
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local socket = require("socket")
    local sha2 = require("ffi/sha2")

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = guarded("webdav delete", function()
        return socket.skip(1, http.request {
            url      = self:url(cloud_path),
            method   = "DELETE",
            headers  = {
                ["User-Agent"]    = "KOReader-BookSync",
                ["Authorization"] = "Basic " .. sha2.bin_to_base64(
                    tostring(self.user) .. ":" .. tostring(self.pass)),
            },
        })
    end)
    socketutil:reset_timeout()
    return code
end

----------------------------------------------------------------- Dropbox (adapter)
local function dropbox_module()
    -- The provider ships with KOReader's cloudstorage plugin. Both spellings are
    -- tried because the plugin is loaded either as a plugin or as a bundled
    -- module depending on the build. The module takes its credentials from its
    -- own configured base, so this only works for a server KOReader manages.
    for _, name in ipairs({
        "plugins/cloudstorage.koplugin/providers/dropbox",
        "cloudstorage.koplugin.providers.dropbox",
    }) do
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" then
            return mod
        end
    end
    return nil
end

local Dropbox = {}
Dropbox.__index = Dropbox

local function new_dropbox(server)
    return setmetatable({
        server = server,
        token = server.password,
        mod = dropbox_module(),
    }, Dropbox)
end

function Dropbox:ensure_token()
    if self.token and self.token ~= "" then
        return self.token
    end
    if not (self.server.address and self.server.address ~= "") then
        return nil
    end
    -- getAccessToken is exported by the provider module, so a server configured
    -- outside KOReader (a custom app key) can still mint a token here.
    local mod = self.mod
    if type(mod.getAccessToken) == "function" then
        self.token = guarded("dropbox token", mod.getAccessToken,
            self.server.password, self.server.address)
    end
    return self.token
end

function Dropbox:url(cloud_path)
    local p = tostring(cloud_path or "")
    -- Same contract as WebDav:url. remote.get_cloud_path already returns
    -- server.url .. "/" .. filename for Dropbox, so prepending server.url again
    -- produced a doubled path (https://api/.../download/Books/Books/a.epub) and
    -- every transfer 404'd or 400'd.
    if p:match("^https?://") then
        return p
    end
    local base = tostring(self.server.url or "")
    if base:sub(-1) ~= "/" then
        base = base .. "/"
    end
    local child = p:gsub("^/+", "")
    if child == "" then
        return base
    end
    return base .. child
end

function Dropbox:upload(cloud_path, local_path)
    local mod = self.mod
    if not mod then return nil end
    local token = self:ensure_token()
    if not token then return nil end
    local code = guarded("dropbox upload", mod.uploadFile, mod,
        self:url(cloud_path), token, local_path, nil, true)
    if code == 200 or code == 201 then
        return code
    end
    -- Overwrite mode plus a cut connection leaves a partial object in the
    -- cloud. upload_book_if_missing() asks "does this name exist?" before every
    -- upload, so a leftover fragment would make every later attempt skip the
    -- book and report "already in cloud" -- the upload would never complete.
    pcall(function()
        logger.err("booksync: upload failed (" .. tostring(code) .. "), removing partial cloud object")
        self:delete(cloud_path)
    end)
    return code
end

function Dropbox:download(cloud_path, local_path, progress_callback, expected_size)
    local mod = self.mod
    if not mod then return nil end
    local token = self:ensure_token()
    if not token then return nil end
    local code = guarded("dropbox download", mod.downloadFile, mod,
        self:url(cloud_path), token, local_path, progress_callback)
    -- KOReader's own Dropbox provider leaves the truncated file behind on
    -- failure. That matters much more here: the next batch run would see the
    -- file exists and skip the book permanently.
    return finish_download(local_path, code, expected_size)
end

function Dropbox:delete(cloud_path)
    local mod = self.mod
    if not mod then return nil end
    local token = self:ensure_token()
    if not token then return nil end
    if type(mod.deleteFile) == "function" then
        return guarded("dropbox delete", mod.deleteFile, mod, self:url(cloud_path), token)
    end
    return nil
end

function Dropbox:list(cloud_path, include_folders)
    local mod = self.mod
    if not mod or type(mod.listFolder) ~= "function" then return nil end
    local token = self:ensure_token()
    if not token then return nil end
    return guarded("dropbox list", mod.listFolder, mod,
        tostring(self.server.url or ""), token, include_folders and true or false)
end

---------------------------------------------------------------------- factory
-- Returns a provider for `server`, or nil when the type is unsupported.
function M.get(server)
    if type(server) ~= "table" or type(server.type) ~= "string" then
        return nil
    end
    if server.type == "webdav" then
        if not (server.address and server.address ~= "") then return nil end
        return new_webdav(server)
    end
    if server.type == "dropbox" then
        if not dropbox_module() then return nil end
        return new_dropbox(server)
    end
    return nil
end


return M
