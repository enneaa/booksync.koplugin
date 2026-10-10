-- Get plugin root directory absolute path (inspired by zen_ui)
local src = debug.getinfo(1, "S").source or ""
local path = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil

local _plugin_dir  -- Declare local variable

if path then
    -- Handle relative path (some KOReader installations may return relative paths)
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

-- Add plugin directory to package.path to avoid module name conflicts
package.path = _plugin_dir .. "?.lua;" .. package.path

-- i18n must be installed before any other require()
local i18n = module("i18n")
i18n.install()

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local Device = require("device")
local DataStorage = require("datastorage")
local _ = module("gettext_shim")
local logger = require("logger")
local T = require("ffi/util").template
local lfs = require("libs/libkoreader-lfs")

local function book_props(ui, file)
    -- Prefer the reader's own view of the properties, which is what the
    -- rest of the plugin uses, and is the only source that knows about a
    -- cover browser's custom title.
    if ui and ui.bookinfo then
        local ok, props = pcall(function()
            return ui.bookinfo:getDocProps(file, nil, true)
        end)
        if ok and type(props) == "table" and (props.title or props.display_title) then
            return props
        end
    end

    -- No UI here -- the app-start hook has no `self` to get one from -- so read
    -- the sidecar. This is what getDocProps does internally for a book that
    -- has been opened, and it does not depend on a window being on screen.
    local ok_sf, sidecar = pcall(function()
        local DocSettings = require("docsettings")
        return DocSettings:findSidecarFile(file)
    end)
    if not ok_sf or not sidecar then return {} end
    local ok_sd, doc_settings = pcall(function()
        local DocSettings = require("docsettings")
        return DocSettings.openSettingsFile(sidecar)
    end)
    if not ok_sd or not doc_settings then return {} end
    local ok_ps, props = pcall(function()
        return doc_settings:readSetting("doc_props")
    end)
    if ok_ps and type(props) == "table" then return props end
    return {}
end

local function book_identity(ui, file)
    local filename = file:match("([^/\\]+)$")
    local stem = filename and filename:gsub("%.[^%.]+$", "")
    local props = book_props(ui, file)
    local title = props.title or props.display_title
    if type(title) ~= "string" or title == "" then title = nil end
    local author = props.authors
    if type(author) == "table" then author = author[1] end
    if type(author) ~= "string" or author == "" then author = nil end
    return filename, stem, title, author
end

local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen
local notify = module("notify")

