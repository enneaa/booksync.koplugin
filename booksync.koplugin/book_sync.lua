-- book_sync.lua
-- Book file cloud sync module

-- Get plugin directory
local src = debug.getinfo(1, "S").source or ""
local path = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
local _plugin_dir

if path then
    if path:sub(1, 1) ~= "/" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs and lfs.currentdir()
        if cwd then
            path = cwd .. "/" .. path
        end
    end
    _plugin_dir = path .. "/"
else
    _plugin_dir = "./"
end

-- Memoised module loader.
--
-- dofile() recompiles the target from source on every single call, and this
-- plugin reached for remote.lua / utils.lua / merge.lua from menu text_func
-- callbacks -- which run on every menu repaint. Building the settings menu
-- alone re-compiled ~8k lines of Lua each time it was opened, which is a very
-- visible stall on an e-ink Kindle. Cache under a namespaced package.loaded key
-- (namespaced so it can never collide with a KOReader core module) so each
-- module is compiled exactly once per session.
local function module(name)
    local key = "booksync." .. name
    local cached = package.loaded[key]
    if cached == nil then
        cached = dofile(_plugin_dir .. name .. ".lua")
        package.loaded[key] = cached
    end
    return cached
end

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Screen = Device.screen
local Input = Device.input
local DocumentRegistry = require("document/documentregistry")
local util = require("util")
local _ = module("gettext_shim")
local T = require("ffi/util").template
local utils = module("utils")
local notify = module("notify")

local DownloadDialog = utils.DownloadDialog

local M = {}

local function get_book_server()
    local json = require("json")
    local settings = G_reader_settings:readSetting("booksync_plugin") or {}
    local book_cloud_dir = settings.book_cloud_dir
    
    if book_cloud_dir and book_cloud_dir ~= "" then
        local server = {
            type = settings.book_cloud_type or "webdav",
            url = book_cloud_dir,
            address = settings.book_cloud_address,
            username = settings.book_cloud_username,
            password = settings.book_cloud_password,
        }
        if server.type == "webdav" and (not server.address or not server.username or not server.password) then
            return M.get_metadata_server()
        end
        if server.type == "dropbox" and not server.password then
            return M.get_metadata_server()
        end
        return server
    end
    
    return M.get_metadata_server()
end

-- Share remote.get_server() so a corrupt cloud_server_object blob is handled in
-- exactly one place. The local copy here called json.decode() bare, and KOReader's
-- json decoder raises on malformed input -- so a truncated setting crashed the
-- book-sync entry points instead of reporting "not configured".
function M.get_metadata_server()
    return module("remote").get_server()
end

-- Normalised provider adapter (see cloudapi.lua): hides the credential
-- difference *and* the fact that KOReader moved these modules in 2024.x.
local function get_api(server)
    return module("cloudapi").get(server)
end

-- The three cloud checks, in one place, for the book-cloud entry points.
-- get_book_server() falls back to the metadata server, so it can hand back a
-- server whose url is "" -- and get_cloud_path then builds a valid path against
-- the storage ROOT. Uploading a book file there is not a recoverable mistake.
--
-- This replaced two hand-rolled copies that had drifted from each other.
local function check_book_cloud_or_notify()
    local server = get_book_server()
    if not server then
        notify.hint(_("Set up cloud storage in settings"))
        return nil, nil
    end
    if type(server.url) ~= "string" or server.url == "" then
        notify.hint(_("Set the cloud folder in settings"))
        return nil, nil
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        notify.hint(_("Offline"))
        return nil, nil
    end
    local api = get_api(server)
    if not api then
        notify.hint(_("Only WebDAV and Dropbox are supported"))
        return nil, nil
    end
    return server, api
end

-- Parse an ISO-8601 timestamp (e.g. Dropbox "2023-01-01T12:00:00Z" or with
-- timezone offset) into a Unix timestamp (seconds since epoch). Returns nil on
-- failure so callers can fall back to "no time".
local function parse_iso8601(s)
    if type(s) ~= "string" or s == "" then return nil end
    local year, month, day, hour, min, sec = s:match(
        "(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if not year then return nil end
    local t = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    }
    -- os.time(t) interprets t as LOCAL time. Compute the local-to-UTC offset
    -- so we can convert the parsed fields (which may be in a different
    -- timezone) into a true UTC Unix timestamp.
    local now = os.time()
    local local_offset = now - os.time(os.date("!*t", now))

    -- Determine the timezone offset of the parsed string.
    local offset_secs = 0
    local sign, oh, om = s:match("([%+%-])(%d%d):(%d%d)$")
    if sign then
        offset_secs = tonumber(oh) * 3600 + tonumber(om) * 60
        if sign == "-" then offset_secs = -offset_secs end
    elseif not (s:sub(-1) == "Z" or s:sub(-1) == "z") then
        -- No suffix: assume local time, offset matches local_offset.
        offset_secs = local_offset
    end

    -- t is in timezone (offset_secs east of UTC). os.time(t) treats it as
    -- local. Correct back to UTC:
    local ts = os.time(t)
    if not ts then return nil end
    return ts + local_offset - offset_secs
end

-- Returns the document extension as KOReader sees it, preserving compound
-- extensions such as ".fb2.zip". getProviders() matches the full registered
-- suffix, so its top provider's extension is "fb2.zip" rather than the bare
-- "zip" (which is only a low-priority generic fallback). This keeps the
-- uploaded cloud filename openable as the right format in the title /
-- title_author naming modes. Falls back to the last dotted component for
-- anything KOReader doesn't recognize.
local function get_file_extension(file_path)
    local providers = DocumentRegistry:getProviders(file_path)
    if providers and providers[1] and providers[1].extension then
        return "." .. providers[1].extension
    end
    local ext = file_path:match("%.([^%.]+)$")
    return ext and ("." .. ext) or ""
end

