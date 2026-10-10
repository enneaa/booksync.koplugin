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

local json = require("json")
local UIManager = require("ui/uimanager")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local docsettings = require("frontend/docsettings")
local DataStorage = require("datastorage")
local _ = module("gettext_shim")
local notify = module("notify")
local T = require("ffi/util").template
local logger = require("logger")
local Event = require("ui/event")
local M = {}

local DOWNLOAD_DIR = DataStorage:getDataDir() .. "/metadatasync/"

local ERROR_TYPES = {
    NO_NETWORK = "no_network",
    NO_SERVER_CONFIG = "no_server_config",
    NO_CLOUD_DIR = "no_cloud_dir",
    UNSUPPORTED_SERVER = "unsupported_server",
    AUTH_FAILED = "auth_failed",
    LOCAL_METADATA_NOT_EXISTS = "local_metadata_not_exists",
    CLOUD_FILE_NOT_FOUND = "cloud_file_not_found",
    FILENAME_TOO_LONG = "filename_too_long",
    UNKNOWN_ERROR = "unknown_error"
}

-- Turn an HTTP status into a reason. Every transfer path used to name 404 and
-- 401 and then report "Unknown error" for every other status, so a 403 (wrong
-- path or no permission) and a 500 (server down) were indistinguishable to the
-- user -- and the five call sites drifted apart because each was patched on its
-- own. One mapping, used everywhere.
local function http_reason(code)
    if type(code) ~= "number" then
        return ERROR_TYPES.UNKNOWN_ERROR
    end
    if code == 404 then return ERROR_TYPES.CLOUD_FILE_NOT_FOUND end
    if code == 401 or code == 407 then return ERROR_TYPES.AUTH_FAILED end
    return "http_" .. tostring(code)
end

function M.get_error_message(error_type, is_upload)
    local messages = {
        [ERROR_TYPES.NO_NETWORK] = { 
            reason = _("Offline"), 
            solution = _("Please turn on Wi-Fi and try again") 
        },
        [ERROR_TYPES.NO_SERVER_CONFIG] = { 
            reason = _("Cloud not configured"), 
            solution = _("Please configure cloud storage in settings") 
        },
        [ERROR_TYPES.NO_CLOUD_DIR] = { 
            reason = _("Cloud directory not set"), 
            solution = _("Please set the cloud folder in settings — syncing without one would write to the storage root") 
        },
        [ERROR_TYPES.UNSUPPORTED_SERVER] = { 
            reason = _("Unsupported cloud storage type"), 
            solution = _("Please use WebDAV or Dropbox") 
        },
        [ERROR_TYPES.AUTH_FAILED] = { 
            reason = _("Cloud login failed"), 
            solution = _("Please check username/password") 
        },
        [ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS] = { 
            reason = _("No local metadata"), 
            solution = _("Please open the book first to generate metadata file") 
        },
        [ERROR_TYPES.CLOUD_FILE_NOT_FOUND] = { 
            reason = _("Metadata file not found in cloud"), 
            solution = _("Please upload the book first") 
        },
        [ERROR_TYPES.FILENAME_TOO_LONG] = { 
            reason = _("Cloud filename too long, upload failed"), 
            solution = _("Please try:\n1. Shorten the book title\n2. Shorten the author name\nCloud files are named Title_Author, and the limit is 255 characters") 
        },
        [ERROR_TYPES.UNKNOWN_ERROR] = { 
            reason = _("Unknown error"), 
            solution = _("Please check the log file") 
        }
    }
    local hit = messages[error_type]
    if hit then return hit end

    -- "http_403" and friends: name what the status actually means, and keep
    -- the number visible so an unlisted status is still actionable.
    local code = type(error_type) == "string" and error_type:match("^http_(%d+)$")
    if code then
        local n = tonumber(code)
        if n == 403 or n == 405 then
            return { reason = _("Access denied - check the cloud path and credentials"),
                     solution = _("The server refused this request. Check the cloud folder path, and that the account may write to it.") }
        end
        if n == 507 then
            return { reason = _("No space left on the device"),
                     solution = _("Free up space in the download folder and try again.") }
        end
        if n == 413 then
            return { reason = _("The file is too large for the server"),
                     solution = _("Ask your server admin to raise the upload limit.") }
        end
        if n == 409 then
            return { reason = _("The cloud folder or file does not exist"),
                     solution = _("Check the cloud folder path in Settings.") }
        end
        return { reason = T(_("Transfer failed (HTTP %1)"), code),
                 solution = _("Check the sync log for the full request that failed.") }
    end

    return { reason = _("Unknown error"), solution = _("Contact developer") }