-- Hard error boundary for anything the plugin triggers from a UIManager
-- callback. UIManager dispatches events and runs scheduled tasks with no pcall
-- of its own, so a single escaping error means a dead app rather than a failed
-- sync. Route every cloud operation through this.
local function guarded(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        logger.err("BookSync: " .. label .. " crashed: " .. tostring(err))
        pcall(function()
            notify.error(T(_("%1 failed: %2"), label, tostring(err)))
        end)
    end
    return ok
end

-- Same boundary, but deferred one tick so the originating dialog is fully
-- closed before any cloud I/O starts.
local function nextTickGuarded(label, fn)
    UIManager:nextTick(function()
        guarded(label, fn)
    end)
end

local BookSyncPlugin = WidgetContainer:extend {
    is_doc_only = false,
}

BookSyncPlugin.default_settings = {
    last_sync = "Never",
    auto_upload_on_annotate = false,
    auto_upload_on_close = false,
    auto_upload_on_suspend = false,
    auto_upload_on_resume = false,
    auto_upload_on_flush = false,
    auto_upload_on_chapter = false,
    auto_upload_on_open = false,
    auto_upload_last_book_on_start = false,
    auto_download_all_on_start = false,
    auto_download_on_open = false,
    auto_download_mode = "merge",
    manual_download_mode = "merge", 
    auto_upload_book_on_open = false,
    auto_upload_book_on_close = false,
    auto_upload_book_on_suspend = false,
    auto_upload_all_on_close = false,
    auto_upload_all_on_suspend = false,
    auto_upload_all_on_open = false,
    auto_download_all_on_open = false,
    auto_download_all_on_resume = false,
    upload_json = false,
    use_notemark_format = false,
    cloud_book_sort_mode = 1,
    long_press_menu = true,
    book_download_dir = nil,
    book_download_overwrite = false,
    book_cloud_dir = nil,
    book_cloud_type = nil,
    book_cloud_address = nil,
    book_cloud_username = nil,
    book_cloud_password = nil,
    exclude_dirs = {},
}


function BookSyncPlugin:init()
    local meta = module("_meta")
    -- PluginLoader normally merges _meta.lua's fields onto the module table.
    -- Re-apply them here so the display name and id resolve even without that
    -- merge (and so there is exactly one place the name is defined).
    self.fullname = meta.fullname
    self.description = meta.description
    self.plugin_id = self.plugin_id or meta.plugin_id
    self.VERSION = meta.version or "v1.0.0"

    -- Picks up a language change, and costs nothing when there is none
    -- (i18n.refresh() returns early unless the language actually moved).
    i18n.refresh()

    self.ui.menu:registerToMainMenu(self)
    
    local utils = module("utils")
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()
    
    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)
    
    local AutoSync = module("auto_sync")
    local ManualSync = module("manual_sync")
    local Hooks = module("hooks")
    
    if not BookSyncPlugin._auto_sync then
        self.auto_sync = AutoSync:new(self, self.settings)
        BookSyncPlugin._auto_sync = self.auto_sync
    else
        self.auto_sync = BookSyncPlugin._auto_sync
        self.auto_sync.settings = self.settings
        self.auto_sync.plugin = self
    end
    
    self.manual_sync = ManualSync:new(self, self.auto_sync)
    self.hooks = Hooks:new(self, self.auto_sync)
    
    if self.ui then
        self.ui.BookSync = self
    end
    
    -- All four hook installers are idempotent now (see hook_once in hooks.lua).
    -- init() runs on *every* entry into this menu, so anything that re-wraps a
    -- core method on each pass stacks layers that outlive the plugin instance
    -- that created them.
    -- These four ARE the automatic triggers: annotation edits, opening a book,
    -- closing a book, device suspend.
    self.hooks:hookAnnotationModified()
    self.hooks:hookOnReaderReady()
    self.hooks:hookOnClose()
    self.hooks:hookOnSuspend()

     -- ===== 长按书籍菜单：上传元数据 / 下载元数据 / 上传书籍 =====
    --
    -- No polling. This used to fall back to a 2-second UIManager timer that ran
    -- until FileManager.instance showed up, and that timer was writing into
    -- fm.file_dialog_added_buttons while KOReader was iterating that very
    -- table to build the long-press menu (filemanager.lua):
    --
    --     for _, row_func in ipairs(file_manager.file_dialog_added_buttons) do
    --
    -- addFileDialogButtons inserts, removeFileDialogButtons shifts every
    -- element after the removed one, and the plugin also re-runs this from the
    -- settings toggle. A menu being built while the table it is walking moves
    -- underneath it is exactly the shape of a "always" freeze, and it explains
    -- why the file dialog was the only place it ever showed up.
    --
    -- Registration is now pinned to the two moments that cannot race with menu
    -- construction: the FileManager instance being built (see
    -- install_startup_hooks, where the row is added right after the original
    -- constructor returns), and an explicit user action -- entering this menu,
    -- or flipping the toggle.
    self:_registerLongPressRow()

    -- ===== 选择模式 Plus 菜单：批量上传元数据 / 批量下载元数据 / 批量上传书籍 =====
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager._booksync_plus_patched then
        FileManager._booksync_plus_patched = true
        local orig_getPlusDialogButtons = FileManager.getPlusDialogButtons
        FileManager.getPlusDialogButtons = function(self_fm, ...)
            local title, buttons = orig_getPlusDialogButtons(self_fm, ...)
            if not self_fm.selected_files then
                return title, buttons
            end

            local files = {}
            for f, selected in pairs(self_fm.selected_files) do
                if selected and lfs.attributes(f, "mode") == "file" then
                    files[#files + 1] = f
                end
            end

            if #files == 0 then
                return title, buttons
            end

            -- Append, do not insert at a fixed index. The plus dialog's row
            -- count belongs to KOReader and changes between versions; index 8
            -- used to displace a core row (the "New folder" button) and push
            -- ours under whatever the user had in Cover Browser mode.
            table.insert(buttons, {
                {
                    text = T(_("Upload metadatas (CL) (%1)"), #files),
                    callback = function()
                        UIManager:close(self_fm.plus_dialog)
                        nextTickGuarded(_("Batch metadata upload"), function()
                            local utils = module("utils")
                            utils.undimFileRows()
                            utils.bookshelfExitSelection()

                            local DocSettings = require("docsettings")
                            local books = {}
                            local without_meta = 0
                            for _i, fpath in ipairs(files) do
                                local mf = DocSettings:findSidecarFile(fpath)
                                if mf and lfs.attributes(mf, "mode") then
                                    local _f, stem, title, author = book_identity(self.ui, fpath)
                                    books[#books + 1] = {
                                        file = fpath,
                                        metadata = mf,
                                        title = title,
                                        author = author,
                                        book_basename = stem,
                                    }
                                else
                                    without_meta = without_meta + 1
                                end
                            end
                            if #books == 0 then
                                notify.error(_("No local metadata files found"))
                                return
                            end
                            -- Say what was dropped. Selecting 20 books and
                            -- watching 6 of them vanish with no mention is
                            -- indistinguishable from a plugin that lost them.
                            if without_meta > 0 then
                                notify.hint(T(_("Skipped %1 book(s) with no local metadata yet. Open them once, then sync again."), without_meta))
                            end
                            self.manual_sync:doBatchSync(true, false, books)
                        end)
                    end,
                },
                {
                    text = T(_("Download metadatas (CL) (%1)"), #files),
                    callback = function()
                        UIManager:close(self_fm.plus_dialog)
                        nextTickGuarded(_("Batch metadata download"), function()
                            self.manual_sync:batchSyncWithFMSelection(false, true)
                        end)
                    end,
                },
                {
                    text = T(_("Upload books (CL) (%1)"), #files),
                    callback = function()
                        UIManager:close(self_fm.plus_dialog)
                        nextTickGuarded(_("Batch book upload"), function()
                            local utils = module("utils")
                            utils.undimFileRows()
                            utils.bookshelfExitSelection()

-- The title of a book is its title, not its filename.
--
-- These paths used to set `title` to the filename with the extension removed,
-- which is a filename in a field every consumer reads as a title. It reached
-- all the way into the name of the file in the cloud: "三体 - 刘慈欣.epub"
-- became "三体_刘慈欣.lua" because the "title" was the filename. Reading the
-- real properties is what separates the two, and a book whose properties have
-- never been read simply has no title -- every caller below already falls
-- back to the filename, and does so visibly.
--
-- no_open_document is passed on purpose: opening every file in a 200-book
-- selection to read a title is not something a menu callback should do.
                            local BookSync = module("book_sync")
                            local books = {}
                            for _i, fpath in ipairs(files) do
                                local filename, stem, title, author =
                                    book_identity(self.ui, fpath)
                                books[#books + 1] = {
                                    file_path = fpath,
                                    path = fpath,
                                    name = filename or _("Unknown"),
                                    title = title,
                                    author = author,
                                    book_basename = stem,
                                }
                            end
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Upload %1 book(s) to cloud"), #books),
                                ok_text = _("Continue"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    BookSync.batchUploadBooks(books, self.settings, self)
                                end,
                            })
                        end)
                    end,
                },
            })

            return title, buttons
        end
    end
    
    logger.info("BookSync: plugin init completed")
end

function BookSyncPlugin:addToMainMenu(menu_items)
    menu_items.booksync_plugin = {
        text = self.fullname,
        sorting_hint = "tools",
        sub_item_table = self:buildMenuItems(),
    }
end

function BookSyncPlugin:buildMenuItems()
    -- The two things a user reaches for most sit at the top rather than
    -- buried two levels down: pushing the current book, and deciding whether
    -- book files get pushed automatically. Both used to live inside Manual
    -- Sync and Auto Sync respectively, which meant the fastest action in the
    -- plugin was the hardest one to find.
    --
    return {
        {
            text = _("Cloud Books"),
            callback = function()
                self:batchDownloadBooks()
            end,
        },
        {
            text = _("Manual Sync"),
            sub_item_table = self:buildManualSyncMenu(),
        },
        {
            text = _("Auto Sync"),
            sub_item_table = self:buildAutoSyncMenu(),
        },
        {
            text = _("More Settings"),
            sub_item_table = self:buildSettingsMenu(),
        },
        {
            -- The plugin tells the user to "check the log file" whenever a
            -- failure is one it cannot explain (see get_error_message's
            -- UNKNOWN_ERROR entry), but until now nothing in the menu pointed
            -- at that file: the path lives in the data dir and the user has no
            -- way to learn it. A button that opens it costs one menu entry and
            -- makes the existing advice actionable.
            text = _("View Sync Log"),
            callback = function()
                self:showSyncLog()
            end,
        },
        -- Last sync, at the bottom of the menu rather than buried in a
        -- submenu. It is a status readout, not something to tap, so it reads
        -- best as a footer: everything above it is something you can do, this
        -- is what happened last.
        self:_lastSyncItem(),
    }
end

-- Open the sync log in a scrollable viewer. Handles the three states the user
-- can actually be in: never synced (no file), synced (show it), and file
-- unreadable (say so rather than showing an empty box, which reads as "no
-- errors" and is the opposite of the truth).
function BookSyncPlugin:showSyncLog()
    local utils = module("utils")
    local log_path = utils.get_log_path()

    local f = io.open(log_path, "r")
    if not f then
        local notify = module("notify")
        notify.info(_("No sync log yet. It is created after the first sync."))
        return
    end
    local content = f:read("*all")
    f:close()

    if not content or content == "" then
        module("notify").info(_("The sync log is empty."))
        return
    end

    -- The log itself is capped at 512 KB (utils.LOG_MAX_BYTES). A modal viewer
    -- is not a log browser: on an e-ink screen this is for reading the most
    -- recent entries, not scrolling a quarter-megabyte. Newest records are
    -- PREPENDED by write_log, so the head is the recent past -- show that, and
    -- say it was trimmed. Showing the tail instead would show the oldest lines
    -- and read as "nothing recent happened", which is the opposite of the news.
    local MAX_BYTES = 8000
    if #content > MAX_BYTES then
        local util = require("util")
        content = T(_("... older records trimmed ...\n[showing the most recent entries]"))
            .. util.fixUtf8(content:sub(1, MAX_BYTES), "")
    end

    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("Sync Log"),
        text = content,
        is_doc_body = false,
    })
end

-- The last-sync line, as a menu item of its own.
--
-- It used to be the last row inside the More Settings submenu, which is two
-- taps deep and below a list of a dozen unrelated switches -- the one number
-- people actually glance at was the hardest one to read. It reads a value
-- rather than doing anything, so it needs no callback.
function BookSyncPlugin:_lastSyncItem()
    return {
        enabled = false,
        text_func = function()
            local last_sync = self.settings.last_sync
            if last_sync == "Never" then
                return T(_("Last sync: %1"), last_sync)
            end
            local time_part = last_sync:match("(.+) %(") or last_sync
            local action_part = last_sync:match("%((.+)%)") or ""
            if action_part ~= "" then
                return T(_("Last sync: %1 (%2)"), time_part, action_part)
            else
                return T(_("Last sync: %1"), last_sync)
            end
        end
    }
end

-- Manual Sync menu: organized by scope (current → all).
--
-- Every "current book" action resolves the same way: the book open in the
-- reader, otherwise the last one opened (see ManualSync:resolveTargetBook and
-- BookSyncPlugin:uploadCurrentBook), so the metadata and book-file entries
-- in this menu never disagree about what "current" means.
--
-- The download entries deliberately do NOT fork into Overwrite/Merge: there is
-- only one download mode now. Picking "Overwrite" on the current-book entry
-- used to silently rewrite the setting while the all-books entry did not --
-- same toggle, two different behaviours. Everything merges.
function BookSyncPlugin:buildManualSyncMenu()
    local utils = module("utils")

    local target, is_open = self.manual_sync:resolveTargetBook()

    -- "Current book" vs "last book" wording, mirroring how the user reached it.
    local function current_or_last(prefix)
        if not target then
            return prefix
        end
        if is_open then
            return prefix
        end
        return T(_("%1 last book (%2)"), prefix, target:match("([^/]+)$") or target)
    end

    return {
        -- ===== Current Book =====
        -- The book file goes first. Pushing the file is what a user opens this
        -- menu to do; the metadata rows around it are the finer-grained moves.
        {
            text_func = function()
                return current_or_last(_("Upload current book file"))
            end,
            enabled = target ~= nil,
            help_text = target and nil or _("No book opened yet"),
            callback = function()
                self:uploadCurrentBook()
            end
        },
        {
            text_func = function()
                return current_or_last(_("Upload current book metadata"))
            end,
            enabled = target ~= nil,
            help_text = target and nil or _("No book opened yet"),
            callback = function()
                self.manual_sync:syncCurrentBook(true)
            end
        },
        {
            text_func = function()
                return current_or_last(_("Download current book metadata"))
            end,
            enabled = target ~= nil,
            help_text = target and nil or _("No book opened yet"),
            callback = function()
                self.manual_sync:syncCurrentBookMerge()
            end
        },
        -- ===== All Books =====
        {
            text = _("Upload all books metadata"),
            callback = function()
                self.manual_sync:batchSyncAllBooks(true, false)
            end,
        },
        {
            text = _("Download all books metadata"),
            callback = function()
                self.manual_sync:batchSyncAllBooks(false, true)
            end,
        },
    }
end

-- Settings menu: storage → naming → download → metadata options → info.

-- ============================================================
-- Cloud account / directory picker
-- ============================================================
--
-- KOReader relocated its cloud settings UI as well: the old
-- Pick a cloud server through KOReader's own UI. The picker hands back
-- { name, type, address, username, password, url }.
--
-- Cloud account / directory picker, from v1.23.0 verbatim.
--
-- Restored deliberately. The apps/cloudstorage/syncservice branch was dropped
-- in a later version on the assumption that KOReader had removed that module;
-- it had not. On a build that still ships it -- the user's Kindle does -- the
-- built-in service is the only one of the three that opens, and without this
-- branch cloud setup is a dead end.
--
-- Do not "simplify" this away: the three entry points are tried in order
-- because different KOReader installs have different subsets of them.

local function show_cloud_config_dialog(onConfirm)
    local UIM = UIManager

    local ok_legacy, SyncService = pcall(require, "apps/cloudstorage/syncservice")
    if ok_legacy and type(SyncService) == "table" then
        local svc = SyncService:new{}
        svc.onConfirm = onConfirm
        UIM:show(svc)
        return true
    end

    -- New layout: Cloud:onShowCloudStorageList(cb) hands us
    -- { name, type, address, username, password, url }.
    for _, mod_name in ipairs({
        "plugins/cloudstorage.koplugin/main",
        "cloudstorage.koplugin.main",
    }) do
        local ok, Cloud = pcall(require, mod_name)
        if ok and type(Cloud) == "table" and type(Cloud.onShowCloudStorageList) == "function" then
            local ok_show, err = pcall(Cloud.onShowCloudStorageList, Cloud, function(server)
                if type(server) == "table" then
                    onConfirm(server)
                end
            end)
            if ok_show then return true end
            logger.err("BookSync: cloud picker failed: " .. tostring(err))
        end
    end

    local ok_cs, CloudStorage = pcall(require, "plugins/cloudstorage.koplugin/cloudstorage")
    if ok_cs and type(CloudStorage) == "table" then
        local ok_show, err = pcall(function()
            local cs = CloudStorage:new{}
            cs.caller_choose_folder_callback = function(server)
                if type(server) == "table" then
                    onConfirm(server)
                end
            end
            cs:show()
        end)
        if ok_show then return true end
        logger.err("BookSync: cloud picker failed: " .. tostring(err))
    end

    UIM:show(Notification:new{
        text = _("This KOReader build does not expose the cloud storage settings dialog"),
        timeout = 4,
    })
    return false
end

-- Generic toggle: flip a boolean setting, save, show enabled/disabled message.
-- `on_change(self)` runs after flipping (e.g. to recompute derived flags).
function BookSyncPlugin:_makeToggle(setting_key, text, help, on_change)
    return {
        text = text,
        help_text = help,
        checked_func = function()
            return self.settings[setting_key] == true
        end,
        callback = function()
            self.settings[setting_key] = not self.settings[setting_key]
            if on_change then on_change(self) end
            G_reader_settings:saveSetting(self.plugin_id, self.settings)
            local utils = module("utils")
            local label = self.settings[setting_key] and _("Enabled: %1") or _("Disabled: %1")
            utils.show_msg(T(label, text))
        end,
    }
end

-- Generic radio item: checked_func decides selection, callback handles state.
function BookSyncPlugin:_makeRadio(text, checked_func, callback, help)
    return {
        text = text,
        help_text = help,
        checked_func = checked_func,
        callback = callback,
    }
end

function BookSyncPlugin:buildSettingsMenu()
    local utils = module("utils")
    local settings_items = {
        -- ===== Cloud Storage =====
        -- The two cloud directories sit directly in Settings. They were
        -- wrapped in a "Cloud Storage" submenu that held nothing else, so
        -- reaching the single most important setting in the plugin cost an
        -- extra tap for no gain.
        {
            text_func = function()
                local remote = module("remote")
                local server = remote.get_server()
                if server and server.url then
                    return T(_("Metadata Cloud Directory: %1"), server.url)
                else
                    return _("Set Metadata Cloud Directory")
                end
            end,
            callback = function()
                local remote = module("remote")
                show_cloud_config_dialog(function(server)
                    remote.save_server_settings(server)
                end)
            end
        },
        {
            text_func = function()
                local book_dir = self.settings.book_cloud_dir
                if book_dir and book_dir ~= "" then
                    return T(_("Book Cloud Directory: %1"), book_dir)
                else
                    return _("Set Book Cloud Directory (defaults to metadata directory)")
                end
            end,
            callback = function() self:chooseBookCloudDir() end,
        },
        -- ===== Download =====
        {
            text_func = function()
                local dir = self.settings.book_download_dir
                if dir and dir ~= "" then
                    return T(_("Book Download Directory: %1"), dir)
                else
                    return _("Set Book Download Directory")
                end
            end,
            callback = function() self:chooseBookLocalDir() end,
        },
        -- Earlier versions could leave a truncated file behind (a transfer that
        -- reported failure after the bytes had landed). Those files are
        -- non-empty, so the batch treats them as "already downloaded" and skips
        -- the book forever. This is the way out of that without hunting through
        -- the download folder by hand.
        self:_makeToggle("book_download_overwrite",
            _("Re-download books that already exist locally"),
            _("Normally a book that is already in the download folder is skipped. Turn this on to replace local files with the cloud copy, which is how you recover a book left half-written by an earlier failed transfer.")),
        self:_makeToggle("long_press_menu",
            _("Buttons in the long-press menu"),
            _("Adds upload and download entries to the menu you get by long-pressing a book in the file browser. Turn this off if that menu misbehaves on your device; the rest of BookSync is unaffected."),
            -- Apply straight away. With registration buried in init(), turning
            -- this back on did nothing visible until the plugin menu happened
            -- to be opened again, which reads as "the setting is broken".
            function(plugin)
                plugin:_registerLongPressRow()
            end),
        -- ===== Metadata Options =====
        {
            text = _("Additional JSON Backup"),
            sub_item_table = {
                self:_makeRadio(_("Original format (default)"),
                    function() return self.settings.upload_json == true and self.settings.use_notemark_format == false end,
                    function()
                        self.settings.upload_json = not (self.settings.upload_json and not self.settings.use_notemark_format)
                        self.settings.use_notemark_format = false
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and _("Enabled: Original format") or _("Disabled: Additional JSON backup"))
                    end),
                self:_makeRadio(_("NoteMarkData format"),
                    function() return self.settings.upload_json == true and self.settings.use_notemark_format == true end,
                    function()
                        self.settings.upload_json = not (self.settings.upload_json and self.settings.use_notemark_format)
                        self.settings.use_notemark_format = self.settings.upload_json
                        G_reader_settings:saveSetting(self.plugin_id, self.settings)
                        utils.show_msg(self.settings.upload_json and _("Enabled: NoteMarkData format") or _("Disabled: Additional JSON backup"))
                    end,
                    _("Convert annotations to NoteMarkData format")),
            },
        },
    }
    return settings_items
end

-- Auto Sync menu: grouped by operation type (upload metadata / upload book
-- file / download / notifications). The book-file group is deliberately its
-- own entry rather than a fourth set of rows inside the metadata one: pushing
-- a whole book is a different decision from pushing a sidecar, and sharing a
-- heading with it made the two hard to tell apart.
function BookSyncPlugin:buildAutoSyncMenu()
    local utils = module("utils")

    -- Toggle that also recomputes the auto-sync enabled flag.

    -- Downloads always merge now, so "download on open" is one switch rather
    -- than a per-mode radio. The old pair ("On opening a book (Overwrite)" /
    -- "(Merge)") let the same feature be turned on in two places, and the only
    -- way to tell them apart while scrolling was reading the parenthetical.
    local function toggle_download_on_open()
        return self:_makeToggle("auto_download_on_open", _("On opening a book"),
            _("Download the cloud metadata when opening a book. Annotations and reading progress are always merged, never replaced."))
    end

    return {
        -- ===== Auto Upload Book File =====
        -- First for the same reason the manual upload leads: uploading the
        -- book file is the action users reach this menu for, and burying it
        -- under the metadata group made the commonest switch the second tap.
        {
            text = _("Auto Upload Book File"),
            sub_item_table = {
                self:_makeToggle("auto_upload_book_on_open", _("On opening a book"),
                    _("Upload the book file only if no file with the same name exists in cloud")),
                self:_makeToggle("auto_upload_book_on_close", _("On closing book"),
                    _("Upload the book file only if no file with the same name exists in cloud")),
                self:_makeToggle("auto_upload_book_on_suspend", _("On device suspend"),
                    _("Upload the book file only if no file with the same name exists in cloud")),
            },
        },
        -- ===== Auto Upload Metadata (current + all) =====
        {
            text = _("Auto Upload Metadata"),
            sub_item_table = {
                -- Current book metadata
                {
                    text = _("Current book metadata"),
                    enabled = false,
                },
                self:_makeToggle("auto_upload_on_open", _("On opening a book"),
                    _("Upload current book metadata when opening a book")),
                self:_makeToggle("auto_upload_last_book_on_start", _("On app start"),
                    _("On launching KOReader, upload the metadata of the book you last read")),
                self:_makeToggle("auto_upload_on_annotate", _("On annotation edit")),
                self:_makeToggle("auto_upload_on_close", _("On closing book")),
                self:_makeToggle("auto_upload_on_suspend", _("On device suspend")),
                self:_makeToggle("auto_upload_on_resume", _("On app resume"),
                    _("On resuming from suspend, upload current book metadata")),
                self:_makeToggle("auto_upload_on_chapter", _("On chapter change"),
                    _("Upload when you finish reading a chapter and move to the next")),
                self:_makeToggle("auto_upload_on_flush", _("On settings flush (~5 min)"),
                    _("Upload when KOReader periodically saves settings (roughly every 5 minutes)")),
                -- ALL books metadata
                {
                    text = _("ALL books metadata"),
                    enabled = false,
                    separator = true,
                },
                self:_makeToggle("auto_upload_all_on_open", _("On opening a book"),
                    _("Scan current directory and upload metadata for ALL books")),
                self:_makeToggle("auto_upload_all_on_close", _("On closing book"),
                    _("Scan current directory and upload metadata for ALL books")),
                self:_makeToggle("auto_upload_all_on_suspend", _("On device suspend"),
                    _("Scan current directory and upload metadata for ALL books")),
            },
        },
        -- ===== Auto Download Metadata =====
        -- Named "Auto Download Metadata" because every trigger in this group
        -- fetches .sdr sidecars only. Book files are never downloaded
        -- automatically -- that is what the separate "Auto Upload Book File"
        -- group (and Batch Download Books) are for, and the bare "Auto
        -- Download" heading made it look like books were pulled down too.
        {
            text = _("Auto Download Metadata"),
            sub_item_table = {
                -- Current book metadata
                {
                    text = _("Current book metadata"),
                    enabled = false,
                },
                toggle_download_on_open(),
                -- ALL books metadata
                {
                    text = _("ALL books metadata"),
                    enabled = false,
                    separator = true,
                },
                self:_makeToggle("auto_download_all_on_open", _("On opening a book"),
                    _("Download metadata for ALL books in current directory")),
                self:_makeToggle("auto_download_all_on_resume", _("On app resume"),
                    _("Download metadata for ALL books from cloud on resuming from suspend")),
                self:_makeToggle("auto_download_all_on_start", _("On app start"),
                    _("On launching KOReader, pull metadata for ALL books so reading progress from your other devices is up to date")),
            },
        },
        {
            text_func = function()
                local count = #(self.settings.exclude_dirs or {})
                if count > 0 then
                    return T(_("Exclude Directories (%1)"), count)
                else
                    return _("Exclude Directories")
                end
            end,
            callback = function() self:showExcludeDirDialog() end,
        },
        {
            text = _("Notifications"),
            sub_item_table = {
                self:_makeToggle("auto_sync_notify_error", _("On failure"),
                    _("Tell me when an automatic sync could not be done. Leave this on.")),
                self:_makeToggle("auto_sync_notify_success", _("On success"),
                    _("Tell me when an automatic sync finished. Usually the noisiest one.")),
                self:_makeToggle("auto_sync_notify_skipped", _("On skipped"),
                    _("Tell me when an automatic sync deliberately did nothing: an excluded directory, a book already in the cloud, or nothing to do.")),
            },
        },
    }
end

function BookSyncPlugin:chooseBookCloudDir()
    -- Reuse whatever picker this KOReader build provides, then store the
    -- chosen directory as a second, independent book cloud.
    show_cloud_config_dialog(function(server)
        self.settings.book_cloud_dir = server.url
        self.settings.book_cloud_type = server.type
        self.settings.book_cloud_address = server.address
        self.settings.book_cloud_username = server.username
        self.settings.book_cloud_password = server.password
        G_reader_settings:saveSetting(self.plugin_id, self.settings)
    end)
end

-- Pick a directory to exclude.
--
-- `on_done` puts the caller back where it came from. The directory picker
-- (DownloadMgr) only reports the chosen path; it has no cancel callback, so
-- pressing Cancel closes it and nothing else. Without a way back, the exclude
-- dialog used to close itself first to avoid stacking -- which meant a cancel
-- left the user looking at whatever was underneath (see the Add button below).
-- on_done runs on both outcomes, so the caller returns either way.
function BookSyncPlugin:addExcludeDir(on_done)
    local utils = module("utils")
    local DownloadMgr = require("ui/downloadmgr")
    local self_ref = self
    local current_dir = nil

    DownloadMgr:new{
        title = _("Select Directory to Exclude from Auto Sync"),
        onConfirm = function(path)
            if path and path ~= "" then
                local exclude_dirs = self_ref.settings.exclude_dirs or {}
                for idx, existing in ipairs(exclude_dirs) do
                    if existing == path then
                        utils.show_msg(_("This directory is already in the exclude list"))
                        return
                    end
                end
                table.insert(exclude_dirs, path)
                self_ref.settings.exclude_dirs = exclude_dirs
                G_reader_settings:saveSetting(self_ref.plugin_id, self_ref.settings)
                utils.show_msg(T(_("Excluded directory added: %1"), path))
            end
            if on_done then on_done() end
        end,
    }:chooseDir(current_dir)
end

function BookSyncPlugin:removeExcludeDir(index)
    local utils = module("utils")
    local exclude_dirs = self.settings.exclude_dirs or {}
    if index < 1 or index > #exclude_dirs then
        return
    end
    
    local removed_dir = exclude_dirs[index]
    local self_ref = self
    
    if self_ref._exclude_dir_dialog then
        UIManager:close(self_ref._exclude_dir_dialog)
        self_ref._exclude_dir_dialog = nil
    end
    
    UIManager:show(ConfirmBox:new{
        text = T(_('Remove "%1" from exclude list?'), removed_dir),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            table.remove(exclude_dirs, index)
            self_ref.settings.exclude_dirs = exclude_dirs
            G_reader_settings:saveSetting(self_ref.plugin_id, self_ref.settings)
        end,
    })
end



-- Register (or remove) BookSync's row in the long-press menu on books.
--
-- A method rather than a local in init(), so the settings toggle can call it
-- directly: with it buried in init(), turning the option back on did nothing
-- until the user happened to open the plugin menu again.
function BookSyncPlugin:_registerLongPressRow()
    local FM = require("apps/filemanager/filemanager")
    local fm = FM and FM.instance
    if not fm or type(fm.addFileDialogButtons) ~= "function" then
        return false
    end

    -- BookSync adds one row to the long-press menu on every book. On a
    -- Kindle that menu is already crowded, and this switch exists so the
    -- integration can be taken out without uninstalling the plugin -- it is
    -- also the only way to tell "the long-press menu hangs" apart from
    -- "this device's long-press menu hangs" without a reinstall.
    -- The row is registered from the FileManager constructor, which can run
    -- before init() has loaded settings. Only an explicit false turns the row
    -- off, so a settings table that is missing or not loaded yet leaves the
    -- default (on) in place rather than erroring.
    local settings = self.settings
    local row_enabled = type(settings) ~= "table" or settings.long_press_menu ~= false
    if not row_enabled then
        if fm._booksync_row_registered then
            fm._booksync_row_registered = false
            if type(fm.removeFileDialogButtons) == "function" then
                fm:removeFileDialogButtons("booksync_upload")
            end
        end
        return true
    end

    if fm._booksync_row_registered then
        return true
    end
    fm._booksync_row_registered = true

    fm:addFileDialogButtons("booksync_upload",
        function(file, is_file, book_props, close_cb)
            if not is_file then return nil end

            -- Close the dialog that is on screen NOW, not the one on the
            -- FileManager instance that happened to exist when this row was
            -- registered. KOReader clears FileManager.instance when the
            -- browser closes and builds a fresh one on the way back
            -- (filemanager.lua: `FileManager.instance = nil`), so the
            -- captured `fm` goes stale -- and closing a stale instance's
            -- dialog is a no-op, which leaves the long-press menu sitting
            -- on screen swallowing every tap.
            local function close_dialog()
                if close_cb then
                    close_cb()
                    return
                end
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                local live = (ok_fm and FM.instance) or fm
                if not live then return end
                -- FileManager stores the long-press dialog as
                -- `file_dialog`, not on its file_chooser.
                local dialog = live.file_dialog
                    or (live.file_chooser and live.file_chooser.file_dialog)
                if dialog then
                    UIManager:close(dialog)
                    live.file_dialog = nil
                end
            end

            -- One button per row, and short labels.
            --
            -- Three buttons in one row gave each of them about a third of
            -- the screen, which is narrow enough that KOReader's
            -- truncation path kicks in (ui/widget/button.lua):
            --
            --     while self.label_widget:isTruncated() do
            --         ... free the widget, rebuild it one point smaller,
            --         ... lay the text out and render it again
            --     end
            --
            -- One text render per font size, per button, every time the
            -- long-press menu opens. KOReader's own rows hold at most two
            -- buttons and never go down that path. Single full-width
            -- buttons with short labels do not truncate, so the loop does
            -- not run at all.
            --
            -- "(CL)" marked these as cloud actions, which meant something
            -- when they were gesture-bound; in a menu the user is already
            -- tapping, it is just four characters of noise.
            return {
                {
                    text = _("Upload metadata"),
                    callback = function()
                        close_dialog()
                        nextTickGuarded(_("Metadata upload"), function()
                            local DocSettings = require("docsettings")
                            local metadata_file = DocSettings:findSidecarFile(file)
                            if not metadata_file or not lfs.attributes(metadata_file, "mode") then
                                notify.error(_("Local metadata file not found"))
                                return
                            end
                            local props = book_props or {}
                            local title = props.title or props.display_title
                                or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
                            local author = props.authors
                            if type(author) == "table" then author = author[1] end
                            local book = {
                                file = file,
                                metadata = metadata_file,
                                title = title,
                                book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
                                author = author,
                            }
                            local remote = module("remote")
                            local success, error_type = remote.upload_book(book)
                            if success then
                                notify.success(_("Metadata uploaded"))
                            else
                                local error_info = remote.get_error_message(error_type, true)
                                notify.error(T(_("Upload failed: %1"), error_info.reason))
                            end
                        end)
                    end,
                },
                {
                    text = _("Download metadata"),
                    callback = function()
                        close_dialog()
                        nextTickGuarded(_("Metadata download"), function()
                            local DocSettings = require("docsettings")
                            local metadata_file = DocSettings:findSidecarFile(file)
                            if not metadata_file or not lfs.attributes(metadata_file, "mode") then
                                notify.error(_("Local metadata file not found"))
                                return
                            end
                            local props = book_props or {}
                            local title = props.title or props.display_title
                                or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
                            local author = props.authors
                            if type(author) == "table" then author = author[1] end
                            local book = {
                                file = file,
                                metadata = metadata_file,
                                title = title,
                                book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
                                author = author,
                            }
                            local remote = module("remote")
                            local success, error_type = remote.download_book_merge(book)
                            if success then
                                notify.success(_("Metadata updated from cloud"))
                            else
                                local error_info = remote.get_error_message(error_type, false)
                                notify.error(T(_("Download failed: %1"), error_info.reason))
                            end
                        end)
                    end,
                },
                {
                    text = _("Upload book"),
                    callback = function()
                        close_dialog()
                        nextTickGuarded(_("Book upload"), function()
                            local BookSync = module("book_sync")
                            BookSync.upload_book(file, true, book_props or {})
                        end)
                    end,
                },
            }
        end)

    return true
end


function BookSyncPlugin:chooseBookLocalDir()
    local DownloadMgr = require("ui/downloadmgr")
    local current_dir = self.settings.book_download_dir
    
    DownloadMgr:new{
        title = _("Select Book Download Directory"),
        onConfirm = function(path)
            if path and path ~= "" then
                self.settings.book_download_dir = path
                G_reader_settings:saveSetting(self.plugin_id, self.settings)
                notify.success(T(_("Book download directory set: %1"), path))
            end
        end,
    }:chooseDir(current_dir)
end

-- Upload the book file currently open in the reader, or — when the user has
-- left the reader and returned to FileManager — the most recently opened book
-- (its path is remembered by the onReaderReady hook). Mirrors
-- manual_sync:syncCurrentBook(true) but for the book file itself.
function BookSyncPlugin:uploadCurrentBook()
    local utils = module("utils")
    local ui = self.ui
    local file
    if ui and ui.document then
        file = ui.document.file
    else
        file = self.settings.last_book_file
    end
    if not file or not lfs.attributes(file, "mode") then
        utils.show_msg(_("No book to upload, please open a book first"))
        return
    end

    local BookSync = module("book_sync")

    local props = {}
    if ui and ui.bookinfo then
        props = ui.bookinfo:getDocProps(file, nil, true) or {}
    end
    local title = props.title or props.display_title
        or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        utils.scheduleSafe("Upload current book", 0, function()
            BookSync.upload_book(file, true, {title = title, author = author})
        end)
    end)
