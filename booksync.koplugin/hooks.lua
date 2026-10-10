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

local Hooks = {}

-- The book's identity as the cloud knows it: the real title and author, not the
-- file name. naming.metadata_name() turns these into the exact key that
-- upload_book() wrote, which is the only way a download can find it.
--
-- Everything here is best-effort and total: any failure falls back to the file
-- name, because a wrong-but-consistent guess is better than an error that stops
-- the sync entirely.
local function readBookIdentity(file)
    local fallback = (file:match("([^/]+)$") or file):gsub("%.[^%.]+$", "")
    local title, author = nil, nil

    -- Hooks._live is the current plugin handle; the caller also holds a local
    -- `self_plugin` for the duration of its own scope, but that is not visible
    -- here, so the shared table is the one place both can reach.
    local live = Hooks._live or {}
    local plugin = live.plugin
    local bookinfo = plugin and plugin.ui and plugin.ui.bookinfo

    if bookinfo then
        local ok, props = pcall(function()
            -- no_open_document = true: reads cached doc_props from DocSettings
            -- and returns without touching the file. Safe on the open hook.
            return bookinfo:getDocProps(file, nil, true)
        end)
        if ok and type(props) == "table" then
            title = props.title or props.display_title
            author = props.authors
            if type(author) == "table" then author = author[1] end
        end
    end

    if type(title) ~= "string" or title == "" then title = fallback end
    if type(author) ~= "string" or author == "" then author = nil end
    return title, author
end

-- The hook markers below live on KOReader's OWN tables (ReaderUI,
-- ReaderAnnotation, ReaderBookmark, ReaderDeviceStatus), so once installed they
-- are never re-created -- not when the menu is reopened, and not when the
-- plugin itself is reloaded. Any object captured in a wrapper closure when the
-- hook was first installed therefore outlives its usefulness: after a reload
-- every automatic trigger kept calling the instance that PluginLoader had
-- already torn down, and toggling a setting in the reloaded plugin had no
-- effect on sync at all.
--
-- Hooks:new() runs on every entry into the plugin menu, so it is the one place
-- that is guaranteed to see the current objects. The wrappers resolve through
-- this table at CALL time instead of holding a capture.
Hooks._live = nil

function Hooks:new(plugin, auto_sync)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.auto_sync = auto_sync
    obj.settings = plugin.settings
    
    Hooks._live = { plugin = plugin, auto_sync = auto_sync, hooks = obj }
    
    return obj
end

function Hooks:hookAnnotationModified()
    local ReaderAnnotation = require("apps/reader/modules/readerannotation")
    if not ReaderAnnotation or ReaderAnnotation._booksync_hooked then
        return
    end
    
    local original = ReaderAnnotation.onAnnotationsModified
    if not original then
        return
    end
    
    ReaderAnnotation._booksync_hooked = true
    
    local self_auto_sync = self.auto_sync
    local last_delete_time = 0
    
    ReaderAnnotation.onAnnotationsModified = function(self_annot, items)
        local result = original(self_annot, items)

        -- This runs inside ReaderUI:handleEvent("CloseDocument") during reader
        -- teardown, so nothing below may throw: an error here would propagate
        -- out of the close path and kill the app on every single annotation.
        local ok_run, err = pcall(function()
            if not self_auto_sync then return end

            local ok_read, ReaderUI = pcall(require, "apps/reader/readerui")
            if not ok_read then return end
            local ui = ReaderUI.instance

            if not (ui and ui.document) or not self_auto_sync:shouldUpload("annotate") then
                return
            end

            local is_deletion = items.index_modified and items.index_modified < 0
            if is_deletion then
                local now = os.time()
                if now - last_delete_time < 1 then
                    last_delete_time = now
                    return
                end
                last_delete_time = now
            end

            self_auto_sync:sync(ui.document, true, "annotate")
        end)

        if not ok_run then
            logger.warn("booksync: annotation hook failed:", tostring(err))
        end

        return result
    end
end

-- Wrap `obj.method` in a crash-proof + install-once proxy.
--
-- Every entry into the plugin menu re-runs BookSyncPlugin:init(), and
-- init() used to call hookOnClose()/hookOnSuspend() unconditionally. Each menu
-- visit therefore wrapped the previous wrapper, so after N visits ReaderUI /
-- ReaderDeviceStatus carried N nested layers -- N live references to plugin
-- instances that PluginLoader:finalize() had already destroyed, and N network
-- round trips fired on every suspend. This installs exactly once.
-- NOTE: `marker` must be unique per (target table, method). Two methods on the
-- same table sharing one marker make the second install a silent no-op.
local function hook_once(target, key, marker)
    if not target or type(target[key]) ~= "function" then return false end
    if rawget(target, marker) then return false end
    rawset(target, marker, true)
    return true