-- Removes the extension (as understood by get_file_extension) from a filename,
-- keeping compound extensions intact so the stem and the extension never
-- overlap. Using a plain `gsub("%.[^%.]+$", "")` here would only drop the last
-- component, turning "book.fb2.zip" into the stem "book.fb2" which, recombined
-- with the compound ext ".fb2.zip", would yield "book.fb2.fb2.zip".
local function strip_extension(filename)
    local ext = get_file_extension(filename)
    if #ext > 0 and filename:sub(-#ext):lower() == ext:lower() then
        return filename:sub(1, #filename - #ext)
    end
    return filename
end

-- A file is a syncable book if KOReader has a document provider for it.
-- We use the same test KOReader's own FileManager uses to decide what to show
-- (hasProvider), instead of a hand-maintained extension allowlist. This
-- automatically covers every format the reader can open and stays in sync with
-- it. We then drop the two provider-backed file kinds that are clearly not
-- books: plain images (covers etc.) and the executable scripts (.sh/.py) that
-- CRE registers only for in-FileManager execution.
local function is_supported_book(file_path)
    return DocumentRegistry:hasProvider(file_path)
        and not DocumentRegistry:isImageFile(file_path)
        and util.getScriptType(file_path) == nil
end

local function get_cloud_path(server, cloud_filename)
    return module("remote").get_cloud_path(server, get_api(server), cloud_filename)
end

-- The cloud name for a book file is the name it already has on this device.
-- See naming.lua for why this is fixed rather than a setting.
function M.get_cloud_filename_for_path(book)
    return module("naming").book_name(book, get_file_extension(book.file_path))
end

function M.write_batch_book_log(results, action)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id(false)
    
    local action_text = ""
    if action == "upload" then
        action_text = _("Book sync") .. "-" .. _("Batch upload")
    elseif action == "download" then
        action_text = _("Book sync") .. "-" .. _("Batch download")
    else
        action_text = _("Book sync") .. "-" .. _("Batch delete")
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), action_text))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format(_("[Success] (%d books)"), #(results.success or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.success or {}) > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.name))
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    
    if results.skipped and #results.skipped > 0 then
        table.insert(new_record, string.format(_("[Skipped] (%d books)"), #results.skipped))
        table.insert(new_record, string.rep("-", 40))
        for _, book in ipairs(results.skipped) do
            table.insert(new_record, string.format("  ○ %s (%s)", book.name, book.reason))
        end
        table.insert(new_record, "")
    end
    
    table.insert(new_record, string.format(_("[Failed] (%d books)"), #(results.failed or {})))
    table.insert(new_record, string.rep("-", 40))
    if #(results.failed or {}) > 0 then
        local failed_by_reason = {}
        -- This is the log, not the on-screen summary: group by the machine
        -- reason so the raw detail is preserved, but label it in words and
        -- print the original next to it so nothing is lost.
        local raw_order = {}
        for _, book in ipairs(results.failed) do
            local key = book.reason or _("Unknown error")
            if not failed_by_reason[key] then
                failed_by_reason[key] = { books = {} }
                raw_order[#raw_order + 1] = key
            end
            table.insert(failed_by_reason[key].books, { name = book.name })
        end
        table.sort(raw_order)
        for reason_index, raw in ipairs(raw_order) do
            local info = failed_by_reason[raw]
            local readable = M.humanize_failure_reason(raw)
            local line = "\n" .. T(_("[Failure reason %1] %2"), reason_index, readable)
            if raw ~= readable then
                line = line .. string.format("  (%s)", tostring(raw))
            end
            table.insert(new_record, line)
            table.insert(new_record, string.rep("~", 40))
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.name))
            end
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
    local settings = G_reader_settings:readSetting("booksync_plugin") or {}
end

-- The cloud layer reports through one function so presentation is decided
-- once, by level. The old second argument was a timeout picked per call site;
-- it is gone, and `level` replaces it.
local function show_notification(msg, level)
    notify[type(level) == "string" and level or "info"](msg)
end

function M.upload_book(book_path, show_msg, book_info)
    show_msg = (show_msg == nil) or show_msg
    
    if lfs.attributes(book_path, "mode") ~= "file" then
        if show_msg then show_notification(_("Book file does not exist"), "error") end
        return false, "file_not_found"
    end
    
    if not is_supported_book(book_path) then
        if show_msg then show_notification(_("Unsupported file format"), "error") end
        return false, "unsupported_format"
    end
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), "error") end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), "error") end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        if show_msg then show_notification(_("Unsupported cloud storage type"), "error") end
        return false, "unsupported_server"
    end
    
    local cloud_filename = M.get_cloud_filename_for_path({
        file_path = book_path,
        title = book_info.title,
        author = book_info.author,
    })
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), "error") end
        return false, "path_error"
    end
    
    local code = api:upload(cloud_path, book_path)
    
    if type(code) == "number" and code >= 200 and code < 300 then
        return true, "success"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed, please reconfigure"), "error") end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(T(_("Upload failed (HTTP %1)"), tostring(code)), "error")
        end
        return false, "upload_failed"
    end
end

-- Upload a book file to the cloud only when no file with the same name
-- already exists in the cloud book directory.
-- Returns (success, status):
--   success=true,  status="uploaded"       -> file was uploaded
--   success=true,  status="already_exists"  -> same-named file exists, skipped
--   success=false, status=<error_type>      -> failed (see upload_book error types)
function M.upload_book_if_missing(file_path, book_info)
    book_info = book_info or {}

    local cloud_filename = M.get_cloud_filename_for_path({
        file_path = file_path,
        title = book_info.title,
        author = book_info.author,
    })

    local exists, err = M.cloud_file_exists(cloud_filename)
    if err then
        return false, "list_failed"
    end
    if exists then
        return true, "already_exists"
    end

    local success, error_type = M.upload_book(file_path, false, book_info)
    if success then
        return true, "uploaded"
    end
    return false, error_type
end

function M.download_book(cloud_filename, target_dir, show_msg, progress_callback, expected_size, force)
    show_msg = (show_msg == nil) or show_msg
    
    local settings = G_reader_settings:readSetting("booksync_plugin") or {}
    local download_dir = target_dir or settings.book_download_dir
    if not download_dir or download_dir == "" then
        if show_msg then show_notification(_("Please set book download directory in settings first"), "hint") end
        return false, "no_download_dir"
    end
    
    if lfs.attributes(download_dir, "mode") ~= "directory" then
        if not utils.mkdir_p(download_dir) then
            if show_msg then show_notification(_("Cannot create download directory"), "error") end
            return false, "cannot_create_dir"
        end
    end
    
    local local_path = download_dir .. "/" .. cloud_filename

    local lmode, lsize = utils.stat_file(local_path)
    if lmode == "file" then
        if not force then
            local size = lsize
            -- A leftover is only safe to keep if it is plausibly COMPLETE.
            -- 0 bytes is the obvious case, but the same skip rule stranded
            -- every PARTIAL file too: a transfer that died at 400 KB of a 3 MB
            -- book left a non-empty file, and from then on every later run saw
            -- "size > 0" and skipped it again -- permanently, with no way for
            -- the user to recover except finding and deleting the file by hand.
            -- We only have the cloud's advertised size here, so that is what a
            -- truncated local file is compared against; without it we keep the
            -- old, conservative behaviour rather than risk deleting a good book
            -- because the server lied about the size.
            local complete = size > 0
            if complete and type(expected_size) == "number" and expected_size > 0
                and size < expected_size then
                complete = false
                logger.warn("booksync: incomplete leftover (" .. size .. "/" ..
                    expected_size .. "), re-downloading: " .. local_path)
            end
            if complete then
                return false, "file_exists"
            end
            -- An incomplete leftover is replaced by the atomic swap below.
            -- Do NOT delete it here: the download may still fail, and the only
            -- copy on the device would be gone.
            logger.info("booksync: incomplete leftover will be replaced: " .. local_path)
        else
            -- Force: the existing file is replaced -- but only once the new
            -- copy is fully on disk. This used to unlink the local book here,
            -- ABOVE the server / network / API / path checks, so any failure
            -- after that point (offline, wrong credentials, unsupported
            -- provider) destroyed the user's only copy of a book and
            -- downloaded nothing. Force re-download plus no network was enough
            -- to lose a book irrecoverably.
            logger.info("booksync: local file will be replaced after a successful download: " .. local_path)
        end
    end
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), "error") end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), "error") end
        return false, "no_network"
    end
    
    local api = get_api(server)
    if not api then
        if show_msg then show_notification(_("Unsupported cloud storage type"), "error") end
        return false, "unsupported_server"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), "error") end
        return false, "path_error"
    end
    
    if show_msg then
        notify.progressStep(T(_("Downloading: %1"), cloud_filename))
    end
    
    -- Download to a sibling .part file and swap it in only after the bytes are
    -- actually here. Two things fall out of that: a failed or truncated
    -- transfer can no longer destroy a book that was already on the device,
    -- and an interrupted run leaves the original intact instead of a
    -- half-written file the user has to recognise and delete by hand.
    local part_path = local_path .. ".part"
    if lfs.attributes(part_path, "mode") == "file" then
        os.remove(part_path)
    end
    local code = api:download(cloud_path, part_path, progress_callback, expected_size)

    if type(code) == "number" and code == 200 then
        -- Verify what actually landed before declaring success. A 200 with a
        -- truncated body used to be reported as "✓ Download successful" and
        -- counted green by the batch, leaving a corrupt book in the library.
        local _pmode, got = utils.stat_file(part_path)
        if got <= 0 then
            os.remove(part_path)
            logger.err("booksync: download reported success but wrote 0 bytes: " .. tostring(local_path))
            if show_msg then show_notification(_("Download failed: empty file"), "error") end
            return false, "empty_download"
        end
        if type(expected_size) == "number" and expected_size > 0 and got < expected_size then
            -- Keep the local file we already had. The mismatch is recorded by
            -- the caller; silently swapping in a short file is worse.
            os.remove(part_path)
            logger.warn(string.format(
                "booksync: %s: got %d of %d bytes, keeping the local copy",
                tostring(local_path), got, expected_size))
            if show_msg then show_notification(_("Download incomplete, local file kept"), "error") end
            return false, "size_mismatch"
        end
        if os.rename(part_path, local_path) then
            if show_msg then
                show_notification(T(_("Download successful: %1"), cloud_filename), "success")
            end
            return true, "success", local_path
        end
        -- rename can fail across filesystems; fall back to copy-then-delete
        local in_f = io.open(part_path, "rb")
        local out_f = io.open(local_path, "wb")
        if in_f and out_f then
            out_f:write(in_f:read("*a") or "")
        end
        if in_f then pcall(function() in_f:close() end) end
        if out_f then pcall(function() out_f:close() end) end
        if out_f and got > 0 and tonumber(lfs.attributes(local_path, "size")) == got then
            os.remove(part_path)
            if show_msg then
                show_notification(T(_("Download successful: %1"), cloud_filename), "success")
            end
            return true, "success", local_path
        end
        os.remove(part_path)
        if show_msg then show_notification(_("Cannot write to the download folder"), "error") end
        return false, "write_failed"
    end
    -- every failure path below must not leave a partial file lying around
    pcall(os.remove, part_path)

    if type(code) == "number" and code == 404 then
        if show_msg then show_notification(_("Cloud file does not exist"), "error") end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed"), "error") end
        return false, "auth_failed"
    else
        -- Carry the real status through: every non-200/401/404 used to collapse
        -- into one opaque "download_failed", which told the user nothing about
        -- whether to fix their path, their password or their disk.
        local reason = "download_failed"
        local code_n = tonumber(code)
        if code_n == 403 or code_n == 405 then
            reason = "forbidden"
        elseif code_n == 507 then
            reason = "no_space"
        elseif code_n == 413 then
            reason = "too_large"
        elseif code_n == 409 then
            reason = "path_missing"
        elseif code_n then
            reason = "download_failed:" .. tostring(code_n)
        else
            reason = "no_response"
        end
        if show_msg then
            show_notification(T(_("Download failed (HTTP %1)"), tostring(code)), "error")
        end
        return false, reason
    end
