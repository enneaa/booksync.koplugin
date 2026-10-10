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
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local _ = module("gettext_shim")
local Event = require("ui/event")
local T = require("ffi/util").template
local util = require("util")
local utils = module("utils")
local notify = module("notify")
local DownloadDialog = utils.DownloadDialog

local ManualSync = {}

function ManualSync:new(plugin, auto_sync)
    local obj = {}
    setmetatable(obj, self)
    self.__index = self
    
    obj.plugin = plugin
    obj.auto_sync = auto_sync
    obj.settings = plugin.settings
    
    return obj
end

-- The book a "current book" action should act on: the one open in the reader,
-- otherwise the last one opened. Falls back exactly like BookSyncPlugin:
-- uploadCurrentBook() does for the book file, so both actions in the same menu
-- always target the same book.
-- The action/button labels a "pick some books first" hint needs. Six call
-- sites across manual_sync.lua and book_sync.lua asked for the same hint and
-- each built the label pair on its own; a wording change had to land six times.
local function batchLabels(is_upload, is_merge)
    if is_upload then
        return _("upload"), _("Batch upload metadata")
    end
    return _("download"), _("Batch download metadata")
end

-- Put the FileManager into select mode (if it is not already) and tell the
-- user what to do next. The hint is the only thing standing between "nothing
-- happened" and a user who thinks the button is broken.
function ManualSync:hintSelectBooks(is_upload, is_merge)
    local action_text, button_text = batchLabels(is_upload, is_merge)
    notify.hint(T(_("Select books to %1, then tap \"%1\""), action_text, button_text))
end

function ManualSync:resolveTargetBook()
    if self.plugin and self.plugin.ui and self.plugin.ui.document then
        return self.plugin.ui.document.file, true
    end
    local f = self.settings and self.settings.last_book_file
    if type(f) == "string" and lfs.attributes(f, "mode") == "file" then
        return f, false
    end
    return nil, false
end

function ManualSync:syncCurrentBook(is_upload, retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        self:syncCurrentBook(is_upload, true)
    end) then
        return
    end

    local file, is_open = self:resolveTargetBook()
    if not file then
        self:showMsg(_("No book open"))
        return
    end
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("No local metadata"))
        return
    end
    
    local remote = module("remote")
    local server = remote.check_preconditions_or_notify()
    if not server then
        return
    end
    if is_upload then
        self:doSyncCurrentBook(is_upload, file, metadata_file)
    else

        local confirm_dialog = ConfirmBox:new{
            title = _("Confirm download"),
            text = _("This operation requires reopening the current book to override update metadata. Continue?"),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                -- Sticky progress bar: no need to name the mode, and no room
                -- for it on a narrow e-ink line.
                notify.progress(_("Downloading and applying metadata..."))
                utils.nextTickSafe("Sync current book", function()
                    self:doSyncCurrentBook(is_upload, file, metadata_file)
                end)
            end
        }
        UIManager:show(confirm_dialog)
    end
end

function ManualSync:syncCurrentBookMerge(retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        self:syncCurrentBookMerge(true)
    end) then
        return
    end
    local doc = self.plugin.ui.document
    if not doc then
        self:showMsg(_("No book open"))
        return
    end
    
    local file = doc.file
    local DocSettings = require("docsettings")
    local metadata_file = DocSettings:findSidecarFile(file)
    
    if not metadata_file then
        self:showMsg(_("No local metadata"))
        return
    end
    
    local remote = module("remote")
    local server = remote.check_preconditions_or_notify()
    if not server then
        return
    end
    self.plugin.ui:saveSettings()
    
    local confirm_dialog = ConfirmBox:new{
        title = _("Confirm merge download"),
        text = _("This operation requires reopening the current book to merge update metadata. Continue?"),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            notify.progress(T(_("Downloading and applying metadata - %1..."), _("Merge")))
            utils.nextTickSafe("Merge current book", function()
                self:doSyncCurrentBookMerge(file, metadata_file)
            end)
        end
    }
    UIManager:show(confirm_dialog)
end