end

function M.ensure_download_dir()
    if lfs.attributes(DOWNLOAD_DIR, "mode") then
        return true
    end
    local utils = module("utils")
    return utils.mkdir_p(DOWNLOAD_DIR)
end

function M.ensure_sdr_directory(book_file)
    local DocSettings = require("docsettings")
    
    local sdr_dir = DocSettings:getSidecarDir(book_file)
    if not sdr_dir then
        return nil
    end
    
    if lfs.attributes(sdr_dir, "mode") == "directory" then
        return sdr_dir
    end
    
    local utils = module("utils")
    if utils.mkdir_p(sdr_dir) then
        return sdr_dir
    end
    return nil
end

function M.ensure_local_metadata(book)
    local metadata_exists = book.metadata and lfs.attributes(book.metadata, "mode") == "file"
    
    if metadata_exists then
        return true
    end
    
    local sdr_dir = M.ensure_sdr_directory(book.file)
    if not sdr_dir then
        return false
    end
    
    local ext = book.file:match("%.([^%.]+)$") or "epub"
    book.metadata = sdr_dir .. "/metadata." .. ext .. ".lua"
    
    return true
end

-- Write metadata back to the book's sidecar through the native DocSettings
-- path.
--
-- Two things matter here and the original code got both wrong:
--   1. DocSettings:flush() derives the sidecar directory from data.doc_path
--      when document_metadata_folder == "hash". Replacing .data wholesale
--      without carrying doc_path over made flush() resolve the directory to
--      "" and write the sidecar to "/metadata.<ext>.lua" -- i.e. the sync
--      silently did nothing (or scribbled on the filesystem root).
--   2. The open ReaderUI keeps its own DocSettings instance in memory. Writing
--      the sidecar underneath it leaves the reader with a stale copy, so the
--      caller has to reload the document (see M.apply_to_open_book).
function M.save_metadata_native(metadata, book_file)
    if type(metadata) ~= "table" then
        return false, "invalid_metadata"
    end
    if not book_file or book_file == "" then
        return false, "invalid_book_file"
    end

    -- Never hand DocSettings a table without doc_path: see note 1 above.
    metadata.doc_path = book_file

    local ok, err = pcall(function()
        local DocSettings = require("docsettings")
        local doc_settings = DocSettings:open(book_file)
        doc_settings.data = metadata
        doc_settings:flush()
    end)
    if not ok then
        logger.err("booksync: save_metadata_native failed:", tostring(err))
        return false, err
    end
    return true
end

-- Is `file` the book currently open in the reader?
function M.is_reader_open(file)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return false end
    local ui = ReaderUI.instance
    return not not (ui and ui.document and ui.document.file == file)
end

-- Apply freshly merged metadata to the book that is currently open.
--
-- The original code did `ui:onClose()` ... `ReaderUI:showReader()` by hand,
-- from the middle of a live UIManager callback. That is fatal for two reasons:
--   * onClose() runs PluginLoader:finalize(), which destroys the very plugin
--     instance whose Lua closure is still executing, and it closes the menu
--     dialog that UIManager is currently dispatching an event for -- the window
--     stack gets re-entered mid-callback.
--   * showReader() was then called on that half-destroyed stack.
--
-- ReaderUI:reloadDocument() is KOReader's own supported close-and-reopen path
-- (it is what "Reload document" does): it closes the reader cleanly and invokes
-- after_close_callback in the gap, which is exactly where the sidecar write
-- belongs. Returns false when there is no open reader for this file.
-- Re-entrancy guard. Two auto triggers (download-on-open and download-all-on-open)
-- could both fire for the same open book, and each issued a full
-- ReaderUI:reloadDocument -- a document teardown/reopen cycle per trigger, with
-- no guard, from inside a scheduled task while a progress dialog was up.
local applying = false

-- The persisted one-shot latch, cleared by the showReader hook as the reloaded
-- document comes up. It has to be set before the reload (the hook runs inside
-- it) and cleared here when no reload happens.
local function set_skip_next_open(value)
    pcall(function()
        G_reader_settings:saveSetting("booksync_skip_auto_download", value)
    end)