end

function Hooks:patchNoteEdit()
    local ok, ReaderBookmark = pcall(require, "apps/reader/modules/readerbookmark")
    if not ok or not ReaderBookmark then return end
    if not hook_once(ReaderBookmark, "setBookmarkNote", "_booksync_hooked_setbookmarknote") then return end

    local original_setBookmarkNote = ReaderBookmark.setBookmarkNote

    ReaderBookmark.setBookmarkNote = function(self, index, is_new_note, text, callback)
        original_setBookmarkNote(self, index, is_new_note, text, callback)

        -- Same rule as onAnnotationsModified above: nothing here may throw, or
        -- the error propagates out of the bookmark path on every single note.
        pcall(function()
            local annotation = self.ui and self.ui.annotation
                and self.ui.annotation.annotations
                and self.ui.annotation.annotations[index]
            if annotation then
                annotation.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
            end
        end)
    end
end

function Hooks:hookOnReaderReady()
    local ReaderUI = require("apps/reader/readerui")
    if not ReaderUI or ReaderUI._booksync_hooked then
        return
    end

    self:patchNoteEdit()

    local original = ReaderUI.showReader
    if not original then
        return
    end
    
    ReaderUI._booksync_hooked = true
    
    local fallback_plugin = self.plugin
    local fallback_auto_sync = self.auto_sync
    
    ReaderUI.showReader = function(...)
        local live = Hooks._live or {}
        local self_plugin = live.plugin or fallback_plugin
        local self_auto_sync = live.auto_sync or fallback_auto_sync
        local args = {...}

        local file = nil
        if #args >= 2 and type(args[2]) == "string" then
            file = args[2]
        end

        -- Nothing below may throw: this wrapper sits in front of KOReader's
        -- own "open a book" entry point, so an escaping error means the book
        -- never opens.
        if not self_auto_sync then
            return original(...)
        end

        -- Remember the last opened book so it can be uploaded from FileManager.
        -- main.lua also installs a startup hook for this; remember_last_book is
        -- idempotent, so the two cannot fight.
        if file then
            -- utils is already loaded into a local above; module() is a dofile
            -- and dofile is evaluated as an argument BEFORE pcall runs, so the
            -- failure it was meant to contain would have escaped anyway.
            pcall(utils.remember_last_book, file)
        end
        
        -- This whole region runs BEFORE original() -- i.e. in front of KOReader's
        -- own "open this book" entry point. readSetting walks the settings tree
        -- and saveSetting re-encodes it to JSON and writes it to disk, so both
        -- can raise on a full or read-only partition. Unprotected, that means a
        -- tap on a book silently does nothing. Contain the whole thing.
        local ok_skip, skip_download = pcall(function()
            return G_reader_settings:readSetting("booksync_skip_auto_download", false)
        end)
        if not ok_skip then
            skip_download = false
            utils.log_crash("readSetting(skip_auto_download)", nil)
        end

        if skip_download then
            pcall(function()
                G_reader_settings:saveSetting("booksync_skip_auto_download", false)
            end)
        else
            local ok_should, should = pcall(function()
                return self_auto_sync:shouldDownload("open")
            end)
            if not ok_should then should = false end
            
            -- ===== 提前获取书籍信息用于通知 =====
            if file and type(file) == "string" and should then
                local ok_download, err_download = pcall(function()
                    -- The cloud name is Title_Author, built from the book's real
                    -- metadata. Deriving the title from the file name instead --
                    -- which this did, and the reason is long gone -- makes the
                    -- lookup ask for a key that was never uploaded, so a book
                    -- sitting in the cloud reports "not found" on every open.
                    -- It happens to work for files named "Title - Author.epub",
                    -- which is why it survived: fold_joins makes that collide
                    -- with the real name by accident, not by design.
                    --
                    -- getDocProps(file, nil, no_open_document=true) reads the
                    -- cached doc_props out of DocSettings and does NOT open the
                    -- document, so it is safe inside the on-open hook. The old
                    -- comment claimed it opened the file; it does not, unless
                    -- that flag is dropped.
                    local title, author = readBookIdentity(file)
                    
                    -- ===== 检查自动同步排除目录 =====
                    local exclude_dirs = self_plugin.settings.exclude_dirs or {}
                    if utils.is_path_excluded(file, exclude_dirs) then
                        self_auto_sync:showNotification(title, _("Auto update skipped (directory excluded)"), nil, false, "skipped")
                        return
                    end
                    
                    -- 👇 前置检查1：网络连接
                    local NetworkMgr = require("ui/network/manager")
                    if not NetworkMgr:isOnline() then
                        self_auto_sync:showNotification(title, _("Auto update failed (Network disconnected)"), nil, false, "error")
                        return
                    end

                    -- 👇 前置检查2：服务器配置
                    local remote = module("remote")
                    local server = remote.get_server()
                    if not server then
                        self_auto_sync:showNotification(title, _("Auto update failed (Cloud storage not configured)"), nil, false, "error")
                        return
                    end

                    -- 👇 前置检查3：云端目录
                    if not server.url or server.url == "" then
                        self_auto_sync:showNotification(title, _("Auto update failed (Cloud directory not set)"), nil, false, "error")
                        return
                    end

                    -- 👇 前置检查4：云服务类型
                    local api = remote.get_api(server)
                    if not api then
                        self_auto_sync:showNotification(title, _("Auto update failed (Unsupported cloud service)"), nil, false, "error")
                        return
                    end
                    -- 👆
                    
                    local DocSettings = require("docsettings")
                    local metadata_file = DocSettings:findSidecarFile(file)
                    
                    local book = {
                        file = file,
                        metadata = metadata_file,
                        title = title,
                        book_basename = (file:match("([^/]+)$") or file):gsub("%.[^%.]+$", ""),
                        author = author,
                    }
                    
                    local success, error_type = remote.download_book_merge_before_open(book)

                    -- The mode goes in the log, not the toast: there is only
                    -- one download behaviour now, so naming it told the user
                    -- nothing and cost them four characters of line length.
                    local log_mode = _("Merge")
                    if success then
                        self_auto_sync:updateLastSync(T(_("Metadata sync") .. "-" .. _("Auto sync") .. "(" .. _("Open book") .. ")-" .. _("Download successful") .. "(%1)", log_mode))
                        self_auto_sync:writeLog(book, _("Open book"), false, true, nil, log_mode)
                        self_auto_sync:showNotification(title, _("Updated from cloud"), nil, true, "success")
                    else
                        local error_info = remote.get_error_message(error_type, false)
                        self_auto_sync:writeLog(book, _("Open book"), false, false, error_info.reason, nil, error_info.solution)
                        local fail_msg = T(_("Update failed: %1"), error_info.reason)
                        self_auto_sync:showNotification(title, fail_msg, nil, false, "error")
                    end
                end)
                
                if not ok_download then
                    logger.warn("booksync: auto-download on open failed:", err_download)
                end
            end
        end

        -- Auto download ALL books metadata when opening a book
        local ok_want_all, want_all = pcall(function()
            return self_auto_sync:shouldDownloadAll("open")
        end)
        if ok_want_all and want_all and file then
            local ok_all, err_all = pcall(function()
                self_auto_sync:syncAllBooksMetadata(false, "open")
            end)
            if not ok_all then
                logger.warn("booksync: auto-download-all on open failed:", err_all)
            end
        end

        local result = original(...)
        
        local ui_instance = ReaderUI.instance
        if ui_instance and not ui_instance.BookSync and self_plugin then
            ui_instance.BookSync = self_plugin
        end
        
        -- Reset chapter tracking so the first page of the new book doesn't
        -- immediately trigger a sync
        -- The chapter trigger reads/writes _last_chapter on the LIVE instance
        -- (main.lua), and init() builds a fresh plugin object per menu entry,
        -- so clearing it here was inert from the second book onward: every new
        -- book then read as a chapter change on its first page and fired a
        -- spurious metadata upload.
        if self_auto_sync then
            self_auto_sync._last_chapter = nil
        end
        if self_plugin then
            self_plugin._last_chapter = nil
        end

        -- Auto upload current book metadata when opening a book
        local ok_want_up, want_up = pcall(function()
            return self_auto_sync:shouldUpload("open")
        end)
        if file and ok_want_up and want_up then
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0, function()
                local ok_up, err_up = pcall(function()
                    local document = ui_instance and ui_instance.document
                    if document then
                        self_auto_sync:sync(document, true, "open")
                    end
                end)
                if not ok_up then
                    logger.warn("booksync: auto-upload on open failed:", err_up)
                end
            end)
        end

        -- Auto upload the book FILE when opening a book. Deferred so the book
        -- opens first: this pushes the whole file over the network and would
        -- otherwise stall the reader behind it. upload_book_if_missing skips
        -- the transfer entirely if the cloud already has a file of that name.
        local ok_want_bk, want_bk = pcall(function()
            return self_auto_sync:shouldUploadBook("open")
        end)
        if file and ok_want_bk and want_bk then
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0, function()
                local ok_bk, err_bk = pcall(function()
                    self_auto_sync:syncBookFile(ui_instance and ui_instance.document, "open", file)
                end)
                if not ok_bk then
                    logger.warn("booksync: auto book upload on open failed:", tostring(err_bk))
                end
            end)
        end

        -- Auto upload ALL books metadata when opening a book
        local ok_want_upall, want_upall = pcall(function()
            return self_auto_sync:shouldUploadAll("open")
        end)
        if file and ok_want_upall and want_upall then
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0, function()
                local ok_up, err_up = pcall(function()
                    self_auto_sync:syncAllBooksMetadata(true, "open")
                end)
                if not ok_up then
                    logger.warn("booksync: auto-upload-all on open failed:", err_up)
                end
            end)
        end
        
        return result
    end