end

function M.delete_cloud_book(cloud_filename, show_msg)
    show_msg = (show_msg == nil) or show_msg
    
    local server = get_book_server()
    if not server then
        if show_msg then show_notification(_("Cloud storage service not configured"), "error") end
        return false, "no_server_config"
    end
    
    if not NetworkMgr:isOnline() then
        if show_msg then show_notification(_("Device not connected to network"), "error") end
        return false, "no_network"
    end
    
    local cloud_path = get_cloud_path(server, cloud_filename)
    
    if not cloud_path then
        if show_msg then show_notification(_("Cannot build cloud path"), "error") end
        return false, "path_error"
    end
    
    local api = get_api(server)
    if not api then
        if show_msg then show_notification(_("Unsupported cloud storage type"), "error") end
        return false, "unsupported_server"
    end

    -- Previously three hand-rolled, unguarded socket.http calls lived here.
    -- socket.http raises on connection/DNS/timeout errors, so deleting a single
    -- book could take down the app; the adapter catches that and returns nil.
    local code = api:delete(cloud_path)
    
    if type(code) == "number" and code >= 200 and code < 300 then
        if show_msg then
            show_notification(T(_("Delete successful: %1"), cloud_filename), "success")
        end
        return true, "success"
    elseif type(code) == "number" and code == 404 then
        if show_msg then show_notification(_("Cloud file does not exist"), "error") end
        return false, "file_not_found"
    elseif type(code) == "number" and code == 401 then
        if show_msg then show_notification(_("Cloud storage authentication failed, please reconfigure"), "error") end
        return false, "auth_failed"
    else
        if show_msg then
            show_notification(T(_("Delete failed (HTTP %1)"), tostring(code)), "error")
        end
        return false, "delete_failed"
    end
end

-- ============================================================
-- Batch delete books
-- ============================================================
function M.batch_delete_books(book_names, settings)
    local function get_display_name(filename)
        local name = tostring(filename)
        if #name > 60 then
            name = util.fixUtf8(name:sub(1, 57), "") .. "..."
        end
        return name
    end

    utils.runBatch{
        items = book_names,
        title = _("Deleting books..."),
        describe = function(_unused, filename) return get_display_name(filename) end,
        step = function(_unused, filename)
            return M.delete_cloud_book(filename, false)
        end,
        classify = function(_unused, filename, success, error_msg)
            if success then
                return "success", { name = filename }
            end
            return "failed", { name = filename, reason = error_msg }
        end,
        on_done = function(results)
            M.write_batch_book_log(results, "delete")

            if settings then
                settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch delete") .. ")"
                G_reader_settings:saveSetting("booksync_plugin", settings)
            end

            local msg = T(_("Delete completed: %1 success, %2 failed"), #results.success, #results.failed)
            -- Level follows the failure count: a batch that lost books must not
            -- read like a clean run, and the counts are the point of the line.
            show_notification(msg, #results.failed > 0 and "error" or "success")

            if #results.failed > 0 then
                utils.scheduleSafe("Show delete failures", 0.5, function()
                    local fail_msg = M.formatFailureDetails(results.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Delete failed details"),
                        text = fail_msg,
                    })
                end)
            end
        end,
    }
end

-- Check whether a file named `cloud_filename` already exists in the cloud
-- book directory. Uses the paged WebDAV lister so the check stays correct
-- even when the directory holds more files than a single PROPFIND response
-- can return (e.g. Jianguoyun caps at 750 items per response).
-- Returns (exists, error_message). error_message is nil when the check
-- succeeded (regardless of whether the file exists).
function M.cloud_file_exists(cloud_filename)
    local server = get_book_server()
    if not server then
        return false, _("Cloud storage service not configured")
    end
    if not server.url or server.url == "" then
        return false, _("Cloud directory not set")
    end
    local api = get_api(server)
    if not api then
        return false, _("Unsupported cloud storage type")
    end

    local items = api:list(server.url, false)
    if items == nil then
        return false, _("Cannot get cloud file list")
    end

    if not items or type(items) ~= "table" then
        return false, _("Cannot get cloud file list")
    end

    for _, item in ipairs(items) do
        if item.is_file or item.type == "file" then
            local name = item.text or item.name
            if name and name == cloud_filename then
                return true, nil
            end
        end
    end
    return false, nil
end

