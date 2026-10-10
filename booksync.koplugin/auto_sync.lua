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
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = module("gettext_shim")
local T = require("ffi/util").template
local utils = module("utils")
local notify = module("notify")

-- A path ending in "/" makes ([^/]+)$ return nil, and an lfs.attributes "mode"
-- gate does not filter that case because "directory" is a truthy string -- so
-- every bare file:match("([^/]+)$") on these paths was a live index-nil crash
-- on the close/suspend hooks. One helper, one nil guard, used everywhere.
local function basename_of(path)
    if type(path) ~= "string" or path == "" then return "book" end
    local base = path:match("([^/]+)$")
    if not base or base == "" then base = path end
    local stem = base:gsub("%.[^%.]+$", "")
    if stem == "" then stem = base end
    return stem
end

-- Coalescing queue. Two triggers can fire in quick succession -- closing a
-- book queues the upload, and suspending a moment later queues another one for
-- the same book. The old behaviour DROPPED the second: it hit the is_syncing
-- guard and returned without a log line, so the last position the user
-- actually read was never backed up and nothing said so.
--
-- Only the latest request per kind is kept (a newer sync of the same book
-- supersedes an older one), and the queue lives in settings so a push that
-- failed while the network was down is retried after a restart instead of
-- being lost with the process.
local function pending_key(kind, file)
    return kind .. "|" .. tostring(file or "*")
end

local function queue_push(self, kind, file)
    local settings = self.settings
    if type(settings) ~= "table" then return end
    settings.pending_sync = settings.pending_sync or {}
    settings.pending_sync[pending_key(kind, file)] = true
    local n = 0
    for _ in pairs(settings.pending_sync) do n = n + 1 end
    logger.info("booksync: queued " .. kind .. " (" .. n .. " pending)")
end

local function queue_clear(self, kind, file)
    local settings = self.settings
    if type(settings) ~= "table" or type(settings.pending_sync) ~= "table" then return end
    settings.pending_sync[pending_key(kind, file)] = nil
end

local AutoSync = {
    is_syncing = false,
    is_book_syncing = false,
    is_all_syncing = false,
    skip_auto_upload = false,
    skip_auto_download = false,
    settings = nil,
    plugin = nil,
}

function AutoSync:new(plugin, settings)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.settings = settings
    obj.is_syncing = false
    obj.is_book_syncing = false
    obj.is_all_syncing = false
    obj.skip_auto_upload = false
    obj.skip_auto_download = false
    
    return obj
end

function AutoSync:shouldUpload(source)
    if source == "appstart" then
        return self.settings.auto_upload_last_book_on_start
    elseif source == "annotate" then
        return self.settings.auto_upload_on_annotate
    elseif source == "close" then
        return self.settings.auto_upload_on_close
    elseif source == "suspend" then
        return self.settings.auto_upload_on_suspend
    elseif source == "resume" then
        return self.settings.auto_upload_on_resume
    elseif source == "flush" then
        return self.settings.auto_upload_on_flush
    elseif source == "chapter" then
        return self.settings.auto_upload_on_chapter
    elseif source == "open" then
        return self.settings.auto_upload_on_open
    end
    return false
end

function AutoSync:shouldDownload(source)
    if source == "open" then
        return self.settings.auto_download_on_open
    end
    return false
end

function AutoSync:shouldUploadBook(source)
    if source == "close" then
        return self.settings.auto_upload_book_on_close
    elseif source == "suspend" then
        return self.settings.auto_upload_book_on_suspend
    elseif source == "open" then
        return self.settings.auto_upload_book_on_open
    end
    return false
end

-- Anything left in the queue when we come up again.
function AutoSync:pending_count()
    local settings = self.settings
    if type(settings) ~= "table" or type(settings.pending_sync) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(settings.pending_sync) do n = n + 1 end
    return n
end

function AutoSync:clear_pending()
    local settings = self.settings
    if type(settings) ~= "table" then return end
    settings.pending_sync = {}
end