end

-- Run `apply_fn` against the book at `file`, going through reloadDocument when
-- the reader is open and falling back to a plain sidecar write when it is not.
-- Returns true when the data was written either way.
--
-- The latch bookkeeping lives HERE rather than at the call sites because the
-- two halves are only safe together. Callers used to write the latch, call
-- apply_to_open_book, and clear it only on the success path. But five of its
-- exits return false WITHOUT ever calling reloadDocument -- the reader closed,
-- require failed, a nested apply, reloadDocument raised, or the callback never
-- ran. On those, no showReader event fires, so the latch stayed set: the next
-- book the user opened silently skipped its auto-download, and nothing but a
-- restart of KOReader cleared it. That is the "a latch left set by an
-- interrupted reload makes the NEXT book skip its auto-download" failure this
-- was supposed to have fixed.
function M.apply_with_latch(file, apply_fn)
    set_skip_next_open(true)
    local ok = M.apply_to_open_book(file, apply_fn)
    if not ok then
        -- No reload happened, so nothing else will clear it.
        set_skip_next_open(false)
        local wrote, err = apply_fn(file)
        if not wrote then
            logger.err("booksync: fallback sidecar write failed:", tostring(err))
        end
        return wrote == true
    end
    return true
end

function M.apply_to_open_book(file, apply_fn)
    if type(apply_fn) ~= "function" then return false end
    if applying then
        logger.info("booksync: apply_to_open_book already in progress, skipping duplicate")
        return false
    end
    if not M.is_reader_open(file) then
        local ok, err = apply_fn(file)
        if not ok then
            -- Callers read a false return as "the reader vanished, run the
            -- fallback write". Swallowing it here meant a failed write -- full
            -- disk, read-only mount, DocSettings error -- was reported to the
            -- user as a success, so nothing was ever retried.
            logger.err("booksync: apply failed:", tostring(err))
            return false
        end
        return true
    end

    local ok_read, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_read or not ReaderUI or not ReaderUI.instance then return false end

    local applied = false
    applying = true
    local ok, err = pcall(function()
        ReaderUI.instance:reloadDocument(function(closed_file)
            -- Reader is fully torn down here: safe to rewrite the sidecar.
            applied = apply_fn(closed_file) and true or false
            applying = false
        end)
    end)
    if not ok then
        applying = false
        logger.err("booksync: reloadDocument failed:", tostring(err))
        return false
    end
    if not applied then
        -- reloadDocument returned without ever running the callback (the reader
        -- was busy, or the document was already closing). Do not stay wedged.
        applying = false
    end
    return applied
end

-- Provider resolution. Returns a normalised adapter (see cloudapi.lua) that
-- hides both the credential difference and the fact that KOReader moved these
-- modules in 2024.x. Nil means "unsupported / misconfigured".
function M.get_api(server)
    return module("cloudapi").get(server)
end

-- Build the full cloud path for a filename, handling Dropbox vs WebDAV.
function M.get_cloud_path(server, api, filename)
    if type(server) ~= "table" then return nil end
    if server.type == "dropbox" then
        local url_base = tostring(server.url or "")
        if url_base:sub(-1) ~= "/" then
            url_base = url_base .. "/"
        end
        return url_base .. tostring(filename or "")
    end
    local CloudApi = module("cloudapi")
    return CloudApi.join(CloudApi.join(server.address, server.url), filename)
end

-- Unified upload / download across providers.
--
-- These two are the narrowest waist in the whole plugin: every metadata
-- transfer funnels through here. socket.http raises on DNS failure, refused
-- connections, timeouts and malformed URLs -- routine on a mobile network, and
-- fatal if they escape into UIManager's event loop. Catching here means every
-- caller just sees "failed" and takes its own error path.
-- The etag the cloud currently reports for one file, or nil when the server
-- does not publish one. Used to make an upload conditional: we only overwrite
-- a file that is still the one we based our work on.
function M.get_cloud_etag(server, api, cloud_path)
    if not (api and api.list) then return nil end
    local ok, items = pcall(function() return api:list(cloud_path, false) end)
    if not ok or type(items) ~= "table" then return nil end
    for _, item in ipairs(items) do
        if type(item) == "table" and item.etag and item.etag ~= "" then
            return item.etag
        end
    end
    return nil