function ManualSync:doSyncCurrentBook(is_upload, file, metadata_file)
    if is_upload then
        self.auto_sync:setSkipUpload(true)
    else
        self.auto_sync:setSkipDownload(true)
    end

    local props = {}
    if self.plugin.ui and self.plugin.ui.bookinfo then
        local ok_props, p = pcall(function()
            return self.plugin.ui.bookinfo:getDocProps(file, nil, true)
        end)
        if ok_props and type(p) == "table" then props = p end
    end
    local title = props.title or props.display_title or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end

    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
        author = author,
    }

    local remote = module("remote")

    if is_upload then
        local success, error_type = remote.upload_book(book)

        if success then
            notify.success(_("Metadata uploaded"))
            self:writeSingleLog(book, true, false, true)
            self:updateLastSync(_("Metadata sync") .. "-" .. _("Single upload") .. "-" .. _("Overwrite cloud"))
        else
            local error_info = remote.get_error_message(error_type, true)
            notify.error(T(_("Upload failed: %1"), error_info.reason))
            self:writeSingleLog(book, true, false, false, error_info.reason)
        end
        self.auto_sync:setSkipUpload(false)
        return
    end

    -- Download
    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = current_ui and current_ui.document and current_ui.document.file == file

    -- Download to temp file
    local downloaded_file, cloud_filename, err_type = remote.download_to_temp(book)

    if not downloaded_file then
        local error_info = remote.get_error_message(err_type, false)
        notify.error(T(_("Download failed: %1"), error_info.reason))
        self:writeSingleLog(book, false, false, false, error_info.reason)
        self.auto_sync:setSkipDownload(false)
        return
    end

    -- Merge (done BEFORE touching the reader, so a bad download can never cost
    -- the user their place in the book).
    --
    -- This used to branch on override_keep_local_settings and, when that switch
    -- was off, write Merger.load_metadata(downloaded_file) straight back: the
    -- cloud table with every local-only annotation dropped. Both the switch and
    -- the replace path are gone.
    local Merger = module("merge")
    local merged_data = Merger.override_merge(book.metadata, downloaded_file)

    os.remove(downloaded_file)

    if not merged_data then
        notify.error(_("Could not apply the downloaded metadata"))
        self:writeSingleLog(book, false, false, false, "merge_failed")
        self.auto_sync:setSkipDownload(false)
        return
    end

    -- Apply + reload through ReaderUI:reloadDocument, KOReader's own
    -- close-and-reopen path. The old code called current_ui:onClose() here and
    -- then ReaderUI:showReader() on the half-destroyed widget stack; onClose
    -- runs PluginLoader:finalize() and UIManager:close() on the very dialog
    -- UIManager is currently dispatching, which is a hard crash.
    local write_ok = true

    if is_currently_open then
        self.auto_sync:setSkipUpload(true)
        -- The one-shot latch only has to outlive the reloadDocument below.
        -- Clearing it here (rather than in init(), on every menu entry) is what
        -- makes "open the menu" a read path again: a latch left set by an
        -- interrupted reload used to make the NEXT book skip its auto-download,
        -- and the only thing that reset it was opening this menu.
        if not remote.apply_with_latch(book.file, function(f)
            local wrote = remote.save_metadata_native(merged_data, f)
            self.auto_sync:setSkipUpload(false)
            return wrote
        end) then
            self.auto_sync:setSkipUpload(false)
            write_ok = false
        end
    else
        local ok_w = remote.save_metadata_native(merged_data, book.file)
        if not ok_w then write_ok = false end
    end

    -- Only say it worked if the sidecar actually accepted the data. A false here
    -- means a full disk, a read-only mount or a DocSettings error -- all
    -- retryable once the cause is gone, but only if the user is told.
    if write_ok then
        notify.success(_("Applied"))
    else
        logger.err("booksync: local metadata write failed (Merge)")
        -- Was two lines: the cause, then a sentence telling the user to check
        -- free space. The second line is the fix and is worth keeping, but
        -- "local metadata could not be written" repeated the first line's
        -- news. One line now, cause and fix both present.
        notify.error(_("Write failed - check free space and permissions"))
    end

    self:writeSingleLog(book, false, false, true)
    self:updateLastSync(_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Merge"))
    self.auto_sync:setSkipDownload(false)
end

function ManualSync:doSyncCurrentBookMerge(file, metadata_file)
    self.auto_sync:setSkipDownload(true)

    local props = {}
    if self.plugin.ui and self.plugin.ui.bookinfo then
        local ok_props, p = pcall(function()
            return self.plugin.ui.bookinfo:getDocProps(file, nil, true)
        end)
        if ok_props and type(p) == "table" then props = p end
    end
    local title = props.title or props.display_title or file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
    local author = props.authors
    if type(author) == "table" then
        author = author[1]
    end

    local book = {
        file = file,
        metadata = metadata_file,
        title = title,
        book_basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", ""),
        author = author,
    }

    local remote = module("remote")

    local ReaderUI = require("apps/reader/readerui")
    local current_ui = ReaderUI.instance
    local is_currently_open = current_ui and current_ui.document and current_ui.document.file == file

    -- Download to temp file
    local downloaded_file, cloud_filename, err_type = remote.download_to_temp(book)

    if not downloaded_file then
        local error_info = remote.get_error_message(err_type, false)
        notify.error(T(_("Download failed: %1"), error_info.reason))
        self:writeSingleLog(book, false, true, false, error_info.reason)
        self.auto_sync:setSkipDownload(false)
        return
    end

    -- Merge metadata (before touching the reader)
    local Merger = module("merge")
    local merged_data = Merger.merge(book.metadata, downloaded_file)
    os.remove(downloaded_file)

    if not merged_data then
        notify.error(_("Could not apply the downloaded metadata"))
        self:writeSingleLog(book, false, true, false, "merge_failed")
        self.auto_sync:setSkipDownload(false)
        return
    end

    local write_ok = true

    -- See doSyncCurrentBook: reloadDocument, never onClose()+showReader().
    if is_currently_open then
        self.auto_sync:setSkipUpload(true)
        -- The one-shot latch only has to outlive the reloadDocument below.
        -- Clearing it here (rather than in init(), on every menu entry) is what
        -- makes "open the menu" a read path again: a latch left set by an
        -- interrupted reload used to make the NEXT book skip its auto-download,
        -- and the only thing that reset it was opening this menu.
        if not remote.apply_with_latch(book.file, function(f)
            local wrote = remote.save_metadata_native(merged_data, f)
            self.auto_sync:setSkipUpload(false)
            return wrote
        end) then
            self.auto_sync:setSkipUpload(false)
            write_ok = false
        end
    else
        local ok_w = remote.save_metadata_native(merged_data, book.file)
        if not ok_w then write_ok = false end
    end

    if write_ok then
        notify.success(_("Applied"))
    else
        logger.err("booksync: local metadata write failed (Merge)")
        -- Was two lines: the cause, then a sentence telling the user to check
        -- free space. The second line is the fix and is worth keeping, but
        -- "local metadata could not be written" repeated the first line's
        -- news. One line now, cause and fix both present.
        notify.error(_("Write failed - check free space and permissions"))
    end

    self:writeSingleLog(book, false, true, true)
    self:updateLastSync(_("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Merge"))

    -- The reader may already be torn down by the time this fires, so the
    -- repaint is best-effort and must not be able to throw.
    utils.scheduleSafe("Redraw after merge", 0.5, function()
        if self.plugin.ui and self.plugin.ui.document then
            self.plugin.ui:handleEvent(Event:new("RedrawCurrentView"))
        end
    end)

    self.auto_sync:setSkipDownload(false)
end

-- `retry` used to be an undefined global: the recursive call below passed a
-- third argument that the (two-parameter) signature silently discarded, so the
-- re-entry never saw retry=true and re-armed willRerunWhenOnline forever. It is
-- a real parameter now.
function ManualSync:batchSyncWithFMSelection(is_upload, is_merge, retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        self:batchSyncWithFMSelection(is_upload, is_merge, true)
    end) then
        return
    end

    local remote = module("remote")
    local server = remote.check_preconditions_or_notify()
    if not server then
        return
    end
      -- ===== Bookshelf support =====
    if utils.isBookshelfShowing() then
        local files = utils.bookshelfGetSelectedFiles()
        
        if #files == 0 then
            utils.bookshelfEnterSelection()
            self:hintSelectBooks(is_upload, is_merge)
            return
        end
        
        local selected_files = {}
        for _, file in ipairs(files) do
            selected_files[file] = true
        end
        
        self:processSelectedFiles(is_upload, is_merge, selected_files)
        return
    end
    
    local ui = self.plugin.ui

    if not ui or not ui.file_chooser then
        local FileManager = require("apps/filemanager/filemanager")

        -- We are in the reader and need the FileManager to pick books. The old
        -- code tore the reader down inline (onClose -> PluginLoader:finalize +
        -- UIManager:close on the menu dialog we are currently inside) and then
        -- immediately opened the FileManager on the re-entered stack. Defer to
        -- a clean tick and go through ReaderUI:onHome(), which is KOReader's
        -- own "leave the book" path.
        local ReaderUI = require("apps/reader/readerui")
        local reader = ReaderUI.instance
        UIManager:nextTick(function()
            local ok, err = pcall(function()
                if reader and reader.document then
                    self.auto_sync:setSkipUpload(true)
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
                -- guarded: showFiles() can return an instance already in
                -- selection mode, and onToggleSelectMode is a toggle
                if fm and not fm.selected_files then
                    fm:onToggleSelectMode(true)
                end
                self:hintSelectBooks(is_upload, is_merge)
            end)
        end)
        return
    end
    
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    
    if not fm then
        self:showMsg(_("Could not open the file browser"))
        return
    end
    
    if fm.selected_files == nil then
        fm:onToggleSelectMode(true)
        self:hintSelectBooks(is_upload, is_merge)
        return
    end
    
    local selected_files = fm.selected_files
    if not selected_files or next(selected_files) == nil then
        self:hintSelectBooks(is_upload, is_merge)
        return
    end
    
    self:processSelectedFiles(is_upload, is_merge, selected_files)
end

-- Recursively scan a local directory for every book file KOReader can open
-- (using DocumentRegistry:hasProvider, the same test FileManager uses), then
-- batch-sync their metadata. Unlike batchSyncWithFMSelection the user does not
-- need to tick books one by one; every book under the chosen root is included.
-- The scan root is the current FileManager directory, falling back to the
-- directory of the book currently open in the reader.
--
-- scanAllBooks() is shared by both manual and auto "sync all" entry points.
-- It returns a list of book tables, or nil if no scan root could be
-- determined (an error message is shown in that case).
--
-- KOReader stores metadata sidecars in one of three locations
-- (document_metadata_folder setting): "doc" (alongside the book), "dir"
-- (central docsettings folder), or "hash" (hashed folder). For "dir" mode we
-- scan the central folder directly so every book's metadata is found no
-- matter where the book file lives; for "doc"/"hash" we scan the book
-- directory and rely on DocSettings:findSidecarFile() to locate metadata.
function ManualSync:scanAllBooks(on_done)
    local DocumentRegistry = require("document/documentregistry")
    local util = require("util")
    local DocSettings = require("docsettings")

    local metadata_location = G_reader_settings:readSetting("document_metadata_folder", "doc")
    local exclude_dirs = self.settings.exclude_dirs or {}

    local function is_book(file_path)
        return DocumentRegistry:hasProvider(file_path)
            and not DocumentRegistry:isImageFile(file_path)
            and util.getScriptType(file_path) == nil
    end

    local function get_props(book_path)
        local props = {}
        if self.plugin.ui and self.plugin.ui.bookinfo then
            local ok, p = pcall(function()
                return self.plugin.ui.bookinfo:getDocProps(book_path, nil, true)
            end)
            if ok and type(p) == "table" then
                props = p
            elseif not ok then
                logger.err("booksync: getDocProps failed in scan:", tostring(p))
            end
        end
        return props
    end

    local function make_book(book_path, metadata_file)
        local props = get_props(book_path)
        local title = props.title or props.display_title
        local basename = (book_path:match("([^/]+)$") or book_path):gsub("%.[^%.]+$", "")
        local author = props.authors
        if type(author) == "table" then
            author = author[1]
        end
        return {
            file = book_path,
            metadata = metadata_file,
            title = title or basename,
            book_basename = basename,
            author = author,
        }
    end

    -- ===================================================================
    -- Cooperative directory walk
    -- ===================================================================
    --
    -- This used to recurse through the whole tree in one call. Every entry
    -- costs a hasProvider / isImageFile / getScriptType round plus a
    -- getDocProps, all synchronous on the main thread, so a few hundred books
    -- froze the screen for the whole duration with nothing drawn on it. The
    -- manual run hides that behind a progress dialog; the automatic one has no
    -- dialog at all and used to run it while KOReader was still painting its
    -- own first frame.
    --
    -- So the walk is a state machine now. Each queue entry carries the listing
    -- of its directory and a cursor into it, and a slice inspects at most
    -- BATCH entries before handing control back so KOReader can repaint and
    -- run its own tasks. Nothing is re-read and nothing is skipped: the
    -- cursor is what makes the walk resumable.
    local BATCH = 25

    local books = {}
    local budget = BATCH

    local function list_dir(dir)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return {} end
        local names = {}
        for name in iter, state do
            if name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
        return names
    end

    local function enqueue_book(book_path, metadata_file)
        if not is_book(book_path) then return end
        if utils.is_path_excluded(book_path, exclude_dirs) then return end
        table.insert(books, make_book(book_path, metadata_file))
    end

    -- Advance the walk by one directory entry. Returns "more" when it stopped
    -- early and "done" when the entry's listing is exhausted.
    local function advance(head, visit)
        if head.names == nil then
            head.names = list_dir(head.dir)
            head.index = 1
        end
        while head.index <= #head.names do
            if budget <= 0 then return "more" end
            budget = budget - 1
            local name = head.names[head.index]
            head.index = head.index + 1
            visit(name, head)
        end
        return "done"
    end

    -- ---- Mode 1: central docsettings directory ("dir") --------------------
    local function start_dir_mode()
        local DataStorage = require("datastorage")
        local docsettings_dir = DataStorage:getDocSettingsDir()
        if not docsettings_dir or lfs.attributes(docsettings_dir, "mode") ~= "directory" then
            return nil
        end

        local queue = { { dir = docsettings_dir, depth = 1 } }
        return function()
            local head = queue[1]
            local state = advance(head, function(name, h)
                local full = h.dir .. "/" .. name
                local attr = lfs.attributes(full)
                if not (attr and attr.mode == "directory") then return end
                if name:sub(-4) == ".sdr" then
                    -- Reverse-map: strip the docsettings prefix and ".sdr"
                    local rel = full:sub(#docsettings_dir + 1)
                    local book_path = rel:sub(1, -5)
                    if lfs.attributes(book_path, "mode") ~= "file" then return end
                    local ext = book_path:match("%.([^%.]+)$") or "_"
                    local metadata_file = full .. "/metadata." .. ext .. ".lua"
                    if lfs.attributes(metadata_file, "mode") == "file" then
                        enqueue_book(book_path, metadata_file)
                    end
                elseif h.depth < 20 then
                    table.insert(queue, { dir = full, depth = h.depth + 1 })
                end
            end)
            if state == "done" then table.remove(queue, 1) end
            return #queue == 0 and "done" or "more"
        end
    end

    -- ---- Mode 2: book-side ("doc") or hash ("hash") -----------------------
    local function start_book_mode()
        local root_dir
        local document = self.plugin.ui and self.plugin.ui.document
        if document and document.file then
            root_dir = document.file:match("^(.*)/[^/]+$")
        end
        if not root_dir then
            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager.instance
            -- fm.path does not exist on current KOReader. The live folder is on
            -- the file chooser, and the folder the browser was opened at is
            -- root_path. The old `fm.path` check never fired, so every run fell
            -- through to last_book_file.
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
            return nil
        end

        local queue = { { dir = root_dir, depth = 1 } }
        return function()
            local head = queue[1]
            local state = advance(head, function(name, h)
                local full = h.dir .. "/" .. name
                local attr = lfs.attributes(full)
                if not attr then return end
                if attr.mode == "file" then
                    enqueue_book(full, DocSettings:findSidecarFile(full))
                elseif attr.mode == "directory" and h.depth < 20 then
                    table.insert(queue, { dir = full, depth = h.depth + 1 })
                end
            end)
            if state == "done" then table.remove(queue, 1) end
            return #queue == 0 and "done" or "more"
        end
    end

    local function start()
        local step = (metadata_location == "dir" and start_dir_mode()) or nil
        if not step then step = start_book_mode() end
        return step
    end

    local step = start()
    if not step then
        -- Reached only when there is no open book, no file browser, and no
        -- last book on record. Saying "open the file browser" is only half
        -- right: with fm.path never resolving, standing in the browser used
        -- to land here too.
        self:showMsg(_("Open the file browser first"))
        if on_done then on_done(nil) end
        return
    end

    local in_dir_mode = (metadata_location == "dir" and true) or false

    local function slice()
        local ok, result = pcall(step)
        if not ok then
            logger.err("booksync: scan failed:", tostring(result))
            if on_done then on_done(nil) end
            return
        end
        if result == "done" then
            -- In "dir" mode a book is only counted when this device has an
            -- .sdr for it, which KOReader creates the first time a book is
            -- opened. So a library full of books that have never been opened
            -- on this device scans to zero, and used to be reported as "No
            -- books to sync" with nothing to act on.
            --
            -- The book-side walk counts on hasProvider alone and locates (or
            -- synthesises, via ensure_local_metadata) the sidecar later, so
            -- it is strictly the better answer when the first one comes back
            -- empty. Nothing is lost: the first walk only ever read the
            -- docsettings tree.
            if #books == 0 and in_dir_mode then
                local fallback = start_book_mode()
                if fallback then
                    logger.warn("booksync: docsettings scan found nothing, retrying against the book directory")
                    in_dir_mode = false
                    books = {}
                    step = fallback
                    budget = BATCH
                    UIManager:scheduleIn(0, slice)
                    return
                end
            end
            if on_done then on_done(books) end
            return
        end
        budget = BATCH
        UIManager:scheduleIn(0, slice)
    end

    budget = BATCH
    UIManager:scheduleIn(0, slice)
end

function ManualSync:batchSyncAllBooks(is_upload, is_merge, retry)
    local NetworkMgr = require("ui/network/manager")
    if not retry and NetworkMgr:willRerunWhenOnline(function()
        self:batchSyncAllBooks(is_upload, is_merge, true)
    end) then
        return
    end

    local remote = module("remote")
    local server = remote.check_preconditions_or_notify()
    if not server then
        return
    end

    -- The scan walks the tree over several ticks now (see scanAllBooks), so
    -- the result arrives in a callback rather than as a return value.
    self:scanAllBooks(function(books)
        if books == nil then
            -- scanAllBooks already showed an error message
            return
        end

        if #books == 0 then
            self:showMsg(_("No books found to sync"))
            return
        end

        local action_text
        if is_upload then
            action_text = _("upload")
        else
            action_text = is_merge and _("download-merge") or _("download-overwrite")
        end

        UIManager:show(ConfirmBox:new{
            text = string.format(_("%s metadata for %d book(s)"), action_text, #books),
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:doBatchSync(is_upload, is_merge, books)
            end
        })
    end)
end

function ManualSync:processSelectedFiles(is_upload, is_merge, selected_files)
    local DocSettings = require("docsettings")
    local ui = self.plugin.ui
    local books = {}
    
    for file, selected in pairs(selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            local metadata_file = DocSettings:findSidecarFile(file)
            
            local props = {}
            if ui and ui.bookinfo then
                props = ui.bookinfo:getDocProps(file, nil, true) or {}
            end
            local title = props.title or props.display_title
            local basename = file:match("([^/]+)$"):gsub("%.[^%.]+$", "")
            local author = props.authors
            if type(author) == "table" then
                author = author[1]
            end
            
            table.insert(books, {
                file = file,
                metadata = metadata_file,
                title = title or basename,
                book_basename = basename,
                author = author,
            })
        end
    end
    
    if #books == 0 then
        self:showMsg(_("No files selected"))
        return
    end
    
    local action_text = ""
    if is_upload then
        action_text = _("upload")
    else
        action_text = is_merge and _("download-merge") or _("download-overwrite")
    end
    
    UIManager:show(ConfirmBox:new{
        text = string.format(_("%s metadata for %d book(s)"), action_text, #books),
        ok_text = _("Continue"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:doBatchSync(is_upload, is_merge, books)
            utils.bookshelfExitSelection()
        end
    })
end

-- on_done fires when the batch actually finishes, not when it is merely
-- scheduled. auto_sync:syncAllBooksMetadata used to call this and then
-- immediately clear its is_all_syncing guard and stamp "last sync" -- but
-- runBatch returns as soon as the first item is queued, so the guard was open
-- again while the whole batch was still running, and the recorded time was
-- minutes early.
--
-- background suppresses the progress dialog. The "ALL books" triggers fire on
-- book close and on device suspend, where a modal box appears on top of a
-- screen that is being torn down or put to sleep -- the one moment the user is
-- guaranteed not to be watching, and cannot dismiss it. A manual run keeps the
-- dialog, because there the user started it and wants the feedback.
function ManualSync:doBatchSync(is_upload, is_merge, selected_books, on_done, background)
    local remote = module("remote")
    local function get_display_name(book)
        local name = book.title or book.book_basename or "Unknown"
        if type(name) ~= "string" then name = tostring(name) end
        if #name > 60 then
            name = util.fixUtf8(name:sub(1, 57), "") .. "..."
        end
        return name
    end

    utils.runBatch{
        items = selected_books,
        title = not background and (is_upload and _("Uploading metadata...")
                                    or _("Downloading metadata...")),
        describe = function(_unused, book) return get_display_name(book) end,
        step = function(_unused, book)
            -- A sidecar that does not exist yet is NOT a reason to refuse.
            -- remote.ensure_local_metadata() exists precisely to synthesise
            -- the path for a book that has never been opened, and restoring
            -- annotations onto a freshly-copied book is the whole point of this
            -- command -- yet the advice shown for it ("please open the book
            -- first") asks for the very action that is unnecessary. The old
            -- check ran before ensure_local_metadata was ever reached, so the
            -- feature could not work for a single unopened book.
            if not book.metadata or not lfs.attributes(book.metadata, "mode") then
                if not is_upload and remote.ensure_local_metadata(book) then
                    -- path now points at where the sidecar will be written
                else
                    return "no_sidecar"
                end
            end
            if is_upload then
                return remote.upload_book(book)
            end
            -- Every caller passes is_merge = true now that Overwrite is gone.
            -- Fall back to merging rather than to download_book: a false here
            -- would silently take the replace-everything path, which is the one
            -- behaviour this mode was removed to guarantee cannot happen.
            if is_merge == false then
                logger.warn("booksync: batch asked for overwrite, merging instead")
            end
            return remote.download_book_merge(book)
        end,
        classify = function(_unused, book, a, b)
            if a == "no_sidecar" then
                if is_upload then
                    -- Nothing to upload, rather than something that went wrong.
                    -- A book that has never been opened on this device has no
                    -- annotations, no progress and no bookmark, so there is
                    -- genuinely nothing to send. Reporting it as a failure
                    -- counted a book that was never in scope as one that broke,
                    -- which is how a 100-book library where 30 were never
                    -- opened came back as "70 success, 30 failed" and made the
                    -- sync look broken when it had worked correctly.
                    --
                    -- The download direction is different and stays a failure:
                    -- there, a missing sidecar really can mean the book is not
                    -- in the library, which is the advice this message gives.
                    return "skipped", {
                        title = book.title,
                        file = book.file,
                        reason = _("No local metadata to upload"),
                        solution = _("The book has not been opened on this device yet. Open it once and sync again."),
                    }
                end
                return "failed", {
                    title = book.title,
                    file = book.file,
                    reason = _("No local metadata"),
                    solution = _("The book is not in your library, or its metadata folder could not be created"),
                }
            end
            if a then
                return "success", { title = book.title, file = book.file }
            end
            local error_info = remote.get_error_message(b, is_upload)
            return "failed", {
                title = book.title,
                file = book.file,
                reason = error_info.reason,
                solution = error_info.solution,
            }
        end,
        on_done = function(results)
            self:writeBatchLog(results, is_upload, is_merge)

            local msg
            local skipped = #results.skipped
            if is_upload then
                msg = T(_("Metadata uploaded: %1 ok, %2 failed"),
                        #results.success, #results.failed)
            else
                -- The mode is gone as a user-facing choice (downloads always
                -- merge), so naming it in the summary just made the line
                -- longer. Counts are what the user is looking for.
                msg = T(_("Metadata downloaded: %1 ok, %2 failed"),
                        #results.success, #results.failed)
            end
            -- Only mention it when it happened, and say it is not a failure:
            -- a "0 failed" line that silently hid 30 books reads like the
            -- plugin lost them.
            if skipped > 0 then
                msg = msg .. T(_(" (%1 skipped)"), skipped)
            end

            -- A batch that lost books must not read like a clean run: the
            -- failure count is the whole point of the line, so the level
            -- follows it and the icon says so before the numbers are read.
            if #results.failed > 0 then
                notify.error(msg)
            else
                notify.success(msg)
            end

            local sync_type
            if is_upload then
                sync_type = _("Metadata sync") .. "-" .. _("Batch upload") .. "-" .. _("Overwrite cloud")
            else
                sync_type = _("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Merge")
            end
            self:updateLastSync(sync_type)

            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager.instance
            utils.undimFileRows()
            utils.bookshelfExitSelection()

            if on_done then pcall(on_done, results) end
        end,
    }
end

function ManualSync:writeSingleLog(book, is_upload, is_merge, success, error_reason)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id(false)
    
    local operation_type = ""
    if is_upload then
        operation_type = _("Metadata sync") .. "-" .. _("Single upload") .. "-" .. _("Overwrite cloud")
    else
        operation_type = _("Metadata sync") .. "-" .. _("Single download") .. "-" .. _("Merge")
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
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
end

function ManualSync:writeBatchLog(results, is_upload, is_merge)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_path = utils.get_log_path()
    
    local device_name = utils.get_device_name()
    local device_id = utils.get_device_id(false)
    
    local operation_type = ""
    if is_upload then
        operation_type = _("Metadata sync") .. "-" .. _("Batch upload") .. "-" .. _("Overwrite cloud")
    else
        operation_type = _("Metadata sync") .. "-" .. _("Batch download") .. "-" .. _("Merge")
    end
    
    local failed_by_reason = {}
    for _, book in ipairs(results.failed) do
        local key = book.reason
        if not failed_by_reason[key] then
            failed_by_reason[key] = {
                solution = book.solution,
                books = {}
            }
        end
        table.insert(failed_by_reason[key].books, {
            title = book.title,
            file = book.file
        })
    end
    
    local new_record = {}
    table.insert(new_record, utils.SEPARATOR_LINE)
    table.insert(new_record, string.format(_("Sync time: %s"), timestamp))
    table.insert(new_record, string.format(_("Device: %s"), device_name))
    table.insert(new_record, string.format(_("Device ID: %s"), device_id))
    table.insert(new_record, string.format(_("Operation type: %s"), operation_type))
    table.insert(new_record, utils.SEPARATOR_LINE)
    
    table.insert(new_record, string.format(_("[Success] (%d books)"), #results.success))
    table.insert(new_record, string.rep("-", 40))
    if #results.success > 0 then
        for _, book in ipairs(results.success) do
            table.insert(new_record, string.format("  ✓ %s", book.title))
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    
    if #results.skipped > 0 then
        table.insert(new_record, string.format(_("[Skipped] (%d books)"), #results.skipped))
        table.insert(new_record, string.rep("-", 40))
        table.insert(new_record, _("  No local metadata to upload (book never opened on this device)"))
        for _sk, bk in ipairs(results.skipped) do
            table.insert(new_record, string.format("  · %s", bk.title))
        end
        table.insert(new_record, "")
    end

    table.insert(new_record, string.format(_("[Failed] (%d books)"), #results.failed))
    table.insert(new_record, string.rep("-", 40))
    if #results.failed > 0 then
        local reason_index = 0
        for reason, info in pairs(failed_by_reason) do
            reason_index = reason_index + 1
            table.insert(new_record, string.format("\n" .. _("[Failure reason %d] %s"), reason_index, reason))
            table.insert(new_record, string.rep("~", 40))
            table.insert(new_record, string.format(_("Solution: %s"), info.solution or _("Please check network and configuration")))
            table.insert(new_record, "")
            table.insert(new_record, _("Failed books:"))
            for i, book in ipairs(info.books) do
                table.insert(new_record, string.format("  (%d) %s", i, book.title))
            end
        end
    else
        table.insert(new_record, _("  None"))
    end
    table.insert(new_record, "")
    table.insert(new_record, "")
    
    local content = table.concat(new_record, "\n") .. "\n"
    
    utils.write_log(log_path, content)
    
end

-- Every call site of this is a blocking precondition: no book open, no
-- network, cloud not configured, nothing selected. The plugin did not fail at
-- anything -- the user has to act first -- so these land on the hint level
-- rather than reading as an error. Kept as a method because 23 call sites
-- already say self:showMsg(...).
function ManualSync:showMsg(msg, level)
    notify[level or "hint"](msg)
end

function ManualSync:updateLastSync(descriptor)
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. " (" .. descriptor .. ")"
    G_reader_settings:saveSetting(self.plugin.plugin_id, self.settings)
end

return ManualSync