function AutoSync:sync(document, is_upload, source)
    if not document or not self.settings then 
        return 
    end
    
    -- ===== 先获取文件路径 =====
    local file = document.file
    if not file or not lfs.attributes(file, "mode") then
        return
    end

    -- ===== 新增：检查是否在排除目录中 =====
    local exclude_dirs = self.settings.exclude_dirs or {}
    if utils.is_path_excluded(file, exclude_dirs) then
        if self:notify_enabled("skipped") then
            local book_title = document.title or (document.file and basename_of(document.file)) or "book"
            self:showNotification(book_title, _("Skipped: directory excluded"), nil, false, "skipped")
        end
        return
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if self:notify_enabled("error") then
            local book_title = document.title or (document.file and basename_of(document.file)) or "book"
            self:showNotification(book_title, _("Offline"), nil, false, "error")
        end
        return
    end
    
    local remote = module("remote")
    local server = remote.get_server()
    if not server then
        if self:notify_enabled("error") then
            local book_title = document.title or (document.file and basename_of(document.file)) or "book"
            self:showNotification(book_title, _("Cloud not set up"), nil, false, "error")
        end
        return
    end
    
    if not server.url or server.url == "" then
        if self:notify_enabled("error") then
            local book_title = document.title or (document.file and basename_of(document.file)) or "book"
            self:showNotification(book_title, _("Cloud folder not set"), nil, false, "error")
        end
        return
    end
    
    local api = remote.get_api(server)
    if not api then
        if self:notify_enabled("error") then
            local book_title = document.title or (document.file and basename_of(document.file)) or "book"
            self:showNotification(book_title, _("Unsupported cloud service"), nil, false, "error")
        end
        return
    end

    if is_upload and self.skip_auto_upload then
        return
    end
    
    if not is_upload and self.skip_auto_download then
        return
    end
    
    if self.is_syncing then
        -- Something is already running. Queue this one instead of dropping it:
        -- the close-then-suspend sequence used to land here and the last read
        -- position was silently never backed up.
        queue_push(self, "metadata", document.file)
        return
    end
    
    if is_upload then
        if not self:shouldUpload(source) then
            return
        end
    else
        if not self:shouldDownload(source) then
            return
        end
    end
    
    local source_desc = ""
    if source == "annotate" then
        source_desc = _("Edit annotation")
    elseif source == "close" then
        source_desc = _("Close book")
    elseif source == "suspend" then
        source_desc = _("Device suspend")
    elseif source == "open" then
        source_desc = _("Open book")
    end
    
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    -- getDocProps() parses the document; during close/suspend the reader may be
    -- half torn down, so never let it throw into an unprotected caller.
    local props = {}
    if self.plugin and self.plugin.ui and self.plugin.ui.bookinfo then
        local ok_props, p = pcall(function()
            return self.plugin.ui.bookinfo:getDocProps(file, nil, true)
        end)
        if ok_props and type(p) == "table" then
            props = p
        elseif not ok_props then
            -- Swallowing this made the plugin upload under the FILENAME instead
            -- of the real title, with no log line at all -- which is exactly
            -- the corrupt-document case that needs cloud recovery.
            logger.err("booksync: getDocProps failed, falling back to filename:", tostring(p))
        end
    end
    local title = props.title or props.display_title or basename_of(file)
    if type(title) ~= "string" then title = tostring(title) end
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end
    
    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = basename_of(file),
        author = author,
    }
    
    if not metadata_file or not lfs.attributes(metadata_file, "mode") then
        local error_info = {
            reason = _("Local metadata file not found"),
            solution = _("Please open the book first to generate metadata file")
        }
        self:writeLog(book, source_desc, is_upload, false, error_info.reason, nil, error_info.solution)
        self:updateLastSync(_("Auto sync") .. "(" .. source_desc .. ")-" .. _("Failed"))
        self:showNotification(book.title, T(_("Sync failed: %1"), error_info.reason), nil, false, "error")
        return
    end
    
    self.is_syncing = true
    -- Whether the transfer actually succeeded, as opposed to merely not
    -- raising. The queue decision below used to key off the pcall, which meant
    -- a push that failed because the network was down was dequeued anyway --
    -- and the queue's entire reason for existing (see the comment on
    -- queue_push) is that such a push is retried after a restart.
    local sync_ok = false

    if not utils.scheduleSafe("auto_sync:is_syncing", 0, function()
        -- UIManager:_checkTasks() calls task.action() with no pcall, so any
        -- error escaping this closure propagates straight into the main loop
        -- and takes the app down. Wrap it, and -- just as important -- make
        -- sure is_syncing is cleared no matter how we leave, otherwise one
        -- failure wedges the "already syncing" guard and every later auto sync
        -- silently does nothing for the rest of the session.
        local ok_run, err = pcall(function()
            local remote = module("remote")
            local success, error_type

            if is_upload then
                success, error_type = remote.upload_book(book)

                if success then
                    sync_ok = true
                    self:writeLog(book, source_desc, true, true)
                    self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload successful"))
                    self:showNotification(book.title, _("Metadata uploaded"), nil, true, "success")
                else
                    local error_info = remote.get_error_message(error_type, true)
                    self:writeLog(book, source_desc, true, false, error_info.reason, nil, error_info.solution)
                    self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload failed"))
                    local fail_msg = T(_("Upload failed: %1"), error_info.reason)
                    self:showNotification(book.title, fail_msg, nil, false, "error")
                end
            else
                success, error_type = remote.download_book_merge(book)

                -- The log keeps the mode (a historical record of how a run
                -- resolved); the toast does not. There is no longer a second
                -- mode to tell it apart from, so " - Merge" on screen was
                -- noise that also made every line longer than it needed to be.
                if success then
                    self:writeLog(book, source_desc, false, true, nil, "merge")
                    sync_ok = true
                    self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Download successful") .. "(" .. _("Merge") .. ")")
                    self:showNotification(book.title, _("Updated from cloud"), nil, true, "success")
                else
                    local error_info = remote.get_error_message(error_type, false)
                    self:writeLog(book, source_desc, false, false, error_info.reason, nil, error_info.solution)
                    self:updateLastSync(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Download failed"))
                    local fail_msg = T(_("Update failed: %1"), error_info.reason)
                    self:showNotification(book.title, fail_msg, nil, false, "error")
                end
            end
        end)

        if not ok_run then
            logger.err("booksync: auto sync crashed:", tostring(err))
        elseif sync_ok then
            queue_clear(self, "metadata", document.file)
        else
            -- Left in the queue on purpose: it is retried on the next start.
            logger.info("booksync: metadata push for " .. tostring(document.file)
                .. " did not succeed, left queued")
        end

        self.is_syncing = false
    end) then
        -- scheduling itself raised: nothing was queued, so nothing
        -- would ever clear the guard. Un-wedge it here instead of
        -- leaving the feature silently dead for the whole session.
        self.is_syncing = false
    end
end

function AutoSync:formatBookUploadError(error_type)
    local map = {
        file_not_found = _("Book file not found"),
        unsupported_format = _("Unsupported file format"),
        no_server_config = _("Cloud storage not configured"),
        no_network = _("Network disconnected"),
        unsupported_server = _("Unsupported cloud service"),
        path_error = _("Cannot build cloud path"),
        auth_failed = _("Cloud authentication failed"),
        upload_failed = _("Upload failed"),
        list_failed = _("Cannot check cloud files"),
    }
    return map[error_type] or _("Unknown error")
end

-- Automatically upload the currently open book's file to the cloud, but only
-- when no file with the same name already exists there. Mirrors the metadata
-- auto-sync flow: same pre-checks (excluded dirs, network, cloud config) and
-- the same async scheduling so it never blocks the close/suspend path.
-- `file_override` lets the "on opening a book" trigger pass the path straight
-- from ReaderUI:showReader. At that moment ui.document is not reliably
-- populated yet, and a path we already have beats reading a half-built
-- document.
function AutoSync:syncBookFile(document, source, file_override)
    if not self.settings then
        return
    end

    local file = file_override or (document and document.file)
    if type(file) ~= "string" or not lfs.attributes(file, "mode") then
        return
    end

    local exclude_dirs = self.settings.exclude_dirs or {}
    if utils.is_path_excluded(file, exclude_dirs) then
        if self:notify_enabled("skipped") then
            local title = document.title or (basename_of(file)) or "book"
            self:showNotification(title, _("Book upload skipped: directory excluded"), nil, false, "skipped")
        end
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if self:notify_enabled("error") then
            local title = document.title or (basename_of(file)) or "book"
            self:showNotification(title, _("Offline"), nil, false, "error")
        end
        return
    end

    local remote = module("remote")
    local server = remote.get_server()
    if not server then
        if self:notify_enabled("error") then
            local title = document.title or (basename_of(file)) or "book"
            self:showNotification(title, _("Cloud not set up"), nil, false, "error")
        end
        return
    end

    if self.is_book_syncing then
        queue_push(self, "book", file)
        return
    end

    local props = {}
    if self.plugin and self.plugin.ui and self.plugin.ui.bookinfo then
        local ok_props, p = pcall(function()
            return self.plugin.ui.bookinfo:getDocProps(file, nil, true)
        end)
        if ok_props and type(p) == "table" then
            props = p
        end
    end
    local title = props.title or props.display_title
        or basename_of(file)
    if type(title) ~= "string" then title = tostring(title) end
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end


    local source_desc = ""
    if source == "close" then
        source_desc = _("Close book")
    elseif source == "suspend" then
        source_desc = _("Device suspend")
    elseif source == "open" then
        source_desc = _("Open book")
    end

    self.is_book_syncing = true

    if not utils.scheduleSafe("auto_sync:is_book_syncing", 0, function()
        local book_ok = false
        local ok_run, err = pcall(function()
            local BookSync = module("book_sync")
            local success, status = BookSync.upload_book_if_missing(file, {
                title = title,
                author = author,
            })

            if success and status == "uploaded" then
                book_ok = true
                self:updateLastSync(_("Book sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload successful"))
                self:showNotification(title, _("Book uploaded"), nil, true, "success")
            elseif success and status == "already_exists" then
                -- The cloud already has it, so there is nothing left to do and
                -- re-trying would never change the answer. Treat it as done.
                book_ok = true
                self:updateLastSync(_("Book sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Skipped (already exists)"))
                self:showNotification(title, _("Book upload skipped: already in cloud"), nil, true, "skipped")
            else
                local error_msg = self:formatBookUploadError(status)
                self:updateLastSync(_("Book sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("Upload failed"))
                self:showNotification(title, T(_("Book upload failed: %1"), error_msg), nil, false, "error")
            end
        end)

        if not ok_run then
            logger.err("booksync: auto book upload crashed:", tostring(err))
        elseif book_ok then
            -- This entry used to never be cleared at all: queue_clear was only
            -- ever called for "metadata", so every queued book was replayed on
            -- every single start, forever, and the queue only ever grew.
            queue_clear(self, "book", file)
        else
            logger.info("booksync: book push for " .. tostring(file)
                .. " did not succeed, left queued")
        end

        self.is_book_syncing = false
    end) then
        -- scheduling itself raised: nothing was queued, so nothing
        -- would ever clear the guard. Un-wedge it here instead of
        -- leaving the feature silently dead for the whole session.
        self.is_book_syncing = false
    end
end

-- Whether the "auto sync ALL books metadata" toggle is on for the given source.
function AutoSync:shouldUploadAll(source)
    if source == "close" then
        return self.settings.auto_upload_all_on_close
    elseif source == "suspend" then
        return self.settings.auto_upload_all_on_suspend
    elseif source == "open" then
        return self.settings.auto_upload_all_on_open
    end
    return false
end

function AutoSync:shouldDownloadAll(source)
    if source == "appstart" then
        return self.settings.auto_download_all_on_start
    elseif source == "open" then
        return self.settings.auto_download_all_on_open
    elseif source == "resume" then
        return self.settings.auto_download_all_on_resume
    end
    return false
end

-- Scan the current directory for all books and batch-sync their metadata.
-- This reuses manual_sync.lua's batchSyncAllBooks so the scan + progress
-- dialog + batch upload/download logic is shared with the manual menu entry.
function AutoSync:syncAllBooksMetadata(is_upload, source)
    if not self.settings then return end
    local document = self.plugin and self.plugin.ui and self.plugin.ui.document
    local file = document and document.file

    -- Determine scan root: prefer the book's directory (for close/suspend we
    -- are inside the reader), fall back to FileManager's current path, and
    -- finally to the last opened book's directory.
    local root_dir
    if file then
        root_dir = file:match("^(.*)/[^/]+$")
    end
    if not root_dir then
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        -- fm.path does not exist. Current KOReader keeps the folder on the
        -- file chooser (fm.file_chooser.path, which is what PathChanged events
        -- carry) and the folder the browser was opened at on fm.root_path.
        -- self.path is referenced twice in filemanager.lua and assigned
        -- nowhere, so the old `fm.path` check was always nil and the
        -- current-directory fallback silently never ran -- which is why
        -- "On app start" would do nothing on a fresh install with no
        -- last_book_file yet, and say nothing about it.
        if fm then
            root_dir = (fm.file_chooser and fm.file_chooser.path) or fm.root_path
        end
    end
    if not root_dir then
        local last = self.settings.last_book_file
        if last and lfs.attributes(last, "mode") == "file" then
            root_dir = last:match("^(.*)/[^/]+$")
        end
    end
    if not root_dir then
        -- Nothing to scan: no open book, no browser to ask, no last book on
        -- record. Silent here is the worst option -- the user turned on an
        -- automatic feature and is owed an answer either way.
        logger.warn("booksync: all-books skipped, no directory to scan (source=" .. tostring(source) .. ")")
        if self:notify_enabled("skipped") then
            self:showNotification(_("All books"), _("No books to sync"), nil, false, "skipped")
        end
        return
    end

    local exclude_dirs = self.settings.exclude_dirs or {}
    if utils.is_path_excluded(root_dir, exclude_dirs) then
        if self:notify_enabled("skipped") then
            self:showNotification(_("All books"), _("All books skipped: directory excluded"), nil, false, "skipped")
        end
        return
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if self:notify_enabled("error") then
            self:showNotification(_("All books"), _("Offline"), nil, false, "error")
        end
        return
    end

    local remote = module("remote")
    local server = remote.get_server()
    if not server or not server.url or server.url == "" then
        if self:notify_enabled("error") then
            self:showNotification(_("All books"), _("Cloud not set up"), nil, false, "error")
        end
        return
    end

    if self.is_all_syncing then
        queue_push(self, "allbooks", root_dir)
        return
    end

    -- Downloads always merge; the Overwrite mode is gone.
    local is_merge = true
    local source_desc = ""
    if source == "close" then
        source_desc = _("Close book")
    elseif source == "suspend" then
        source_desc = _("Device suspend")
    elseif source == "open" then
        source_desc = _("Open book")
    elseif source == "appstart" then
        source_desc = _("App start")
    end

    -- The guard is released by the batch's on_done, so EVERY path that does
    -- not reach doBatchSync has to release it itself. The two early returns
    -- below (no books found / scan failed) were missed once, and the symptom
    -- was the whole feature dying silently for the rest of the session: one
    -- book close on a device whose metadata lives somewhere the scan does not
    -- look, and from then on every app-start, open, close, suspend and resume
    -- "all books" trigger returned at the guard with no log and no message.
    local function release_guard(why)
        if self.is_all_syncing then
            logger.warn("booksync: all-books guard released (" .. tostring(why) .. ")")
        end
        self.is_all_syncing = false
    end

    self.is_all_syncing = true

    if not utils.scheduleSafe("auto_sync:is_all_syncing", 0, function()
        local ok_run, err = pcall(function()
            local ManualSync = module("manual_sync")
            local manual = ManualSync:new(self.plugin, self)

            -- Use the shared scan helper (handles doc/dir/hash metadata locations).
            -- It is cooperative -- the walk is spread over several ticks so the
            -- screen keeps updating -- so the result arrives in a callback.
            manual:scanAllBooks(function(books)
                if books == nil then
                    -- A crash inside a scheduled task never reaches the user:
                    -- the pcall above logs it and that is all, so the run
                    -- silently disappears. Say it here, where we still know
                    -- what it was.
                    self:showNotification(_("All books"), _("Scan failed"), nil, false, "error")
                    release_guard("scan failed")
                    return
                end
                if #books == 0 then
                    if self:notify_enabled("skipped") then
                        self:showNotification(_("All books"), _("No books to sync"), nil, false, "skipped")
                    end
                    release_guard("no books found")
                    return
                end

                local sync_type = is_upload
                    and (_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("All upload"))
                    or  (_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. source_desc .. ")-" .. _("All download"))

                -- doBatchSync returns as soon as the first item is queued; the
                -- guard and the timestamp belong to the real completion, or a
                -- second trigger can start a concurrent batch and "last sync"
                -- records a time the batch had not reached yet.
                -- close / suspend / open / start are all background moments: the
                -- reader is going away or the device is sleeping, so a modal
                -- progress box there is worse than no feedback at all.
                -- Say it is starting. Without this the only sign of an
                -- automatic run is the line that appears at the end, and on a
                -- slow connection that is minutes after the user stopped
                -- looking. A run that begins and a run that never began have
                -- to look different while it is happening.
                if self:notify_enabled("success") then
                    self:showNotification(_("All books"),
                        T(_("Syncing %1 book(s)..."), #books), nil, nil, "info")
                end

                local background = (source == "close" or source == "suspend"
                    or source == "open" or source == "appstart"
                    or source == "resume" or source == "pending")
                local function report(result)
                    local ok_n, failed_n, skipped_n = 0, 0, 0
                    for _ in pairs((result or {}).success or {}) do ok_n = ok_n + 1 end
                    for _ in pairs((result or {}).failed or {}) do failed_n = failed_n + 1 end
                    for _ in pairs((result or {}).skipped or {}) do skipped_n = skipped_n + 1 end

                    -- Say what happened.
                    --
                    -- A manual run shows a confirm box and a progress dialog, so
                    -- the user watches it. An automatic one passes background=true,
                    -- which suppresses the dialog entirely -- so when the batch
                    -- finished there was nothing at all on screen. The only trace
                    -- was the "Last sync" line, which lives at the bottom of a
                    -- menu the user has to go and open. From the outside, a
                    -- successful automatic download is indistinguishable from one
                    -- that never ran, and "it did not do anything" is the
                    -- reasonable conclusion to draw from that.
                    local total_n = ok_n + failed_n + skipped_n
                    if total_n == 0 then
                        self:showNotification(_("All books"), _("Nothing to sync"), nil, false, "skipped")
                    elseif failed_n > 0 then
                        self:showNotification(_("All books"),
                            T(_("%1 of %2 failed"), failed_n, total_n), nil, false, "error")
                    elseif skipped_n > 0 then
                        self:showNotification(_("All books"),
                            T(_("Updated %1, skipped %2"), ok_n, skipped_n), nil, false, "skipped")
                    else
                        self:showNotification(_("All books"),
                            T(_("Updated %1 book(s)"), ok_n), nil, true, "success")
                    end
                end

                manual:doBatchSync(is_upload, is_merge, books, function(res)
                    self:updateLastSync(sync_type)
                    report(res)
                    self.is_all_syncing = false
                    -- Cleared once the batch is genuinely finished. A crash part
                    -- way through leaves it queued so the next start retries it,
                    -- which is the whole point of the queue.
                    if not res or #res.failed == 0 then
                        queue_clear(self, "allbooks", nil)
                    end
                end, background)
            end)
        end)

        if not ok_run then
            logger.err("booksync: auto sync-all crashed:", tostring(err))
            self:showNotification(_("All books"), T(_("Sync failed: %1"), tostring(err)),
                nil, false, "error")
            release_guard("crashed")
        end

        -- Otherwise the guard is cleared by the batch's on_done callback, which
        -- is the only place that runs once the batch has really finished.
    end) then
        -- scheduling itself raised: nothing was queued, so nothing would ever
        -- clear the guard.
        self:showNotification(_("All books"), _("Could not start the sync"), nil, false, "error")
        release_guard("scheduling failed")
    end
end

-- Whether this class of notification is wanted.
--
-- There used to be one switch for everything, which meant the only way to
-- silence the endless "uploaded" pings from a successful auto sync was to also
-- silence the failures you actually wanted to see. `kind` splits them:
--   success -- it worked
--   error   -- it did not work, and the user needs to know
--   skipped -- it deliberately did nothing (excluded directory, already in
--              the cloud, nothing to do); the noisiest of the three
--
-- An absent key means on, so an install that has never touched these behaves
-- exactly as it did under the single switch.
function AutoSync:notify_enabled(kind)
    local st = self.settings
    if type(st) ~= "table" then return false end
    if kind == "success" then return st.auto_sync_notify_success ~= false end
    if kind == "error"   then return st.auto_sync_notify_error   ~= false end
    if kind == "skipped" then return st.auto_sync_notify_skipped ~= false end
    -- An unrecognised kind is shown rather than swallowed. Every call site
    -- passes one of the three above; this only matters if a future caller
    -- forgets, and losing a failure notice is worse than an extra line.
    return true
end

-- The one way auto sync talks to the user. Every call site funnels through
-- here so the three-way user preference (success / error / skipped) is applied
-- in exactly one place, and so the title truncation below cannot be forgotten
-- at a new call site.
function AutoSync:showNotification(title, operation, mode, is_success, kind)
    if not self:notify_enabled(kind) then
        return
    end

    -- `title` comes from book metadata (props.title / display_title), which is
    -- not guaranteed to be a string. #title on a table or a nil-ish value was
    -- a straight "attempt to get length of" error inside a scheduled task.
    if type(title) ~= "string" then
        title = tostring(title or "book")
    end

    local max_bytes = 30
    local display_title = title
    if #title > max_bytes then
        local truncated = title:sub(1, max_bytes)
        local util = require("util")
        display_title = util.fixUtf8(truncated, "") .. "..."
    end

    -- "skipped" is neither a success nor a failure: the sync deliberately did
    -- nothing (excluded directory, already in the cloud). Painting it green
    -- or red trains the user to ignore the colour, so it stays a plain line.
    --
    -- `kind` is authoritative when it is present. It cannot be inferred from
    -- is_success: a skipped upload is reported with is_success = true (nothing
    -- went wrong), and reading that flag first would colour every skip green.
    -- is_success is only the fallback for a caller that passes no kind.
    local level
    if kind == "error" then
        level = "error"
    elseif kind == "success" then
        level = "success"
    elseif kind == "info" or kind == "skipped" then
        -- "info" is progress ("Syncing 40 book(s)..."), which is neither an
        -- outcome nor a problem. It would land here by falling through the
        -- is_success checks, but relying on that is how a progress line ends
        -- up painted green one refactor later.
        level = "info"
    elseif is_success == false then
        level = "error"
    elseif is_success == true then
        level = "success"
    else
        level = "info"
    end

    notify[level](notify.compose(display_title, operation, mode))
end

function AutoSync:updateLastSync(descriptor)
    if not self.plugin or not self.plugin.plugin_id then return end
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. descriptor .. ")"
    G_reader_settings:saveSetting(self.plugin.plugin_id, self.settings)
end

function AutoSync:writeLog(book, source_desc, is_upload, success, error_reason, download_mode, solution)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id(false)
    
    local operation_type = ""
    if is_upload then
        operation_type = string.format(_("Metadata sync") .. "-" .. _("Auto sync") .. "-%s-" .. _("Upload"), source_desc)
    else
        -- Always Merge: the download_mode argument is kept for signature
        -- compatibility but no longer varies, and letting it fall through to
        -- the "Overwrite" arm would write a mode that can no longer happen.
        operation_type = string.format(_("Metadata sync") .. "-" .. _("Auto sync") .. "-%s-" .. _("Download") .. "(%s)", source_desc, _("Merge"))
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    if success then
        table.insert(new_record, string.format(_("[Success] ✓ %s"), book.title or book.book_basename))
    else
        table.insert(new_record, string.format(_("[Failed] ✗ %s"), book.title or book.book_basename))
        table.insert(new_record, string.format(_("Reason: %s"), error_reason or _("Unknown error")))
        if solution then
            table.insert(new_record, string.format(_("Solution: %s"), solution))
        end
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
end

function AutoSync:setSkipUpload(skip)
    self.skip_auto_upload = skip
end

function AutoSync:setSkipDownload(skip)
    self.skip_auto_download = skip
end

-- Replay whatever a previous session could not finish. The queue lives in
-- settings, so a push that failed because the device was offline -- or that was
-- dropped by a trigger collision right before KOReader was killed -- is still
-- there after a restart instead of being lost with the process.
function AutoSync:replay_pending()
    local settings = self.settings
    if type(settings) ~= "table" or type(settings.pending_sync) ~= "table" then return 0 end
    local queued = {}
    for key in pairs(settings.pending_sync) do
        local kind, file = key:match("^([^|]+)|(.+)$")
        if kind then queued[#queued + 1] = { kind = kind, file = file } end
    end
    if #queued == 0 then return 0 end

    table.sort(queued, function(a, b)
        -- books first, then directories, then everything else
        local rank = { book = 1, metadata = 2, allbooks = 3 }
        return (rank[a.kind] or 9) < (rank[b.kind] or 9)
    end)

    local n, failed = 0, 0
    for _, item in ipairs(queued) do
        logger.info("booksync: replaying queued " .. item.kind .. " for " .. tostring(item.file))
        local ok, err
        if item.kind == "book" then
            local document = { file = item.file }
            ok, err = pcall(function() self:syncBookFile(document, "pending", item.file) end)
        elseif item.kind == "metadata" then
            local document = { file = item.file }
            ok, err = pcall(function() self:sync(document, true, "pending") end)
        elseif item.kind == "allbooks" then
            ok, err = pcall(function() self:syncAllBooksMetadata(true, "pending") end)
        else
            -- A key whose kind nothing handles. Left in the queue it would be
            -- re-examined on every start forever, so drop it and say so --
            -- otherwise the queue can only ever accumulate.
            logger.err("booksync: dropping queued item of unknown kind \"" ..
                tostring(item.kind) .. "\"")
            if type(self.settings.pending_sync) == "table" then
                self.settings.pending_sync[item.kind .. "|" .. tostring(item.file)] = nil
            end
            -- Handled, not failed: there is nothing left to retry, so counting
            -- it as a replay failure would show the user a "could not be
            -- completed" warning about an entry that no longer exists.
            ok = true
        end

        if ok then
            -- What "replayed" means: the call was made without raising. The
            -- entry clears itself if the transfer really succeeded; if it did
            -- not, it stays queued for the next attempt, which is the intended
            -- behaviour rather than something to paper over here.
            n = n + 1
        else
            failed = failed + 1
            -- Previously swallowed entirely. A queued push that keeps raising
            -- on every launch is a real problem, and the user is the only one
            -- who can clear it.
            logger.err("booksync: replay of " .. tostring(item.kind) .. " for "
                .. tostring(item.file) .. " failed:", tostring(err))
        end
    end
    if failed > 0 then
        -- A whole sentence in a one-line toast, wrapping on an e-ink screen.
        -- The reassuring half ("will be retried") is the point: this is not
        -- lost data, so the message says so and stops.
        self:showNotification(nil,
            T(_("%1 queued sync(s) failed, will retry"), failed),
            nil, false, "error")
    end
    return n
end

return AutoSync