end

function M.api_upload(server, api, cloud_path, local_path, progress_callback, expected_etag)
    if not (api and api.upload) then return nil end
    if expected_etag ~= nil then
        local ok, code = pcall(function()
            return api:upload(cloud_path, local_path, expected_etag)
        end)
        if ok then return code end
        logger.err("booksync: conditional upload failed:", tostring(code))
        return nil
    end
    return api:upload(cloud_path, local_path)
end

function M.api_download(server, api, cloud_path, local_path, progress_callback)
    if not (api and api.download) then return nil end
    return api:download(cloud_path, local_path, progress_callback)
end

-- Common pre-flight checks for any cloud operation.
-- Returns (server, api) or (nil, nil, error_type).
function M.check_preconditions()
    local server = M.get_server()
    if not server then
        return nil, nil, ERROR_TYPES.NO_SERVER_CONFIG
    end
    -- An empty cloud directory used to sail straight through here: get_cloud_path
    -- joins address + url, so url="" builds a perfectly valid path pointing at
    -- the WebDAV/Dropbox ROOT. The sync then ran, and reported success, against
    -- a folder the user never chose. Ten call sites each checked this by hand,
    -- which is exactly the kind of check that one of them forgets.
    if type(server.url) ~= "string" or server.url == "" then
        return nil, nil, ERROR_TYPES.NO_CLOUD_DIR
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        return nil, nil, ERROR_TYPES.NO_NETWORK
    end
    local api = M.get_api(server)
    if not api then
        return nil, nil, ERROR_TYPES.UNSUPPORTED_SERVER
    end
    return server, api, nil
end

-- The same three checks, for the paths that are driven from a menu entry and
-- have to tell the user what to do rather than return an error code. Returns
-- server, api, or nil after having already shown a message.
--
-- This is the single place the wording lives. It replaced twelve copies of the
-- same if/return/showMsg ladder spread over manual_sync.lua and book_sync.lua,
-- which is why the set had drifted: some copies checked the network, some did
-- not, and only the ones that remembered had a "please configure" message.
function M.check_preconditions_or_notify()
    local server = M.get_server()
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
    local api = M.get_api(server)
    if not api then
        notify.hint(_("Only WebDAV and Dropbox are supported"))
        return nil, nil
    end
    return server, api
end

-- ============================================================================
-- The name a book has in the cloud
-- ============================================================================
--
-- Fixed, and derived every time: 书名_作者.lua (see naming.lua).
--
-- A version of this decided the name ONCE and stored it in the sidecar, so
-- that a device which disagreed about the title would still find the file.
-- That was wrong, and in a way that mattered: the title is the name of the
-- book, and a file that does not follow it stops being the name of the book.
-- Renaming a book in KOReader and having the cloud still hold the old title
-- under a filename nobody can predict is worse than a name that is simply
-- recomputed. One rule, applied everywhere, every time.
--
-- The consequence is worth stating plainly: editing a title moves the file.
-- The old .lua is left in the cloud rather than renamed or deleted, because
-- deleting needs a name this design deliberately does not remember. Renaming a
-- book therefore leaves one orphaned file per rename, and the user may want
-- to clear those out of the cloud browser from time to time.

function M.get_cloud_filename(book)
    return module("naming").metadata_name(book)
end

-- G_reader_settings holds this as a JSON blob, so a truncated/hand-edited
-- setting makes json.decode return nil *or throw*. Every caller in the plugin
-- immediately does server.url / server.type on the result, so an undecodable
-- setting used to crash the whole sync path. Normalise to nil here instead.
function M.get_server()
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if type(server_json) ~= "string" or server_json == "" then
        return nil
    end
    local ok, server = pcall(json.decode, server_json)
    if not ok or type(server) ~= "table" then
        logger.warn("booksync: cloud_server_object is corrupt, ignoring it")
        return nil
    end
    return server
end

function M.save_server_settings(server)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    G_reader_settings:saveSetting("cloud_provider_type", server.type)
    notify.success(T(_("Cloud storage configured:\n%1"), server.url))
end



local function get_plugin()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.BookSync then
        return ReaderUI.instance.BookSync
    end
    return nil
end

function M.get_settings()
    return G_reader_settings:readSetting("booksync_plugin") or {}