end

-- Run the "upload on <source>" trio against whatever reader is open *right now*.
-- Never let a failure here escape into ReaderUI's close/suspend path.
local function run_source_uploads(auto_sync, source)
    if not auto_sync then return end
    local ok_read, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_read or not ReaderUI then return end
    local ui = ReaderUI.instance
    if not (ui and ui.document) then return end
    local document = ui.document

    local function attempt(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            logger.warn("booksync: auto upload on " .. source .. " (" .. label .. ") failed:", tostring(err))
        end
    end

    -- Every predicate goes through the same boundary as the work it guards.
    -- attempt() wrapped the three sync calls but not the three shouldXxx calls
    -- themselves, and auto_sync.lua declares `settings = nil` as the class
    -- default -- so an instance that had not been initialised raised here, out
    -- of ReaderUI.onClose, with nothing in between to catch it.
    local function wants(label, predicate, work)
        local ok_p, result = pcall(predicate)
        if not ok_p then
            logger.warn("booksync: " .. source .. " guard (" .. label .. ") failed:", tostring(result))
            return
        end
        if result then attempt(label, work) end
    end

    wants("metadata", function() return auto_sync:shouldUpload(source) end,
          function() auto_sync:sync(document, true, source) end)
    wants("book", function() return auto_sync:shouldUploadBook(source) end,
          function() auto_sync:syncBookFile(document, source) end)
    wants("all", function() return auto_sync:shouldUploadAll(source) end,
          function() auto_sync:syncAllBooksMetadata(true, source) end)
end

-- NOTE: the original version captured `self.plugin.ui` at hook time. When the
-- plugin is opened from the FileManager (the normal case) that is the
-- FileManager, which never has a `.document` -- so the close/sync logic never
-- fired at all, while still leaving a permanently live closure pointing at a
-- plugin instance that PluginLoader:finalize() had already destroyed.
-- Resolve ReaderUI.instance lazily instead.
-- Both the declared onCloseDocument event and the ReaderUI.onClose wrap land
-- here. Whichever KOReader happens to deliver first does the work and latches
-- the document; the second one is a no-op. That is why the wrap can stay as a
-- fallback: the plugin does not have to bet that every KOReader version
-- dispatches the event, and it cannot upload twice if it does.
Hooks._closed_file = nil

function Hooks:handleDocumentClosed()
    local live = Hooks._live or {}
    local auto_sync = live.auto_sync or self.auto_sync
    if not auto_sync then return end

    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    local inst = ok_r and ReaderUI and ReaderUI.instance
    local file = inst and inst.document and inst.document.file
        or (auto_sync.settings and auto_sync.settings.last_book_file)

    if file and Hooks._closed_file == file then
        return   -- the other close path already handled this book
    end
    Hooks._closed_file = file

    if auto_sync.skip_auto_upload then
        auto_sync.skip_auto_upload = false
    else
        run_source_uploads(auto_sync, "close")
    end
end

function Hooks:hookOnClose()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return end
    if not hook_once(ReaderUI, "onClose", "_booksync_hooked_onclose") then return end

    local original = ReaderUI.onClose
    if not original then return end

    local self_hooks = self

    ReaderUI.onClose = function(...)
        -- pcall: this sits in front of KOReader's own reader teardown, and an
        -- error here would take the app down while the widget stack is being
        -- destroyed.
        pcall(function() self_hooks:handleDocumentClosed() end)
        return original(...)
    end
end

function Hooks:hookOnSuspend()
    local ok, ReaderDeviceStatus = pcall(require, "apps/reader/modules/readerdevicestatus")
    if not ok or not ReaderDeviceStatus then return end
    if not hook_once(ReaderDeviceStatus, "onSuspend", "_booksync_hooked_onsuspend") then return end

    local original = ReaderDeviceStatus.onSuspend
    if not original then return end

    local fallback_auto_sync = self.auto_sync

    ReaderDeviceStatus.onSuspend = function(self_status)
        local live = Hooks._live or {}
        local self_auto_sync = live.auto_sync or fallback_auto_sync
        local result = original(self_status)
        run_source_uploads(self_auto_sync, "suspend")
        return result
    end
end

return Hooks