function M.show_cloud_book_dialog(callback, plugin, retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        M.show_cloud_book_dialog(callback, plugin, true)
    end) then
        return
    end
    
    local server, api = check_book_cloud_or_notify()
    if not server then
        return
    end

    -- ===== Read settings =====
    local settings = G_reader_settings:readSetting("booksync_plugin") or {}
    
    -- ===== Current path =====
    local current_path = server.url
    local browse_history = {}  -- for going back to parent
    local root_path = "/"      -- cloud storage root
    local current_folders = {} -- subfolders of current path
    local folder_offset = 0    -- offset for paginating subfolder quick buttons
    
    -- ===== Get parent directory =====
    local function get_parent_path(path)
        if path == "/" or path == "" then
            return nil
        end
        local trimmed = path:gsub("/$", "")
        local parent = trimmed:match("^(.*)/")
        if parent == "" then
            parent = "/"
        end
        return parent
    end
    
    -- ===== Fetch path content (including folders) =====
    local function fetch_path_content(path)
        local items = api:list(path, true)
        if items == nil then
            return nil, _("Cannot get cloud file list")
        end

        if not items or type(items) ~= "table" then
            return nil, _("Cannot get cloud file list")
        end

        local folders = {}
        local books = {}

        for _, item in ipairs(items) do
            -- Skip "Long-press to choose current folder" special entry.
            -- NOTE: written as if/elseif rather than `goto continue`, which is
            -- Lua 5.2 syntax. LuaJIT only accepts it when built with 5.2
            -- compatibility, and a parse error here would blow up the
            -- dofile() that loads this module from inside an unprotected
            -- UIManager callback -- i.e. a hard crash instead of a feature.
            if item.type ~= "folder_long_press" then
                if item.is_folder or item.type == "folder" then
                    local name = item.text:gsub("/$", "")
                    if name ~= "" then
                        table.insert(folders, {
                            name = name,
                            path = item.url,
                        })
                    end
                elseif item.is_file or item.type == "file" then
                    local filename = item.text
                    if filename and is_supported_book(filename) then
                        -- Capture file modification time for sorting.
                        -- WebDAV: item.modification is a Unix timestamp (seconds).
                        -- Dropbox: item.server_modified is an ISO-8601 string.
                        local mtime = item.modification
                        if not mtime and item.server_modified then
                            mtime = parse_iso8601(item.server_modified)
                        end
                        table.insert(books, {
                            name = filename,
                            path = item.url,
                            size = item.filesize or 0,
                            modification = mtime,
                        })
                    end
                end
            end
        end

        return {
            folders = folders,
            books = books,
        }, nil
    end
    
    -- ===== Load books list =====
    local original_books = {}
    local search_keyword = ""
    local items_per_page = 10
    local current_page = 1
    local selected = {}
    local dialog
    local refresh_book_list
    local update_buttons
    local show_search_dialog
    local clear_search
    local go_to_page
    -- Sort mode: 1=name asc, 2=name desc, 3=size desc, 4=size asc,
    --            5=time desc (newest first), 6=time asc (oldest first)
    --
    -- Persisted, so the order the user picked survives closing the dialog. It
    -- used to be a plain local, which reset the list to "name ascending" on
    -- every visit. Loaded on demand rather than at file scope: a raise there
    -- would cost the whole plugin, not just this screen.
    local sort_mode = module("sortstate").get()
    local sort_labels = { _("Name A→Z"), _("Name Z→A"), _("Size ↓"), _("Size ↑"), _("Time ↓"), _("Time ↑") }
    -- When toggling a checkbox rebuilds the dialog, advance the cursor to the
    -- next list row (so serial selection flows downward) instead of jumping
    -- back to the top. Set just before such a rebuild; consumed by update_buttons.
    local keep_focus
    -- True only while a hardware-key activation (Press on the focused row) is
    -- being handled, so a checkbox callback can tell key activation from a
    -- touch/mouse tap (which must never advance the cursor or paginate).
    local from_key_press = false
    -- Layout row of the first book. Rows without buttons are separators and do
    -- not reach the focus layout (ButtonTable only adds a row when column_cnt >
    -- 0), so the count is the directory navigation row, plus the search summary
    -- row when a search is active. Everything that places the cursor asks here,
    -- so a row added above the list only has to be counted once.
    local function first_book_row()
        return search_keyword ~= "" and 3 or 2
    end
    
    local function load_books(path)
        current_path = path
        folder_offset = 0  -- Reset folder pagination when switching directory
        local result, err = fetch_path_content(path)
        if not result then
            show_notification(err or _("Cannot load directory"), "error")
            return false
        end
        
        -- Do NOT silently repoint the configured Book Cloud Directory here.
        -- Navigating into a subfolder is browsing, not configuration, and the
        -- old behaviour wrote the folder the user was LOOKING at into their
        -- settings -- so browsing the library quietly changed where every
        -- subsequent upload went, with no confirmation and no notification.
        -- The browse path keeps its own pointer; only an explicit "use this
        -- folder" action is allowed to write settings.
        -- Update server.url so delete_cloud_book uses the new path
        server.url = current_path
        
        -- Save subfolders for quick buttons
        current_folders = result.folders or {}
        
        original_books = result.books or {}
        for _, book in ipairs(original_books) do
            selected[book.name] = false
        end
        
        refresh_book_list()
        update_buttons()
        return true
    end
    
    -- ===== Enter subfolder =====
    local function enter_folder(folder_path)
        table.insert(browse_history, current_path)
        current_path = folder_path
        load_books(current_path)
    end
    
    -- ===== Directory browser =====
    local browse_dialog = nil
    
    local function show_browser()
        local result, err = fetch_path_content(current_path)
        if not result then
            show_notification(err or _("Cannot load directory"), "error")
            return
        end
        
        local folders = result.folders or {}
        local folder_buttons = {}
        
        -- Parent directory
        if #browse_history > 0 then
            table.insert(folder_buttons, {
                {
                    text = "..",
                    callback = function()
                        local parent = table.remove(browse_history)
                        current_path = parent
                        if browse_dialog then
                            UIManager:close(browse_dialog)
                            browse_dialog = nil
                        end
                        load_books(current_path)
                    end
                }
            })
        end
        
        -- Subfolder list
        if #folders == 0 then
            table.insert(folder_buttons, {
                {
                    text = _("No subfolders"),
                    enabled = false,
                }
            })
        else
            for _, folder in ipairs(folders) do
                table.insert(folder_buttons, {
                    {
                        text = folder.name .. "/",
                        callback = function()
                            if browse_dialog then
                                UIManager:close(browse_dialog)
                                browse_dialog = nil
                            end
                            table.insert(browse_history, current_path)
                            current_path = folder.path
                            load_books(current_path)
                        end
                    }
                })
            end
        end
        
        table.insert(folder_buttons, {})
        
        -- Cancel
        table.insert(folder_buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    if browse_dialog then
                        UIManager:close(browse_dialog)
                        browse_dialog = nil
                    end
                end
            }
        })
        
        local display_path = current_path
        if #display_path > 40 then
            display_path = "..." .. util.fixUtf8(display_path:sub(-37), "")
        end
        
        browse_dialog = ButtonDialog:new{
            title = string.format(_("Browse: %s"), display_path),
            title_align = "center",
            buttons = folder_buttons,
            width = math.floor(Screen:getWidth() * 0.7),
        }
        UIManager:show(browse_dialog)
    end
    
    -- Turn to another page of the list (clamped). Rebuilds the dialog, as the
    -- list is paginated by recreating the ButtonDialog. Returns true if the page
    -- actually changed.
    -- wrap: a page-turn gesture (arrows, hardware keys) cycles past the ends the way the
    -- reader's other lists do; a focus move into the margin only clamps, so the cursor
    -- does not jump from the last book to the first.
    go_to_page = function(page, wrap)
        local total_pages = math.ceil(#books / items_per_page)
        if total_pages < 1 then total_pages = 1 end
        if wrap then
            if page < 1 then page = total_pages end
            if page > total_pages then page = 1 end
        else
            if page < 1 then page = 1 end
            if page > total_pages then page = total_pages end
        end
        if page == current_page then return false end
        current_page = page
        -- put the cursor on the first book row of the new page
        keep_focus = { x = 1, y = first_book_row() }
        update_buttons()
        return true
    end

    refresh_book_list = function()
        if search_keyword == "" then
            books = {}
            for i, book in ipairs(original_books) do
                table.insert(books, book)
            end
        else
            books = {}
            local keyword_lower = string.lower(search_keyword)
            for _, book in ipairs(original_books) do
                if string.find(string.lower(book.name), keyword_lower, 1, true) then
                    table.insert(books, book)
                end
            end
        end

        -- Apply sorting
        if sort_mode == 1 then
            table.sort(books, function(a, b)
                return string.lower(a.name) < string.lower(b.name)
            end)
        elseif sort_mode == 2 then
            table.sort(books, function(a, b)
                return string.lower(a.name) > string.lower(b.name)
            end)
        elseif sort_mode == 3 then
            table.sort(books, function(a, b)
                return (a.size or 0) > (b.size or 0)
            end)
        elseif sort_mode == 4 then
            table.sort(books, function(a, b)
                return (a.size or 0) < (b.size or 0)
            end)
        elseif sort_mode == 5 then
            -- Time ↓ (newest first). Items without a modification time sink to the end.
            table.sort(books, function(a, b)
                local ma = a.modification or 0
                local mb = b.modification or 0
                return ma > mb
            end)
        elseif sort_mode == 6 then
            -- Time ↑ (oldest first). Items without a modification time sink to the end.
            table.sort(books, function(a, b)
                local ma = a.modification or 0
                local mb = b.modification or 0
                if ma == 0 and mb == 0 then
                    return string.lower(a.name) < string.lower(b.name)
                elseif ma == 0 then
                    return false
                elseif mb == 0 then
                    return true
                end
                return ma < mb
            end)
        end

        current_page = 1
    end
    
    update_buttons = function()
        local total_pages = math.ceil(#books / items_per_page)
        if total_pages == 0 then total_pages = 1 end
        if current_page > total_pages then current_page = total_pages end
        
        local start_idx = (current_page - 1) * items_per_page + 1
        local end_idx = math.min(start_idx + items_per_page - 1, #books)
        
        local buttons = {}
        
        -- ===== Navigation bar =====
        local display_path = current_path
        if #display_path > 20 then
           display_path = "..." .. util.fixUtf8(display_path:sub(-17), "")
        end
        
        local nav_buttons = {}
        
        -- Left: current directory (click to open browser)
        table.insert(nav_buttons, {
            text = display_path,
            callback = function()
                browse_history = {}
                show_browser()
            end
        })
        
        -- Middle: parent directory (display path name)
        local parent_path = get_parent_path(current_path)
        if parent_path then
            local parent_display = parent_path
            if #parent_display > 15 then
                parent_display = "..." .. util.fixUtf8(parent_display:sub(-12), "")
            end
            table.insert(nav_buttons, {
                text = parent_display,
                callback = function()
                    if browse_dialog then
                        UIManager:close(browse_dialog)
                        browse_dialog = nil
                    end
                    table.insert(browse_history, current_path)
                    current_path = parent_path
                    load_books(current_path)
                end
            })
        else
            table.insert(nav_buttons, {
                text = "",
                enabled = false,
            })
        end
        
        -- Right: root directory
        if current_path ~= root_path then
            table.insert(nav_buttons, {
                text = _("Root"),
                callback = function()
                    current_path = root_path
                    browse_history = {}
                    load_books(current_path)
                end
            })
        else
            table.insert(nav_buttons, {
                text = _("Root"),
                enabled = false,
            })
        end
        
        table.insert(buttons, nav_buttons)
        table.insert(buttons, {})
        
        -- ===== Subfolder quick buttons =====
        local subfolders = current_folders or {}
        local show_folders = {}
        local total = #subfolders
        
        if total == 0 then
            table.insert(show_folders, {
                text = _("No subfolders"),
                enabled = false,
            })
        else
            local display_count = 4  -- Total 4 button slots
            
            if total <= 3 then
                -- total <= 3: show all, leave empty slots
                for i = 1, total do
                    table.insert(show_folders, {
                        text = subfolders[i].name,
                        callback = function()
                            enter_folder(subfolders[i].path)
                        end
                    })
                end
                local remaining = display_count - #show_folders
                for i = 1, remaining do
                    table.insert(show_folders, {
                        text = "",
                        enabled = false,
                    })
                end
            else
                -- total > 3: show 3 subfolders + refresh button
                local start_idx = folder_offset + 1
                local end_idx = math.min(start_idx + 3 - 1, total)
                
                for i = start_idx, end_idx do
                    table.insert(show_folders, {
                        text = subfolders[i].name,
                        callback = function()
                            enter_folder(subfolders[i].path)
                        end
                    })
                end
                
                -- Fill up to 3 slots if current batch has less than 3
                local current_count = #show_folders
                for i = current_count + 1, 3 do
                    table.insert(show_folders, {
                        text = "",
                        enabled = false,
                    })
                end
                
                -- Refresh button
                table.insert(show_folders, {
                    text = "↻",
                    callback = function()
                        if end_idx >= total then
                            folder_offset = 0
                        else
                            folder_offset = folder_offset + 3
                        end
                        update_buttons()
                    end
                })
            end
        end
        
        table.insert(buttons, show_folders)
        table.insert(buttons, {})
        
        -- ===== Search results display =====
        if search_keyword ~= "" then
            table.insert(buttons, {
                {
                    text = string.format(_("Search: \"%s\" (%d books found)"), search_keyword, #books),
                    enabled = false,
                }
            })
            table.insert(buttons, {})
        end
        
        -- ===== Book list =====
        if #books == 0 then
            table.insert(buttons, {
                {
                    text = _("No books found"),
                    enabled = false,
                    alignment = "center",
                }
            })
        else
            for i = start_idx, end_idx do
                local book = books[i]
                local size_mb = string.format("%.2f MB", (book.size or 0) / (1024 * 1024))
                local check = selected[book.name] and "✓ " or "  "
                local display_text
                if sort_mode == 5 or sort_mode == 6 then
                    -- When sorting by time, show the modification date for context.
                    if book.modification and book.modification > 0 then
                        local date_str = os.date("%Y-%m-%d", book.modification)
                        display_text = check .. book.name .. " (" .. size_mb .. ", " .. date_str .. ")"
                    else
                        display_text = check .. book.name .. " (" .. size_mb .. ")"
                    end
                else
                    display_text = check .. book.name .. " (" .. size_mb .. ")"
                end
                table.insert(buttons, {
                    {
                        text = display_text,
                        callback = function()
                            selected[book.name] = not selected[book.name]
                            if dialog then
                                -- Advance the cursor downward so serial checking
                                -- flows: to the next book on the page; if the last
                                -- book of a non-final page was toggled, to the first
                                -- book of the next page; on the very last book of the
                                -- last page, stay put. Book rows are located by index
                                -- (start_idx/end_idx, plus the optional search summary
                                -- row) so the cursor never lands on the non-actionable
                                -- "Page x/y" row.
                                -- Gated on from_key_press: only a hardware-key
                                -- activation advances/paginates. A touch/mouse tap
                                -- (even on a hybrid device, even on the already
                                -- focused row) just toggles the checkbox.
                                if from_key_press then
                                    local first_book_y = first_book_row()
                                    local this_y = first_book_y + (i - start_idx)
                                    local last_book_y = first_book_y + (end_idx - start_idx)
                                    local total_pages = math.ceil(#books / items_per_page)
                                    if this_y < last_book_y then
                                        keep_focus = { x = 1, y = this_y + 1 }
                                    elseif current_page < total_pages then
                                        current_page = current_page + 1
                                        keep_focus = { x = 1, y = first_book_y }
                                    else
                                        keep_focus = { x = 1, y = this_y }
                                    end
                                end
                                update_buttons()
                            end
                        end,
                    }
                })
            end
        end
        
        table.insert(buttons, {})
        
        -- ===== Page navigation =====
        local page_buttons = {}
        if current_page > 1 then
            table.insert(page_buttons, {
                text = _("◀ Previous Page"),
                callback = function()
                    go_to_page(current_page - 1)
                end
            })
        end
        table.insert(page_buttons, {
            text = string.format(_("Page %d/%d (%d books)"), current_page, total_pages, #books),
            enabled = false,
        })
        if current_page < total_pages then
            table.insert(page_buttons, {
                text = _("Next Page ▶"),
                callback = function()
                    go_to_page(current_page + 1)
                end
            })
        end
        table.insert(buttons, page_buttons)
        
        table.insert(buttons, {})
        
        -- ===== Action buttons =====
        local selected_count = 0
        for _, book in ipairs(original_books) do
            if selected[book.name] then
                selected_count = selected_count + 1
            end
        end
        
        table.insert(buttons, {
            {
                text = _("Select All"),
                callback = function()
                    for _, book in ipairs(original_books) do
                        selected[book.name] = true
                    end
                    update_buttons()
                end
            },
            {
                text = _("Deselect All"),
                callback = function()
                    for _, book in ipairs(original_books) do
                        selected[book.name] = false
                    end
                    update_buttons()
                end
            },
            {
                text = _("Search"),
                callback = function()
                    show_search_dialog()
                end
            },
            {
                text = T(_("Sort: %1"), sort_labels[sort_mode]),
                callback = function()
                    sort_mode = module("sortstate").next(sort_mode)
                    module("sortstate").set(sort_mode)
                    refresh_book_list()
                    update_buttons()
                end
            },
        })
        
        table.insert(buttons, {
            {
                text = search_keyword ~= "" and _("Clear Search") or "",
                enabled = search_keyword ~= "",
                callback = function()
                    clear_search()
                end
            },
            {
                text = string.format(_("Delete (%d)"), selected_count),
                callback = function()
                    local selected_names = {}
                    for _, book in ipairs(original_books) do
                        if selected[book.name] then
                            table.insert(selected_names, book.name)
                        end
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    if #selected_names > 0 then
                        UIManager:show(ConfirmBox:new{
                            text = string.format(_("Are you sure you want to delete %d book(s) from the cloud?\nThis action cannot be undone!"), #selected_names),
                            ok_text = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                local settings = G_reader_settings:readSetting("booksync_plugin") or {}
                                M.batch_delete_books(selected_names, settings)
                            end
                        })
                    else
                        show_notification(_("No books selected"), "hint")
                    end
                end
            },
            {
                text = string.format(_("Download (%d)"), selected_count),
                callback = function()
                    local picked_books = {}
                    for _, book in ipairs(original_books) do
                        if selected[book.name] then
                            table.insert(picked_books, book)
                        end
                    end
                    if dialog then
                        UIManager:close(dialog)
                    end
                    if #picked_books > 0 then
                        callback(picked_books)
                    else
                        show_notification(_("No books selected"), "hint")
                    end
                end
            },
            {
                text = _("Cancel"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    end
                end
            },
        })
        
        local title_text = string.format(_("Select books to download/delete (%d selected)"), selected_count)
        -- Where the cursor should land after (re)building: an explicit
        -- keep_focus set by a toggle / page turn, otherwise the first book row.
        local target_focus = keep_focus or { x = 1, y = first_book_row() }
        keep_focus = nil

        if dialog then
            -- Rebuild the contents in place via reinit() instead of
            -- close()+new(). Closing the dialog triggers a flashing e-ink
            -- refresh (onCloseWidget -> "flashui") on every checkbox toggle;
            -- reinit() rebuilds the button table on the same widget with a
            -- plain "ui" refresh (this is what ButtonDialog:setTitle does),
            -- so it no longer flashes, and the widget's key bindings and the
            -- onFocusMove override are preserved.
            dialog.title = title_text
            dialog.buttons = buttons
            dialog.selected = target_focus
            -- ButtonDialog:init() does `self.layout = self.layout or buttontable.layout`,
            -- so on reinit the stale layout (pointing at freed buttons) would be
            -- kept and the focus highlight would land on nothing. Clear it so
            -- init() rebuilds the layout from the new buttontable.
            dialog.layout = nil
            -- Same reasoning for the ScrollableContainer: init() only (re)creates
            -- cropping_widget in the overflow branch, so a stale one left over
            -- from a taller previous build would keep driving scroll/focus
            -- geometry (onFocusMove calls _scrollBy on it). Clear it too.
            dialog.cropping_widget = nil
            -- The rebuilt dialog may be shorter (the last page holds fewer rows), and
            -- refreshing only its new extent would leave a strip of the old, taller frame
            -- on screen. Refresh the union of the frames, and repaint what is underneath.
            local old_dimen = dialog.movable and dialog.movable.dimen
                and dialog.movable.dimen:copy()
            dialog:reinit()
            UIManager:setDirty("all", function()
                local new_dimen = dialog and dialog.movable and dialog.movable.dimen
                if old_dimen and new_dimen then
                    return "ui", old_dimen:combine(new_dimen)
                end
                return "ui", new_dimen or old_dimen
            end)
        else
            dialog = ButtonDialog:new{
                title = title_text,
                title_align = "center",
                buttons = buttons,
                width = math.floor(Screen:getWidth() * 0.85),
                selected = target_focus,
            }

            -- Non-touch navigation (D-pad devices): in this single-column list
            -- the horizontal arrows have no in-row neighbour to move to, so they
            -- do nothing there. Repurpose them to turn pages while the cursor is
            -- on a list item (a one-button row); on the multi-column nav/action
            -- rows they keep moving the focus as usual.
            if Device:hasDPad() then
                dialog.onFocusMove = function(self, args)
                    local dx = args[1]
                    if dx ~= 0 and self.layout and self.selected then
                        local row = self.layout[self.selected.y]
                        if row and #row == 1 then
                            go_to_page(current_page + (dx > 0 and 1 or -1), true)
                            return true
                        end
                    end
                    return ButtonDialog.onFocusMove(self, args)
                end
            end

            -- Hardware page-turn keys flip the list pages too, the natural
            -- gesture on these devices. Use KOReader's logical page-key groups
            -- (not hard-coded LPgFwd/etc.) so they follow the device and screen
            -- orientation; this also restores a working handler for those keys
            -- after we strip them from the scroll container below.
            if Device:hasKeys() then
                dialog.key_events.CloudNextPage = { { Input.group.PgFwd } }
                dialog.key_events.CloudPrevPage = { { Input.group.PgBack } }
                dialog.onCloudNextPage = function()
                    go_to_page(current_page + 1, true)
                    return true
                end
                dialog.onCloudPrevPage = function()
                    go_to_page(current_page - 1, true)
                    return true
                end
            end

            -- Tell checkbox callbacks whether a toggle came from a hardware-key
            -- activation (Press on the focused row) vs a touch/mouse tap: only
            -- the former should advance the cursor / paginate.
            local orig_onPress = dialog.onPress
            dialog.onPress = function(self, ...)
                from_key_press = true
                local ret = orig_onPress(self, ...)
                from_key_press = false
                return ret
            end

            UIManager:show(dialog)
        end

        -- Hardware page-turn keys must flip list pages, not scroll the popup.
        -- When the dialog is tall enough to be wrapped in a ScrollableContainer,
        -- that child binds PgFwd/PgBack (== our LPgFwd/RPgFwd/LPgBack/RPgBack) and
        -- would consume them first. Drop its page-key handlers so our
        -- CloudNextPage/CloudPrevPage bindings on the dialog win. Re-applied on
        -- each (re)build since reinit recreates cropping_widget.
        if dialog.cropping_widget and dialog.cropping_widget.key_events then
            dialog.cropping_widget.key_events.ScrollPageUp = nil
            dialog.cropping_widget.key_events.ScrollPageDown = nil
        end

        -- Make the cursor position visible on D-pad devices (and on the row we
        -- advanced to after an in-list rebuild).
        if Device:hasDPad() then
            dialog:refocusWidget()
            -- After an in-place reinit the ScrollableContainer is recreated with
            -- its scroll offset back at the top; refocusWidget() only restyles
            -- the focus, while the auto-scroll-to-focus lives in onFocusMove
            -- (not run on reinit). Nudge it (next tick, once geometry is laid
            -- out) so the focused row is scrolled into view if it would be
            -- off-screen.
            if dialog.cropping_widget then
                utils.nextTickSafe("Focus dialog", function()
                    if dialog.onFocusMove then
                        dialog:onFocusMove({ 0, 0 })
                    end
                end)
            end
        end
    end

    show_search_dialog = function()
        local InputDialog = require("ui/widget/inputdialog")
        local search_dialog = nil
        search_dialog = InputDialog:new{
            title = _("Search books"),
            input = search_keyword,
            input_hint = _("Enter book title keyword"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(search_dialog)
                        end,
                    },
                    {
                        text = _("Search"),
                        is_enter_default = true,
                        callback = function()
                            search_keyword = search_dialog:getInputText()
                            UIManager:close(search_dialog)
                            refresh_book_list()
                            update_buttons()
                        end,
                    },
                },
            },
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end
    
    clear_search = function()
        if search_keyword ~= "" then
            search_keyword = ""
            refresh_book_list()
            update_buttons()
        end
    end
    
    -- Initial load
    load_books(server.url)
end

-- ============================================================
-- Batch upload books
-- ============================================================
function M.batchUploadBooks(selected_books, settings, plugin)
    local function get_display_name(book)
        local name = book.title or book.name or "?"
        if type(name) ~= "string" then name = tostring(name) end
        if #name > 60 then
            name = util.fixUtf8(name:sub(1, 57), "") .. "..."
        end
        return name
    end

    local function names_for(book_info)
        local path = book_info.path or book_info.file_path
        local local_name = tostring(path):match("([^/]+)$") or _("Unknown")
        local ok_cloud, cloud_name = pcall(M.get_cloud_filename_for_path, {
            file_path = path,
            title = book_info.title,
            author = book_info.author,
        })
        if not ok_cloud or type(cloud_name) ~= "string" then
            cloud_name = local_name
        end
        return path, local_name, cloud_name
    end

    utils.runBatch{
        items = selected_books,
        title = _("Uploading books..."),
        describe = function(_unused, b) return get_display_name(b) end,
        step = function(_unused, book_info)
            local path = book_info.path or book_info.file_path
            return M.upload_book(path, false, {
                title = book_info.title,
                author = book_info.author,
            })
        end,
        classify = function(_unused, book_info, success, error_msg)
            local path, local_name, cloud_name = names_for(book_info)
            if success then
                return "success", { name = local_name, cloud_name = cloud_name, path = path }
            end
            return "failed", { name = local_name, cloud_name = cloud_name, path = path, reason = error_msg }
        end,
        on_done = function(results)
            M.write_batch_book_log(results, "upload")
            if settings then
                settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch upload") .. ")"
                G_reader_settings:saveSetting(plugin and plugin.plugin_id or "booksync_plugin", settings)
            end

            local msg = T(_("Upload completed: %1 success, %2 failed"), #results.success, #results.failed)
            if #results.failed > 0 then
                notify.error(msg)
            else
                notify.success(msg)
            end

            if #results.failed > 0 then
                utils.scheduleSafe("Show upload failures", 0.5, function()
                    local fail_msg = M.formatFailureDetails(results.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Upload failed details"),
                        text = fail_msg,
                    })
                end)
            end

            M.cleanupFileManagerSelection()
        end,
    }
end

function M.batchDownloadBooks(books, settings, plugin)
    local results = { success = {}, failed = {}, skipped = {} }

    if not settings.book_download_dir or settings.book_download_dir == "" then
        table.insert(results.failed, {
            name = _("All books"),
            reason = _("Download directory not set"),
        })
        M.write_batch_book_log(results, "download")
        show_notification(_("Download completed: 0 success, 1 failed, 0 skipped"), "error")
        return
    end

    local download_dir = settings.book_download_dir

    -- Total bytes for the progress bar. Providers that do not report a size
    -- (Dropbox) give 0, in which case progress_max stays 0 and the dialog
    -- simply shows the item counter instead of a bar.
    local total_bytes = 0
    for _, book in ipairs(books) do
        total_bytes = total_bytes + (tonumber(book.size) or 0)
    end

    local function get_display_name(book)
        local name = book.title or book.name or "?"
        if type(name) ~= "string" then name = tostring(name) end
        if #name > 60 then
            name = util.fixUtf8(name:sub(1, 57), "") .. "..."
        end
        return name
    end

    -- Byte accounting is kept outside runBatch because the progress callback
    -- fires many times per file while the item counter only advances once.
    local bytes_done = 0
    local force_overwrite = settings.book_download_overwrite and true or false

    utils.runBatch{
        items = books,
        title = _("Downloading books..."),
        progress_max = total_bytes > 0 and total_bytes or #books,
        describe = function(_unused, book) return get_display_name(book) end,
        step = function(_unused, book, report)
            local filename = book.name
            local local_path = download_dir .. "/" .. filename

            local lm, ls = utils.stat_file(local_path)
            local already = lm == "file" and ls > 0
            if already and not force_overwrite then
                bytes_done = bytes_done + (tonumber(book.size) or 0)
                if report then report(bytes_done) end
                return "file_exists", nil, local_path
            end

            local seen = 0
            local ok, success, error_msg, wrote = pcall(M.download_book, filename, nil, false, function(n)
                n = tonumber(n) or 0
                local delta = n - seen
                if delta > 0 then
                    seen = n
                    bytes_done = bytes_done + delta
                    if report then report(bytes_done) end
                end
            end, tonumber(book.size) or nil, force_overwrite)
            if not ok then
                -- Let runBatch log the full traceback, then re-raise so this
                -- book is recorded as failed rather than silently skipped.
                error(success, 0)
            end

            -- Pad the bar out to the file's full size: providers do not always
            -- report a final byte count, and a bar stuck at 97% looks broken.
            local declared = tonumber(book.size) or 0
            if declared > seen then
                bytes_done = bytes_done + (declared - seen)
            end
            if report then report(bytes_done) end
            return success, error_msg, local_path
        end,
        classify = function(_unused, book, a, b, c)
            local filename = book.name
            if a == "file_exists" then
                return "skipped", { name = filename, reason = _("Local file with same name already exists") }
            end
            if a then
                return "success", { name = filename, path = c }
            end
            return "failed", { name = filename, reason = b }
        end,
        on_done = function(res)
            M.write_batch_book_log(res, "download")
            if settings then
                settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. _("Book sync") .. "-" .. _("Batch download") .. ")"
                G_reader_settings:saveSetting(plugin and plugin.plugin_id or "booksync_plugin", settings)
            end

            local msg = T(_("Download completed: %1 success, %2 failed, %3 skipped"),
                #res.success, #res.failed, #res.skipped)
            show_notification(msg, #res.failed > 0 and "error" or "success")

            if #res.failed > 0 then
                utils.scheduleSafe("Show download failures", 0.5, function()
                    local fail_msg = M.formatFailureDetails(res.failed)
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{
                        title = _("Download failed details"),
                        text = fail_msg,
                    })
                end)
            end

            M.refreshFileManager()
        end,
    }
end

function M.refreshFileManager()
    -- The FileManager instance can be stale by the time a batch finishes (the
    -- user may have left the library, or switched to the reader). refreshPath
    -- on a dead FileChooser is a native crash on Android, not a Lua error.
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and fm.file_chooser and type(fm.file_chooser.refreshPath) == "function" then
            fm.file_chooser:refreshPath()
        end
    end)
end

-- Every batch failure carries a machine reason code. Showing that code -- or,
-- worse, the raw Lua error behind it -- is how a download failure ends up
-- reading "cloudapilua:272: attempt to use a closed file" in a dialog box.
-- Map the codes to sentences, and demote anything unrecognised to a short
-- human line: the technical detail belongs in the log, which the user can
-- open deliberately, not in the failure summary they read on a phone.
local FAILURE_REASONS = {
    -- HTTP status buckets. A bare "download failed" is unactionable; the user
    -- cannot tell a wrong cloud path from a full disk.
    forbidden      = function() return _("Access denied - check the cloud path and credentials") end,
    no_space       = function() return _("No space left on the device") end,
    too_large      = function() return _("The file is too large for the server") end,
    path_missing   = function() return _("The cloud folder or file does not exist") end,
    no_response    = function() return _("No response from the server - connection dropped or timed out") end,
    file_exists    = function() return _("Already downloaded") end,
    no_download_dir = function() return _("Download directory is not set") end,
    cannot_create_dir = function() return _("Cannot create the download directory") end,
    no_server_config = function() return _("Cloud storage is not configured") end,
    no_network     = function() return _("No network connection") end,
    unsupported_server = function() return _("Unsupported cloud storage type") end,
    path_error     = function() return _("Cannot build the cloud path") end,
    file_not_found = function() return _("The file no longer exists in the cloud") end,
    auth_failed    = function() return _("Cloud storage rejected the credentials") end,
    download_failed = function() return _("Transfer failed or was cut off") end,
    list_failed    = function() return _("Could not list the cloud folder") end,
    upload_failed  = function() return _("Upload failed or was cut off") end,
    upload_too_large = function() return _("File is too large for this cloud service") end,
    no_metadata_file = function() return _("No metadata sidecar next to the book") end,
    file_read_error = function() return _("The local file could not be read") end,
    unknown        = function() return _("Unknown error - see the sync log") end,
}

-- A raw Lua error is anything that looks like "file.lua:123: message".
local function looks_like_lua_error(s)
    return type(s) == "string" and s:match("^%a[^:]-%.lua:%d+:") ~= nil
end

function M.humanize_failure_reason(reason)
    if type(reason) ~= "string" or reason == "" then
        return FAILURE_REASONS.unknown()
    end
    local mapped = FAILURE_REASONS[reason]
    if not mapped then
        -- "download_failed:503" -> name plus the status, so an unmapped code is
        -- still informative instead of silently generic.
        local base, code = reason:match("^(%a+):(%d+)$")
        if base then
            local fn = FAILURE_REASONS[base]
            if fn then return fn() .. " (HTTP " .. code .. ")" end
            return _("Transfer failed") .. " (HTTP " .. code .. ")"
        end
    end
    if mapped then
        return mapped()
    end
    if looks_like_lua_error(reason) then
        return _("Internal error - the details are in the sync log")
    end
    -- An unrecognised but non-Lua string is still a message; show it as-is.
    return reason
end

function M.formatFailureDetails(failed_list)
    local fail_msg = _("Failure details:\n\n")

    -- Group by human-readable reason, counting how many books hit each one.
    local groups, order = {}, {}
    for _, fail in ipairs(failed_list or {}) do
        local text = M.humanize_failure_reason(fail.reason)
        local g = groups[text]
        if not g then
            g = { books = {}, count = 0 }
            groups[text] = g
            order[#order + 1] = text
        end
        g.count = g.count + 1
        g.books[#g.books + 1] = fail
    end
    -- pairs() order is undefined, so the numbering used to shuffle between
    -- otherwise identical runs. Sort: biggest group first, then alphabetically.
    table.sort(order, function(a, b)
        if groups[a].count ~= groups[b].count then
            return groups[a].count > groups[b].count
        end
        return a < b
    end)

    for i, reason in ipairs(order) do
        local g = groups[reason]
        fail_msg = fail_msg .. T(_("[Failure reason %1] %2 (%3 books)\n"), i, reason, g.count)
        fail_msg = fail_msg .. string.rep("~", 40) .. "\n"
        for j, book in ipairs(g.books) do
            fail_msg = fail_msg .. string.format("  %d. %s", j, tostring(book.name))
            if book.cloud_name then
                fail_msg = fail_msg .. string.format(" -> %s", book.cloud_name)
            end
            fail_msg = fail_msg .. "\n"
        end
        fail_msg = fail_msg .. "\n"
    end

    if #order > 0 then
        fail_msg = fail_msg .. _("Full details, including stack traces, are in the sync log.")
    end
    return fail_msg
end

-- Return the file browser to its normal state after a batch.
--
-- Both halves of the old version were wrong. It called onToggleSelectMode
-- unconditionally, and onToggleSelectMode is a toggle -- so a batch that
-- finished after the user had already left selection mode switched the browser
-- *into* it. It also undimmed the rows and then asked onToggleSelectMode to
-- refresh, rebuilding the same directory twice; on a Kindle holding a few
-- hundred books in a folder, that second scan is enough to look like a freeze.
function M.cleanupFileManagerSelection()
    local utils = module("utils")
    utils.undimFileRows()
    utils.bookshelfExitSelection()
end

function M.batchUploadWithFMSelection(plugin, retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        M.batchUploadWithFMSelection(plugin, true)
    end) then
        return
    end
    
    local remote = module("remote")
    local server = check_book_cloud_or_notify()
    if not server then
        return
    end

     -- ===== Bookshelf support =====
    if utils.isBookshelfShowing() then
        local files = utils.bookshelfGetSelectedFiles()
        
        if #files == 0 then
            utils.bookshelfEnterSelection()
            notify.hint(T(_("Please select books to %1, then tap \"%1\""),
                           _("upload"), _("Batch upload selected books")))
            return
        end
        
        local books = {}
        for _, file in ipairs(files) do
            if is_supported_book(file) then
                local filename = file:match("([^/]+)$") or _("Unknown")
                local basename = strip_extension(filename)
                local props = {}
                if plugin.ui and plugin.ui.bookinfo then
                    props = plugin.ui.bookinfo:getDocProps(file, nil, true) or {}
                end
                
                table.insert(books, {
                    file_path = file,
                    path = file,
                    name = filename,
                    title = props.title or props.display_title or basename,
                    author = props.authors,
                    book_basename = basename,
                })
            end
        end
        
        if #books == 0 then
            notify.hint(_("No valid book files selected"))
            return
        end
        
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Upload %d book(s) to cloud"), #books),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                M.batchUploadBooks(books, plugin.settings, plugin)
                utils.bookshelfExitSelection()
            end
        })
        return
    end
    
    local ui = plugin.ui
    local action_text = _("upload")
    local button_text = _("Batch upload selected books")
    
    if not ui or not ui.file_chooser then
        local FileManager = require("apps/filemanager/filemanager")

        -- Same teardown hazard as manual_sync: tearing the reader down inline
        -- ran PluginLoader:finalize() (destroying the plugin instance whose
        -- closure is running) and closed the menu dialog UIManager was in the
        -- middle of dispatching. Defer a tick and use ReaderUI:onHome().
        local ReaderUI = require("apps/reader/readerui")
        local reader = ReaderUI.instance
        UIManager:nextTick(function()
            local ok, err = pcall(function()
                if reader and reader.document then
                    if plugin.auto_sync then
                        plugin.auto_sync:setSkipUpload(true)
                    end
                    reader:onHome()
                else
                    FileManager:showFiles()
                end
            end)
            if not ok then
                logger.err("booksync: failed to open the file manager:", tostring(err))
                return
            end
            utils.nextTickSafe("Enter select mode", function()
                local fm = FileManager.instance
                -- only when we are not already in it: this runs a tick after
                -- showFiles(), and showFiles() can hand back an instance that
                -- was left in selection mode. An unconditional toggle would
                -- then leave selection instead of entering it.
                if fm and not fm.selected_files then
                    fm:onToggleSelectMode(true)
                end
                notify.hint(T(_("Please select books to %1, then tap \"%1\""), action_text, button_text))
            end)
        end)
        return
    end
    
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    
    if not fm then
        notify.hint(_("Could not open the file browser"))
        return
    end
    
    if fm.selected_files == nil then
        fm:onToggleSelectMode(true)
        notify.hint(T(_("Please select books to %1, then tap \"%1\""), action_text, button_text))
        return
    end
    
    local selected_files = fm.selected_files
    if not selected_files or next(selected_files) == nil then
        notify.hint(T(_("Please select books to %1, then tap \"%1\""), action_text, button_text))
        return
    end
    
    local books = {}
    for file, selected in pairs(selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            if is_supported_book(file) then
                local filename = file:match("([^/]+)$") or _("Unknown")
                local basename = strip_extension(filename)

                local props = {}
                if ui and ui.bookinfo then
                    props = ui.bookinfo:getDocProps(file, nil, true) or {}
                end
                local title = props.title or props.display_title or basename
                local author = props.authors
                if type(author) == "table" then
                    author = author[1]
                end
                
                table.insert(books, {
                    file_path = file,
                    path = file,
                    name = filename,
                    title = title,
                    author = author,
                    book_basename = basename,
                })
            end
        end
    end
    
    if #books == 0 then
        notify.hint(_("No valid book files selected"))
        return
    end
    
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Upload %d book(s) to cloud"), #books),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            M.batchUploadBooks(books, plugin.settings, plugin)
        end
    })
end

return M