end

function M.is_json_upload_enabled()
    return M.get_settings().upload_json == true
end

function M.clean_for_json(data)
    if type(data) ~= "table" then
        return data
    end
    
    local clean = {}
    for k, v in pairs(data) do
        local t = type(v)
        if t == "table" then
            clean[k] = M.clean_for_json(v)
        elseif t == "string" or t == "number" or t == "boolean" then
            clean[k] = v
        end
    end
    return clean
end

local function generate_random_string(length)
    length = length or 8
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local result = ""
    for i = 1, length do
        local rand = math.random(1, #chars)
        result = result .. chars:sub(rand, rand)
    end
    return result
end

local function datetime_to_timestamp(datetime_str)
    if not datetime_str then
        return nil
    end
    local year, month, day, hour, min, sec = datetime_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    if not year then
        return nil
    end
    local dt = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    })
    -- os.time interprets the date table as local time and returns the
    -- correct UTC-based Unix timestamp, so no manual timezone offset is
    -- needed (the previous -8h hardcoding broke non-UTC+8 devices).
    return dt * 1000
end

local function datetime_to_iso(datetime_str)
    if not datetime_str then
        return nil
    end
    local timestamp_ms = datetime_to_timestamp(datetime_str)
    if not timestamp_ms then
        return nil
    end
    local seconds = math.floor(timestamp_ms / 1000)
    local millis = timestamp_ms % 1000
    local utc_time = os.date("!%Y-%m-%dT%H:%M:%S", seconds)
    return string.format("%s.%03dZ", utc_time, millis)
end

local function generate_id(annotation_type, datetime_str)
    local timestamp_ms = datetime_to_timestamp(datetime_str) or (os.time() * 1000)
    local random_str = generate_random_string(8)
    return string.format("%s_%d_%s", annotation_type, timestamp_ms, random_str)
end

local function convert_annotation_to_notemark(ann)
    local text = ann.text or ""
    local datetime_str = ann.datetime or ""
    local datetime_updated = ann.datetime_updated or ann.datetime or ""
    local note_content = ann.note or ""
    local drawer = ann.drawer
    
    local notemark = {
        order = 1,
        total = 1,
        timestamp = datetime_to_iso(datetime_str) or os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    }
    
    if note_content and note_content ~= "" then
        notemark.id = generate_id("note", datetime_str)
        notemark.type = "note"
        notemark.text = text
        notemark.note = note_content
        notemark.noteType = "richtext"
        notemark.updated = datetime_to_iso(datetime_updated) or notemark.timestamp
        return notemark
    end
    
    if drawer == "lighten" then
        notemark.id = generate_id("highlight", datetime_str)
        notemark.type = "highlight"
        notemark.text = text
    elseif drawer == "underscore" then
        notemark.id = generate_id("htmltag", datetime_str)
        notemark.type = "html-tag"
        notemark.text = text
        notemark.htmlTag = "u"
    elseif drawer == "strikeout" then
        notemark.id = generate_id("question", datetime_str)
        notemark.type = "question"
        notemark.text = text
    elseif drawer == "invert" then
        notemark.id = generate_id("bold", datetime_str)
        notemark.type = "bold"
        notemark.text = text
    else
        return nil
    end
    
    return notemark
end

function M.convert_annotations_to_notemarkdata(annotations)
    if not annotations or type(annotations) ~= "table" or #annotations == 0 then
        return nil
    end
    
    local notemarks = {}
    for _, ann in ipairs(annotations) do
        local notemark = convert_annotation_to_notemark(ann)
        if notemark then
            table.insert(notemarks, notemark)
        end
    end
    
    if #notemarks == 0 then
        return nil
    end
    
    return {
        NoteMarkData = {
            notemarks = notemarks
        }
    }
end

function M.convert_metadata_to_json(lua_path)
    if not lua_path or not lfs.attributes(lua_path, "mode") then
        return nil
    end
    
    local merge = module("merge")
    local metadata = merge.load_metadata(lua_path)
    if not metadata then
        return nil
    end
    
    local clean_data = M.clean_for_json(metadata)
    
    local ok, json_str = pcall(json.encode, clean_data)
    if not ok or not json_str then
        return nil
    end
    
    local json_tmp_path = lua_path .. ".json.tmp"
    local f = io.open(json_tmp_path, "w")
    if not f then
        return nil
    end
    f:write(json_str)
    f:close()
    
    return json_tmp_path