end




function BookSyncPlugin:batchDownloadBooks()
    local utils = module("utils")
    local download_dir = self.settings.book_download_dir
    if not download_dir or download_dir == "" then
        utils.show_msg(_("Please set book download directory in settings first"))
        return
    end
    
    local BookSync = module("book_sync")
    BookSync.show_cloud_book_dialog(function(selected_books)
        -- selected_books 现在包含 name 和 size 的完整对象
        BookSync.batchDownloadBooks(selected_books, self.settings, self)
    end, self)
end




function BookSyncPlugin:onDispatcherRegisterActions()
    -- ============================================================
    -- 通用手势（阅读器 + 文件管理器）
    -- ============================================================
    Dispatcher:registerAction("booksync_quick_actions", {
        category = "none",
        event = "CloudLibraryQuickActions",
        title = self.fullname .. " - " .. _("Quick Actions"),
        general = true,
    })

    Dispatcher:registerAction("booksync_autosync", {
        category = "none",
        event = "CloudLibraryAutoSync",
        title = self.fullname .. " - " .. _("Worry-Free Sync Mode"),
        general = true,
    })

    Dispatcher:registerAction("booksync_exclude_dirs", {
        category = "none",
        event = "CloudLibraryExcludeDirs",
        title = self.fullname .. " - " .. _("Exclude Directories"),
        general = true,
    })

    -- ============================================================
    -- 仅阅读器手势（需要打开书籍）
    -- ============================================================
    Dispatcher:registerAction("booksync_upload_current", {
        category = "none",
        event = "CloudLibraryUploadCurrent",
        title = self.fullname .. " - " .. _("Upload current book metadata"),
        reader = true,
    })
    
    Dispatcher:registerAction("booksync_download_current", {
        category = "none",
        event = "CloudLibraryDownloadCurrent",
        title = self.fullname .. " - " .. _("Download current book metadata (Smart mode)"),
        reader = true,
    })

    -- ============================================================
    -- 仅文件管理器手势（需要选择文件）
    -- ============================================================
    Dispatcher:registerAction("booksync_batch_upload_metadata", {
        category = "none",
        event = "CloudLibraryBatchUploadMetadata",
        title = self.fullname .. " - " .. _("Batch upload selected books metadata"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("booksync_batch_download_metadata_smart", {
        category = "none",
        event = "CloudLibraryBatchDownloadMetadataSmart",
        title = self.fullname .. " - " .. _("Batch download metadata (Smart mode)"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("booksync_batch_upload_books", {
        category = "none",
        event = "CloudLibraryBatchUploadBooks",
        title = self.fullname .. " - " .. _("Batch upload selected books"),
        filemanager = true,
    })
    
    Dispatcher:registerAction("booksync_batch_download_books", {
        category = "none",
        event = "CloudLibraryBatchDownloadBooks",
        title = self.fullname .. " - " .. _("Batch download/delete cloud books"),
        filemanager = true,
    })
end

-- ============================================================
-- 通用手势处理函数
-- ============================================================

function BookSyncPlugin:onCloudLibraryQuickActions()
    local context
    if self.ui and self.ui.document then
        context = "reader"
    else
        context = "filemanager"
    end
    self:showSyncDialog(context)
end

function BookSyncPlugin:onCloudLibraryAutoSync()
    self:toggleAutoSyncQuick()
end

function BookSyncPlugin:onCloudLibraryExcludeDirs()
    self:showExcludeDirDialog()
end

-- ============================================================
-- Live resolution for the declared plugin lifecycle events
-- ============================================================
--
-- KOReader dispatches onPageUpdate / onResume / onFlushSettings / onSuspend /
-- onCloseDocument to the plugin CLASS table, not to the instance that init()
-- built -- so `self.auto_sync` and `self.ui` are both nil on the object these
-- handlers actually run against. And `self.ui` is whichever screen the menu
-- was last opened from, so a user who configures from the FileManager (the
-- normal place) got nothing at all from flush, resume and page update.
--
-- These accessors resolve the live singleton and the live reader at call
-- time, so the triggers work regardless of where the menu was opened and
-- whether it has been opened at all this session.
local function live_auto_sync()
    if BookSyncPlugin._auto_sync then return BookSyncPlugin._auto_sync end
    -- Never opened the menu this session: build the object on demand so the
    -- declared events still work.
    -- module() was an ARGUMENT to pcall, so it was evaluated BEFORE the
    -- boundary -- and it would have been dofile-ing a non-existent
    -- "_plugin_dir.lua", so the whole accessor raised and the events it feeds
    -- stayed dead in exactly the state it was written for. Wrapping the call
    -- itself is the fix; the loader already knows the directory.
    local ok, AutoSync = pcall(function() return module("auto_sync") end)
    if not ok or type(AutoSync) ~= "table" then return nil end
    local st = G_reader_settings:readSetting("booksync_plugin")
    if type(st) ~= "table" then return nil end
    local obj = AutoSync:new(BookSyncPlugin, st)
    BookSyncPlugin._auto_sync = obj
    return obj
end

local function live_document()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return nil end
    local instance = ReaderUI.instance
    return instance and instance.document or nil
end

-- Declared plugin event, preferred over wrapping ReaderUI.onClose. The wrap
-- stays installed as a fallback for KOReader versions that do not dispatch it,
-- and hooks.lua latches on the document so whichever arrives first runs the
-- upload and the other one does nothing. This plugin is therefore correct
-- whether or not the event exists, and can never upload twice when it does.
function BookSyncPlugin:onCloseDocument()
    local live = module("hooks")._live or {}
    local hooks = live.hooks
    if not hooks then
        -- The menu has not been opened this session, so no Hooks object exists
        -- yet; the ReaderUI wrap installed at load time covers this case.
        return
    end
    pcall(function() hooks:handleDocumentClosed() end)
end

-- ============================================================
-- KOReader lifecycle event handlers for automatic metadata sync
-- ============================================================

-- On resuming from suspend: upload current book metadata + optionally
-- download all books metadata (pull latest progress from other devices).
function BookSyncPlugin:onResume()
    local auto_sync = live_auto_sync()
    local document = live_document()
    if not auto_sync then return end
    -- The all-books pull is directory work and must work with no book open.
    if auto_sync:shouldDownloadAll("resume") then
        auto_sync:syncAllBooksMetadata(false, "resume")
    end
    if not document then return end
    if auto_sync:shouldUpload("resume") then
        auto_sync:sync(document, true, "resume")
    end
end

-- On FlushSettings (KOReader periodically saves settings, roughly every 5 min):
-- upload current book metadata so reading progress is backed up regularly.
function BookSyncPlugin:onFlushSettings()
    local auto_sync = live_auto_sync()
    local document = live_document()
    if not auto_sync or not document then return end
    if auto_sync:shouldUpload("flush") then
        auto_sync:sync(document, true, "flush")
    end
end

-- Detect chapter changes while paging through the document (paginated mode,
-- e.g. PDF). When the chapter title changes, upload current book metadata.
function BookSyncPlugin:onPageUpdate(page)
    self:_checkChapterChange(page)
end

-- Detect chapter changes in scroll/continuous mode (CREngine, e.g. EPUB).
function BookSyncPlugin:onPosUpdate(pos)
    -- Gate first. onPosUpdate fires on every scroll and every held-down page
    -- turn in continuous mode, and getCurrentPage() is a search over the
    -- document's xpoint page map -- real work, on the hottest path in the
    -- plugin -- to produce a page number that _checkChapterChange then throws
    -- away when auto-upload-on-chapter is off. _checkChapterChange checks the
    -- same flag again, so the gate here costs nothing and changes no behaviour.
    local auto_sync = live_auto_sync()
    if not auto_sync or not auto_sync:shouldUpload("chapter") then
        return
    end
    local page = self.ui and self.ui.document and self.ui.document:getCurrentPage()
    if page then
        self:_checkChapterChange(page)
    end
end

-- Internal: get the current chapter title via ReaderToc and compare it with
-- the last known chapter. If it changed, trigger a metadata upload. Uses pcall
-- so a missing or renamed ReaderToc method can never crash the reader.
-- Runs on EVERY page turn, so the early-outs matter: this is the cheapest
-- gate first, and the toc lookup is inside a pcall because ReaderUI can be
-- half torn down. The chapter title is what we key on, so a book whose toc
-- yields no title simply never triggers -- that is correct, not a failure.
function BookSyncPlugin:_checkChapterChange(page)
    local auto_sync = live_auto_sync()
    if not auto_sync or not auto_sync:shouldUpload("chapter") then
        return
    end
    local ok_read, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_read or not ReaderUI or not ReaderUI.instance then return end
    local ui = ReaderUI.instance
    if not ui.document then return end

    local current_chapter
    pcall(function()
        local toc = ui.toc
        if toc then
            if toc.getTocTitleByPage then
                current_chapter = toc:getTocTitleByPage(page)
            elseif toc.getTocTitleOfCurrentPage then
                current_chapter = toc:getTocTitleOfCurrentPage()
            end
        end
    end)

    if current_chapter and current_chapter ~= "" then
        -- _last_chapter lives on the singleton, which is the same object the
        -- reader-close hook resets. It used to live on the plugin instance,
        -- which init() recreates per menu entry, so the reset never applied
        -- and every new book fired a spurious upload on its first page.
        if auto_sync._last_chapter == nil then
            auto_sync._last_chapter = current_chapter
        elseif current_chapter ~= auto_sync._last_chapter then
            auto_sync._last_chapter = current_chapter
            auto_sync:sync(ui.document, true, "chapter")
        end
    end
end

function BookSyncPlugin:showSyncDialog(context)
    local buttons = {}
    local BookSync = module("book_sync")
    
if context == "reader" then
    buttons = {
        { 
            { text = _("Upload current book metadata"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self.manual_sync:syncCurrentBook(true)
            end } 
        },
        { 
            { text = _("Download current book metadata"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self.manual_sync:syncCurrentBookMerge()
            end } 
        },
    }
else
    buttons = {
        { 
            { text = _("Batch upload selected books metadata"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self.manual_sync:batchSyncWithFMSelection(true, false)
            end } 
        },
        { 
            {
                text = _("Batch download selected books metadata"),
                callback = function()
                    if self._current_dialog then
                        UIManager:close(self._current_dialog)
                        self._current_dialog = nil
                    end
                    self.manual_sync:batchSyncWithFMSelection(false, true)
                end
            } 
        },
        { 
            { text = _("Batch upload selected books"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                BookSync.batchUploadWithFMSelection(self)
            end } 
        },
        { 
            { text = _("Batch download/delete cloud books"), callback = function()
                if self._current_dialog then
                    UIManager:close(self._current_dialog)
                    self._current_dialog = nil
                end
                self:batchDownloadBooks()
            end } 
        },
    }
end
    
    local dialog = ButtonDialog:new{
        title = self.fullname .. " - " .. _("Quick Actions"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.6),
    }
    self._current_dialog = dialog
    UIManager:show(dialog)
end

-- These two gestures are dispatched in the reader AND in the FileManager, so
-- they resolve the target the same way the menu entries do -- including falling
-- back to the last opened book instead of silently doing nothing.
function BookSyncPlugin:onCloudLibraryUploadCurrent()
    local target = self.manual_sync:resolveTargetBook()
    if not target then
        module("utils").show_msg(_("No book is currently open"))
        return
    end
    self.manual_sync:syncCurrentBook(true)
end

function BookSyncPlugin:onCloudLibraryDownloadCurrent()
    local target = self.manual_sync:resolveTargetBook()
    if not target then
        module("utils").show_msg(_("No book is currently open"))
        return
    end
    self.manual_sync:syncCurrentBookMerge()
end


function BookSyncPlugin:showExcludeDirDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen

    local self_ref = self
    local exclude_dirs = self.settings.exclude_dirs or {}

    -- Returning from the directory picker re-opens this dialog, and the old
    -- instance is still on the stack underneath. Close it first, or the user
    -- gets a second copy of the same list on top of the first.
    if self_ref._exclude_dir_dialog then
        pcall(function() UIManager:close(self_ref._exclude_dir_dialog) end)
        self_ref._exclude_dir_dialog = nil
    end

    local buttons = {}
    
    -- 添加新目录按钮
    --
    -- This dialog used to close ITSELF before opening the picker, so cancelling
    -- the picker dropped the user onto whatever was underneath it -- the plugin
    -- menu, or in the reader, the book. Keeping the list open underneath
    -- avoids that, and the callback rebuilds it: the button table above was
    -- captured when the dialog was built, so a newly added path would not
    -- appear in it.
    table.insert(buttons, {
        {
            text = _("+ Add Directory to Exclude"),
            callback = function()
                self_ref:addExcludeDir(function()
                    self_ref:showExcludeDirDialog()
                end)
            end
        }
    })
    
    table.insert(buttons, {})
    
    -- 显示已排除的目录列表
    if #exclude_dirs == 0 then
        table.insert(buttons, {
            {
                text = _("(No directories excluded)"),
                enabled = false,
                alignment = "center",
            }
        })
    else
        for i, dir in ipairs(exclude_dirs) do
            local display_dir = dir
            if #display_dir > 35 then
                display_dir = "..." .. display_dir:sub(-32)
            end
            table.insert(buttons, {
                {
                    text = display_dir,
                    enabled = false,
                }
            })
            table.insert(buttons, {
                {
                    text = _("Remove"),
                    callback = function()
                        self_ref:removeExcludeDir(i)
                    end
                }
            })
            if i < #exclude_dirs then
                table.insert(buttons, {})
            end
        end
    end
    
    table.insert(buttons, {})
    
    -- One button, not two.
    --
    -- "Back" used to open a separate Quick Settings dialog rather than going
    -- back anywhere: it was a sibling window, not a parent, so it left the
    -- exclude list closed and dropped the user into a different screen. With
    -- that window gone, Back had nowhere to go. Closing this dialog is already
    -- the way back -- it is shown on top of the plugin menu, so closing it
    -- uncovers the menu the user came from.
    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                if self_ref._exclude_dir_dialog then
                    UIManager:close(self_ref._exclude_dir_dialog)
                    self_ref._exclude_dir_dialog = nil
                end
            end
        }
    })
    
    local dialog = ButtonDialog:new{
        title = _("Auto Sync Exclude Directories"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.75),
        max_height = math.floor(Screen:getHeight() * 0.6),
    }
    
    self_ref._exclude_dir_dialog = dialog
    UIManager:show(dialog)
end

function BookSyncPlugin:onCloudLibraryBatchUploadMetadata()
    self.manual_sync:batchSyncWithFMSelection(true, false)
end

function BookSyncPlugin:onCloudLibraryBatchDownloadMetadataSmart()
    self.manual_sync:batchSyncWithFMSelection(false, true)
end

function BookSyncPlugin:onCloudLibraryBatchUploadBooks()
    local BookSync = module("book_sync")
    BookSync.batchUploadWithFMSelection(self)
end

function BookSyncPlugin:onCloudLibraryBatchDownloadBooks()
    self:batchDownloadBooks()
end

-- Every settings key that arms an automatic trigger. The gesture shortcut and
-- the "disable all" menu entry both go through here, so a new trigger can never
-- be added to the UI without also being switched off by the one control that
-- claims to turn everything off.
function BookSyncPlugin:disableAllAutoSyncSettings()
    local S = self.settings
    S.auto_upload_on_annotate = false
    S.auto_upload_on_open = false
    S.auto_upload_on_close = false
    S.auto_upload_on_suspend = false
    S.auto_upload_on_resume = false
    S.auto_upload_on_flush = false
    S.auto_upload_on_chapter = false
    S.auto_upload_book_on_open = false
    S.auto_upload_all_on_open = false
    S.auto_upload_all_on_close = false
    S.auto_upload_all_on_suspend = false
    S.auto_upload_all_on_start = false
    S.auto_upload_last_book_on_start = false
    S.auto_download_on_open = false
    S.auto_download_all_on_start = false
    S.auto_download_all_on_open = false
    S.auto_download_all_on_resume = false
    return S
end

function BookSyncPlugin:toggleAutoSyncQuick()
    local is_auto_mode = self.settings.auto_upload_on_close and 
                         self.settings.auto_upload_on_suspend and 
                         self.settings.auto_download_on_open
    
    if is_auto_mode then
        -- "All auto sync disabled" has to actually disable all of it. This
        -- cleared 4 flags and said so, while 14 triggers -- every app-start,
        -- chapter, flush and open upload, and the whole upload-all/download-all
        -- family -- stayed armed. Turning the feature off and watching it keep
        -- syncing is worse than not having the shortcut at all, because the
        -- message says the opposite.
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = false
        self.settings.auto_upload_on_suspend = false
        self.settings.auto_download_on_open = false
        self.settings.auto_download_mode = "merge"
        self:disableAllAutoSyncSettings()
        
        
        local utils = module("utils")
        utils.show_msg(_("Cloud Library: All auto sync disabled"))
    else
        self.settings.auto_upload_on_annotate = false
        self.settings.auto_upload_on_close = true
        self.settings.auto_upload_on_suspend = true
        self.settings.auto_download_on_open = true
        self.settings.auto_download_mode = "merge"
        
        
        local utils = module("utils")
        utils.show_msg(_("Cloud Library: Worry-Free Sync Mode enabled (auto upload on close/suspend + auto download merge on open)"))
    end
end

-- ============================================================
-- Startup hooks (installed at load time, not from init())
-- ============================================================
--
-- PluginLoader:_load() runs `pcall(dofile, mainfile)` for every plugin during
-- boot, so this file's top level executes before any UI exists. That is the
-- only place early enough to observe "the app just launched". Both features
-- below used to depend on the user opening this plugin's menu at least once,
-- because their hooks were installed from init().

local function install_startup_hooks()
    local utils = module("utils")

    -- Make sure the settings table exists before anything tries to write to it.
    -- remember_last_book() bails out when the table is missing, and a fresh
    -- install has no booksync_plugin entry until the menu is opened for the
    -- first time -- so without this the "last book" fallback would silently stay
    -- empty, which is exactly the bug this feature exists to fix.
    --
    -- Note: copy rather than store default_settings by reference. LuaSettings
    -- hands the stored table back on every read, so sharing the defaults object
    -- would let later edits corrupt them.
    if type(G_reader_settings:readSetting("booksync_plugin")) ~= "table" then
        local seeded = {}
        for k, v in pairs(BookSyncPlugin.default_settings) do
            if type(v) == "table" then
                local copy = {}
                for k2, v2 in pairs(v) do copy[k2] = v2 end
                seeded[k] = copy
            else
                seeded[k] = v
            end
        end
        G_reader_settings:saveSetting("booksync_plugin", seeded)
    end

    -- 1. Record the last opened book.
    --    The "current book" actions fall back to it when no book is open (e.g.
    --    from the FileManager); without this the fallback stayed empty until
    --    the menu had been opened once, so the feature appeared broken on a
    --    fresh install.
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and type(ReaderUI.showReader) == "function"
        and not rawget(ReaderUI, "_booksync_lastbook_hooked") then
        rawset(ReaderUI, "_booksync_lastbook_hooked", true)
        local original = ReaderUI.showReader
        ReaderUI.showReader = function(...)
            local args = { ... }
            -- showReader(self, file, ...) -- the file is the 2nd argument
            if #args >= 2 and type(args[2]) == "string" then
                pcall(utils.remember_last_book, args[2])
            end
            return original(...)
        end
    end

    -- 2. "On app start" actions.
    --    FileManager:init is the single FileManager constructor (showFiles is
    --    its only caller) and KOReader builds one at boot. showFiles also runs
    --    every time the reader returns to the library, so the latch below is
    --    what keeps this to once per launch.
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and type(FileManager.init) == "function"
        and not rawget(FileManager, "_booksync_start_hooked") then
        rawset(FileManager, "_booksync_start_hooked", true)
        local original_init = FileManager.init

        local app_start_done = false
        local function on_app_start()
            if app_start_done then return end
            app_start_done = true
            local delay = 1
            utils.scheduleSafe("auto sync on app start", delay, function()
                local settings = G_reader_settings:readSetting("booksync_plugin")
                if type(settings) ~= "table" then return end

                -- Resolve `ui` lazily: do_it() may run much later (deferred
                -- until the network comes back), by which time the FileManager
                -- instance will have been replaced.
                local stand_in = {
                    plugin_id = "booksync_plugin",
                    settings = settings,
                }
                setmetatable(stand_in, {
                    __index = function(t, k)
                        if k == "ui" then return FileManager.instance end
                        return rawget(t, k)
                    end,
                })
                local auto_sync = module("auto_sync"):new(stand_in, settings)
                -- ask the same should* helpers every other trigger uses, so
                -- there is exactly one definition of "is this trigger on"
                local wants_upload = auto_sync:shouldUpload("appstart")
                local wants_download = auto_sync:shouldDownloadAll("appstart")
                if not (wants_upload or wants_download) then return end

                local lfs = require("libs/libkoreader-lfs")
                local NetworkMgr = require("ui/network/manager")

                local function do_it()
                    if wants_download then
                        -- Already handles root resolution (current directory,
                        -- else the last book's folder) and the exclude list.
                        auto_sync:syncAllBooksMetadata(false, "appstart")
                    end

                    if wants_upload then
                        local last = settings.last_book_file
                        if type(last) == "string" and lfs.attributes(last, "mode") == "file" then
                            local DocSettings = require("docsettings")
                            local metadata_file = DocSettings:findSidecarFile(last)
                            if metadata_file and lfs.attributes(metadata_file, "mode") then
                                -- No self here: book_props falls back to the sidecar, which is where
                                -- the properties live once a book has been opened.
                                local _f, stem, title, author = book_identity(nil, last)
                                local ok_up, err = pcall(function()
                                    module("remote").upload_book({
                                        file = last,
                                        metadata = metadata_file,
                                        title = title,
                                        author = author,
                                        book_basename = stem,
                                    })
                                end)
                                if not ok_up then
                                    logger.err("BookSync: app-start upload failed: " .. tostring(err))
                                end
                            end
                        end
                    end
                end

                if NetworkMgr:isOnline() then
                    do_it()
                else
                    -- Offline at launch: defer. Popping the Wi-Fi prompt while
                    -- the library is still opening is the last thing anyone
                    -- wants at boot.
                    NetworkMgr:willRerunWhenOnline(do_it)
                end
            end)
        end

        FileManager.init = function(...)
            local result = original_init(...)

            -- Add the long-press row here, immediately after the instance is
            -- built and before the user can possibly long-press anything.
            --
            -- The instance is brand new at this point, so this is a write to a
            -- table no one is reading yet. Registering from a timer instead --
            -- which is what this did until v1.37 -- meant writing to
            -- instance.file_dialog_added_buttons while filemanager.lua was
            -- running ipairs() over it to build the long-press dialog.
            --
            -- `_booksync_row_registered` keeps this to one add per instance,
            -- and addFileDialogButtons indexes by row_id anyway.
            local ok_reg, reg_err = pcall(function()
                return BookSyncPlugin:_registerLongPressRow()
            end)
            if not ok_reg then
                logger.err("BookSync: long-press row registration failed: " .. tostring(reg_err))
            end

            utils.nextTickSafe("app start", on_app_start)
            return result
        end

        -- Cold boot into the file browser, which is what start_with defaults
        -- to, used to skip "On app start" entirely. The whole boot is one
        -- in-flight FileManager:init() call:
        --
        --   filemanager.lua:418   PluginLoader:loadPlugins()   <- this file
        --   filemanager.lua:447   FileManager.instance = self  <- instance appears
        --
        -- So when this plugin loads, the browser is half-built and
        -- FileManager.instance is still nil. The wrapper above misses the
        -- construction it was installed during, and a guard on
        -- FileManager.instance here would see nil too.
        --
        -- The next tick runs once init() has returned and the instance is
        -- set. Both calls are latch-guarded one-shots, so when the wrapper
        -- does fire later -- the next time the library is opened -- they are
        -- no-ops, and this remains the only path that runs on a cold boot.
        utils.nextTickSafe("booksync startup", function()
            BookSyncPlugin:_registerLongPressRow()
            on_app_start()
        end)
    end
end

install_startup_hooks()

-- Once per launch, and it self-throttles to hourly. Removes temporary files
-- left by interrupted transfers; without it a device on a flaky connection
-- slowly fills up with bytes the user can neither see nor reclaim. Runs before
-- any plugin file is loaded, so the only call it makes is require() plus io,
-- and it is fully pcall'd either way.
pcall(function()
    local u = module("utils")
    u.reap_temp_files(u.temp_dirs())
end)

-- ============================================================
-- Error boundary for every entry point KOReader can call
-- ============================================================
--
-- Plugin event handlers (onResume, onFlushSettings, onPageUpdate, onPosUpdate)
-- and dispatcher actions (the onCloudLibrary* gestures) are invoked from inside
-- KOReader's own event loop, in the middle of a page turn or a gesture. An
-- error escaping one of those is a crash at the least convenient possible
-- moment, and these run unconditionally on hot paths like every scroll event.
-- Wrap them all in one place rather than sprinkling pcall through the bodies.
local PLUGIN_ENTRY_POINTS = {
    "onDispatcherRegisterActions",
    "onResume", "onFlushSettings", "onPageUpdate", "onPosUpdate", "_checkChapterChange",
    "onCloudLibraryQuickActions", "onCloudLibraryAutoSync",
    "onCloudLibraryExcludeDirs", "onCloudLibraryUploadCurrent", "onCloudLibraryDownloadCurrent",
    "onCloudLibraryBatchUploadMetadata", "onCloudLibraryBatchDownloadMetadataSmart",
    "onCloudLibraryBatchUploadBooks", "onCloudLibraryBatchDownloadBooks",
}

for _, name in ipairs(PLUGIN_ENTRY_POINTS) do
    local fn = BookSyncPlugin[name]
    if type(fn) == "function" then
        BookSyncPlugin[name] = function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                module("utils").log_crash("entry point " .. name, err)
            end
        end
    end
end

return BookSyncPlugin