end

function M.convert_metadata_to_json_with_notemark(lua_path)
    if not lua_path or not lfs.attributes(lua_path, "mode") then
        return nil
    end
    
    local merge = module("merge")
    local metadata = merge.load_metadata(lua_path)
    if not metadata then
        return nil
    end
    
    local annotations = metadata.annotations
    local notemark_data = M.convert_annotations_to_notemarkdata(annotations)
    
    if not notemark_data then
        return nil
    end
    
    local output_data = notemark_data
    
    local ok, json_str = pcall(json.encode, output_data)
    if not ok or not json_str then
        return nil
    end
    
    local json_tmp_path = lua_path .. ".json.tmp"
    local f = io.open(json_tmp_path, "w")
    if not f then
        return nil
    end
    f:write(json_str)
    f:close()
    
    return json_tmp_path
end

function M.upload_dual_format(server, lua_path, lua_filename, book)
    local settings = M.get_settings()
    local use_notemark = settings.use_notemark_format == true
    
    local json_tmp_path
    if use_notemark then
        json_tmp_path = M.convert_metadata_to_json_with_notemark(lua_path)
    else
        json_tmp_path = M.convert_metadata_to_json(lua_path)
    end
    
    if not json_tmp_path then
        return
    end
    
    local json_success = M.upload_json_to_cloud(server, json_tmp_path, lua_filename)
    
    if json_success and book and book.title then
        local log_path = DataStorage:getDataDir() .. "/booksync_sync_log.txt"
        local f = io.open(log_path, "a")
        if f then
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            if use_notemark then
                f:write(string.format(_("[%s] JSON format uploaded (NoteMarkData): %s\n"), timestamp, book.title))
            else
                f:write(string.format(_("[%s] JSON format uploaded: %s\n"), timestamp, book.title))
            end
            f:close()
        end
    end
    
    os.remove(json_tmp_path)
end

function M.upload_json_to_cloud(server, json_path, lua_filename)
    if not json_path or not lfs.attributes(json_path, "mode") then
        return false
    end
    
    local api = M.get_api(server)
    if not api then
        return false
    end
    
    local json_filename = lua_filename:gsub("%.lua$", ".json")
    local cloud_path = M.get_cloud_path(server, api, json_filename)
    local code = M.api_upload(server, api, cloud_path, json_path)
    
    return type(code) == "number" and code >= 200 and code < 300
end

-- Fetch a metadata sidecar into the plugin temp directory.
--
-- The rule that decides the cloud name is fixed (naming.lua), but the cloud may
-- have been written when a different one was in effect. The canonical name is
-- tried first; the rest are read-only fallbacks, so an install that has been
-- syncing for months keeps finding its own files instead of failing with a 404
-- on every book.
--
-- Returns: ok, downloaded_file, code, tried_names
function M.fetch_metadata(book, progress_callback)
    local server, api, err = M.check_preconditions()
    if not server then
        return false, nil, nil, err
    end
    if not M.ensure_download_dir() then
        return false, nil, nil, "download_dir_create_failed"
    end

    local cloud_filename = M.get_cloud_filename(book)
    local cloud_path = M.get_cloud_path(server, api, cloud_filename)
    local downloaded_file = DOWNLOAD_DIR .. cloud_filename
    local code = M.api_download(server, api, cloud_path, downloaded_file, progress_callback)

    -- stat once, and reuse it: the old chain asked three times about the same
    -- file, once more after removing it, to decide a single question.
    local dmode = lfs.attributes(downloaded_file, "mode")
    if type(code) ~= "number" or code ~= 200 or not dmode then
        if dmode then
            os.remove(downloaded_file)
        end
        if not dmode or type(code) ~= "number" or code ~= 200 then
            logger.warn("booksync: no metadata in the cloud for " .. tostring(book.file)
                .. " as " .. cloud_filename .. " (HTTP " .. tostring(code) .. ")")
            -- A 404 says the name was not found, and nothing else. Since the
            -- name is computed from this device's own view of the title, that
            -- leaves four causes that are indistinguishable from the message:
            -- the cloud holds it under a name an older version wrote, this
            -- device has a different title, the book was never uploaded from
            -- here, or the metadata directory is pointed somewhere else.
            -- Listing the directory turns "the cloud has nothing" into an
            -- answerable question. It costs one PROPFIND, and only on a 404 --
            -- a network failure does not reach it, so a flapping connection
            -- cannot turn every auto sync into a directory listing.
            if code == 404 then
                M.log_cloud_metadata_dir(server, api, cloud_filename)
            end
        end
        return false, nil, code, cloud_filename
    end
    return true, downloaded_file, code, cloud_filename
end

-- What is actually in the metadata directory. This is the answer to "but the
-- cloud has it", which the failure message cannot give on its own.
function M.log_cloud_metadata_dir(server, api, wanted)
    local ok_dir, dir_path = pcall(M.get_cloud_path, server, api, nil)
    if not ok_dir or not dir_path then dir_path = "" end
    local ok_list, items = pcall(function() return api:list(dir_path, false) end)
    if not ok_list or type(items) ~= "table" then
        logger.warn("booksync: could not list the metadata directory at "
            .. tostring(dir_path))
        return
    end
    local names = {}
    for _i, item in ipairs(items) do
        if type(item) == "table" and item.text then
            names[#names + 1] = tostring(item.text):gsub("/$", "")
        end
    end
    table.sort(names)
    if #names == 0 then
        logger.warn("booksync: the metadata directory is empty, so "
            .. tostring(wanted) .. " was never uploaded from any device")
        return
    end
    -- A directory with thousands of books would flood the log, and the tail is
    -- the part that says whether this book is there under another name.
    local shown, total = {}, #names
    local from = 1
    if total > 30 then from = total - 29 end
    for i = from, total do shown[#shown + 1] = names[i] end
    logger.warn("booksync: " .. total .. " file(s) in the metadata directory, "
        .. (from > 1 and ("showing the last " .. #shown .. ", looking for "
            .. tostring(wanted)) or ("looking for " .. tostring(wanted))) .. ": "
        .. table.concat(shown, ", "))
end

function M.upload_book(book)
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = (current_ui and current_ui.document and current_ui.document.file == book.file)
    
    if is_currently_open then
        current_ui:saveSettings()
        UIManager:broadcastEvent(Event:new("FlushSettings"))
    end
    
    if not book.metadata or not lfs.attributes(book.metadata, "mode") then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    
    local server, api, err = M.check_preconditions()
    if not server then
        return false, err
    end
    
    local cloud_filename = M.get_cloud_filename(book)
    
    if #cloud_filename > 255 then
        return false, ERROR_TYPES.FILENAME_TOO_LONG
    end
    
    local cloud_path = M.get_cloud_path(server, api, cloud_filename)
    local etag = M.get_cloud_etag(server, api, cloud_path)
    local code = M.api_upload(server, api, cloud_path, book.metadata, nil, etag)

    -- 412 means the cloud copy changed after we read it, so another device
    -- wrote in between. Merging their work into ours and trying again is the
    -- whole point: without this we silently overwrite whatever they saved.
    if code == 412 and M.merge_conflict_count == nil then
        M.merge_conflict_count = 0
    end
    local retried = false
    if code == 412 then
        M.merge_conflict_count = (M.merge_conflict_count or 0) + 1
        if M.merge_conflict_count <= 2 then
            logger.warn("booksync: " .. tostring(cloud_filename)
                .. " changed on another device, merging and retrying ("
                .. tostring(M.merge_conflict_count) .. ")")
            retried = M.retry_upload_after_conflict(server, api, book, cloud_filename, cloud_path)
        end
    end
    M.merge_conflict_count = nil

    if retried then
        return true
    end

    if type(code) == "number" and code >= 200 and code < 300 then
        if M.is_json_upload_enabled() then
            M.upload_dual_format(server, book.metadata, cloud_filename, book)
        end
        return true
    end
    
    return false, http_reason(code)
end

-- Fetch the other device's copy, merge it with the local sidecar, write the
-- union back locally, and only then upload. The local file is the authority
-- for what we keep, so a conflict can never lose data on this device.
function M.retry_upload_after_conflict(server, api, book, cloud_filename, cloud_path)
    local Merger = module("merge")
    if not M.ensure_local_metadata(book) then return false end
    -- The conflict stage lives in the download dir, which nothing on this path
    -- has created yet: upload_book normally never downloads. Without this the
    -- merge always failed with "cannot open ... for writing" and the upload was
    -- reported as a conflict failure rather than being resolved.
    if not M.ensure_download_dir() then
        logger.err("booksync: cannot stage a conflict merge (", tostring(cloud_path), ")")
        return false
    end

    local stage = DOWNLOAD_DIR .. cloud_filename .. ".conflict"
    local code = M.api_download(server, api, cloud_path, stage)
    if type(code) ~= "number" or code ~= 200 then
        pcall(os.remove, stage)
        return false
    end

    local merged = Merger.merge(book.metadata, stage)
    pcall(os.remove, stage)
    if not merged then return false end

    local wrote, err = M.save_metadata_native(merged, book.file)
    if not wrote then
        logger.err("booksync: conflict merge could not be written locally:", tostring(err))
        return false
    end

    -- Re-read the etag: the other device may have written again while we were
    -- merging. A second 412 is handled by the caller's retry budget.
    local etag = M.get_cloud_etag(server, api, cloud_path)
    local ok = M.api_upload(server, api, cloud_path, book.metadata, nil, etag)
    return type(ok) == "number" and ok >= 200 and ok < 300
end

function M.download_book_merge(book, progress_callback)
    local Merger = module("merge")
    local is_currently_open = M.is_reader_open(book.file)

    if not M.ensure_local_metadata(book) then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end

    local server, api, err = M.check_preconditions()
    if not server then
        return false, err
    end

    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end

    local got, downloaded_file, code = M.fetch_metadata(book, progress_callback)
    if not got then
        return false, http_reason(code)
    end

    local merged_data = Merger.merge(book.metadata, downloaded_file)
    os.remove(downloaded_file)

    if not merged_data then
        return false, "merge_failed"
    end

    if is_currently_open then
        local plugin = get_plugin()
        if plugin and plugin.auto_sync then
            plugin.auto_sync:setSkipUpload(true)
        end
        -- The one-shot latch only has to outlive the reloadDocument below.
        -- Clearing it here (rather than in init(), on every menu entry) is what
        -- makes "open the menu" a read path again: a latch left set by an
        -- interrupted reload used to make the NEXT book skip its auto-download,
        -- and the only thing that reset it was opening this menu.
        if not M.apply_with_latch(book.file, function(f)
            local wrote = M.save_metadata_native(merged_data, f)
            if plugin and plugin.auto_sync then
                plugin.auto_sync:setSkipUpload(false)
            end
            return wrote
        end) then
            return false, "write_failed"
        end
        return true
    end

    local ok_w2, err_w2 = M.save_metadata_native(merged_data, book.file)
    if not ok_w2 then
        logger.err("booksync: sidecar write failed:", tostring(err_w2))
        return false, "write_failed"
    end
    return true
end


function M.download_book_merge_before_open(book)
    local Merger = module("merge")
    
    if not M.ensure_local_metadata(book) then
        return false, ERROR_TYPES.LOCAL_METADATA_NOT_EXISTS
    end
    
    local server, api, err = M.check_preconditions()
    if not server then
        return false, err
    end
    
    if not M.ensure_download_dir() then
        return false, "download_dir_create_failed"
    end
    
    local got, downloaded_file, code = M.fetch_metadata(book)
    if got then
        if lfs.attributes(downloaded_file, "mode") then
            local merged_data = Merger.merge(book.metadata, downloaded_file)
            os.remove(downloaded_file)
            
            if merged_data then
                local ok_wrote, err_wrote = M.save_metadata_native(merged_data, book.file)
                if not ok_wrote then
                    logger.err("booksync: sidecar write failed:", tostring(err_wrote))
                    return false, "write_failed"
                end
            else
                return false, "merge_failed"
            end
            
            return true
        end
    end
    
    return false, http_reason(code)
end

-- Download metadata to temp directory without closing current book
function M.download_to_temp(book, progress_callback)
    local server, api, err = M.check_preconditions()
    if not server then
        return nil, nil, err
    end

    if not M.ensure_download_dir() then
        return nil, nil, "download_dir_create_failed"
    end

    local got, downloaded_file, code, cloud_filename =
        M.fetch_metadata(book, progress_callback)
    if not got then
        return nil, nil, http_reason(code)
    end

    return downloaded_file, cloud_filename, nil
end

return M
