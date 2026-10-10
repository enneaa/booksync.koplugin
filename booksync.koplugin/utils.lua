-- Get plugin directory (utils.lua is loaded via dofile, so it has to work the
-- directory out for itself just like every other module here).
local src = debug.getinfo(1, "S").source or ""
local path = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/[^/]+$") or nil
local _plugin_dir

if path then
    if path:sub(1, 1) ~= "/" then
        local ok, lfs_dir = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok and lfs_dir and lfs_dir.currentdir()
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

local reader_order = require("ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local logger = require("logger")
local _ = module("gettext_shim")
local notify = module("notify")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local Screen = Device.screen

local M = {}


function M.insert_after_statistics(key)
    local pos = 1
    if reader_order and reader_order.tools then
        for index, value in ipairs(reader_order.tools) do
            if value == "statistics" then
                pos = index + 1
                break
            end
        end
        -- reader_order is a core module singleton and init() calls this on
        -- every single menu entry, so without the guard the gear menu grew one
        -- more BookSync row per visit.
        for _, existing in ipairs(reader_order.tools) do
            if existing == key then return end
        end
        table.insert(reader_order.tools, pos, key)
    end
end

function M.isPossiblyJson(content)
    return content:sub(1, #"{") == "{"
end

-- Settings acknowledgements ("Download mode: Merge", "Excluded directory
-- added: ...") -- the action worked and the user just wants confirmation, so
-- info level. Kept as a function because callers already say utils.show_msg.
function M.show_msg(msg, level)
    notify[type(level) == "string" and level or "info"](msg)
end

function M.get_device_name()
    local model = Device.model or "Unknown"
    
    local friendly_names = {
        KindleVoyage = "Kindle Voyage",
        KindlePaperWhite = "Kindle PaperWhite",
        KindlePaperWhite2 = "Kindle PaperWhite 2",
        KindlePaperWhite3 = "Kindle PaperWhite 3",
        KindlePaperWhite4 = "Kindle PaperWhite 4",
        KindlePaperWhite5 = "Kindle PaperWhite 5",
        KindleBasic = "Kindle Basic",
        KindleBasic2 = "Kindle Basic 2",
        KindleBasic3 = "Kindle Basic 3",
        KindleOasis = "Kindle Oasis",
        KindleOasis2 = "Kindle Oasis 2",
        KindleOasis3 = "Kindle Oasis 3",
        Kindle = "Kindle",
        KoboAuraH2O = "Kobo Aura H2O",
        KoboAura = "Kobo Aura",
        KoboAuraOne = "Kobo Aura One",
        KoboGlo = "Kobo Glo",
        KoboGloHD = "Kobo Glo HD",
        KoboClara = "Kobo Clara",
        KoboClaraHD = "Kobo Clara HD",
        KoboForma = "Kobo Forma",
        KoboLibra = "Kobo Libra",
        KoboLibra2 = "Kobo Libra 2",
        KoboSage = "Kobo Sage",
        KoboElipsa = "Kobo Elipsa",
        PocketBook = "PocketBook",
        PocketBookBasic = "PocketBook Basic",
        PocketBookTouch = "PocketBook Touch",
        PocketBookHD = "PocketBook HD",
        Android = "Android Device",
        Remarkable = "reMarkable",
        Likebook = "Likebook",
        Boox = "Boox",
    }
    
    return friendly_names[model] or model
end

-- persist=false is for call sites that only need something to print. Every
-- call site here is inside a log write, and a log write must not mutate
-- settings: this runs on the close and suspend paths, where a saveSetting
-- re-encodes the whole settings tree and writes it to disk, and the id is then
-- fixed forever, so entries logged before the first write could never match it.
function M.get_device_id(persist)
    local id = G_reader_settings:readSetting("booksync_device_id")
    if not id then
        math.randomseed(os.time())
        id = string.format("%08x", math.random(0xffffffff))
        if persist ~= false then
            G_reader_settings:saveSetting("booksync_device_id", id)
        end
    end
    return id
end

-- The log is newest-first, so the cap keeps the HEAD of the merged text and
-- cuts on a line boundary. Without it the file grew forever AND every write
-- re-read and rewrote all of it, so a device that syncs often ended up
-- handling a multi-megabyte string per entry -- and the "View Sync Log" menu
-- item then handed that whole thing to a TextViewer.
--
-- 128 KB, down from 512. The log is written once per book open, and every
-- write is a full read + concat + cap + write, so the cap sets the cost of
-- opening a book: measured at 0.2 ms per write with a 64 KB log against 2.0 ms
-- at 512 KB, on a machine far faster than a Kindle. 128 KB still holds well
-- over a thousand entries, which is more than anyone scrolls through.
local LOG_MAX_BYTES = 128 * 1024

local function cap_log(text)
    if #text <= LOG_MAX_BYTES then return text end
    local kept = text:sub(1, LOG_MAX_BYTES)
    local nl = kept:match(".*()\n")   -- cut back to the last complete line
    if nl then kept = kept:sub(1, nl - 1) end
    return kept .. "\n[... older records trimmed ...]\n"
end

function M.write_log(log_path, content)
    if not log_path or not content then
        return false
    end
    
    local dir = log_path:match("(.*)/")
    if dir and dir ~= "" then
        M.mkdir_p(dir)
    end
    
    local old_content = ""
    local f = io.open(log_path, "r")
    if f then
        old_content = f:read("*all") or ""
        f:close()
    end
    
    local new_content = content
    if old_content ~= "" then
        new_content = content .. old_content
    end
    
    local out_f = io.open(log_path, "w")
    if out_f then
        out_f:write(cap_log(new_content))
        out_f:close()
        return true
    end
    return false
end

-- One stat(2) per path, returning mode and size.
--
-- The download paths asked lfs.attributes for "mode", then for "size", then
-- again for a whole-table fallback -- three syscalls for one file, on a code
-- path that runs once per book in a batch. Three hundred books is nine hundred
-- stats where three hundred would do, and it shows up as a stalled progress
-- dialog rather than as anything the user can name.
--
-- Returns mode, size. mode is nil when the path does not exist.
function M.stat_file(path)
    if not path or path == "" then
        return nil, 0
    end
    local a = lfs.attributes(path)
    if a == nil then
        return nil, 0
    end
    if type(a) == "table" then
        return a.mode, tonumber(a.size) or 0
    end
    -- Some lfs builds answer the no-field form with the value itself; fall
    -- back to per-attribute queries rather than reporting a missing file.
    return lfs.attributes(path, "mode"), tonumber(lfs.attributes(path, "size")) or 0
end

function M.get_log_path()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/booksync_sync_log.txt"
end

-- Recursively create a directory (like mkdir -p) using lfs only, no shell.
-- KOReader already ships this: frontend/util.makePath creates every missing
-- component and returns whether the directory exists afterwards. It was
-- reimplemented here for no gain.
function M.mkdir_p(dir)
    if not dir or dir == "" then
        return false
    end
    local ok, koutil = pcall(require, "frontend/util")
    if ok and koutil and type(koutil.makePath) == "function" then
        return koutil.makePath(dir) == true
    end
    -- Only reached if frontend/util is unavailable, which should not happen
    -- inside KOReader; the tests exercise this path.
    if lfs.attributes(dir, "mode") == "directory" then
        return true
    end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= dir then
        if not M.mkdir_p(parent) then
            return false
        end
    end
    local ok_mk = pcall(lfs.mkdir, dir)
    return ok_mk and lfs.attributes(dir, "mode") == "directory"
end

M.SEPARATOR_LINE = string.rep("=", 30)

-- ============================================================
-- DownloadDialog - Progress dialog with cancel button
-- ============================================================

-- Non-touch Kindles paint slowly: one bar update a second is enough there.
local slow_paint = Device:isKindle() and not Device:isTouchDevice()

local DownloadDialog = InputContainer:extend{
    title = "",
    description = nil,
    progress_max = 100,
    buttons = nil,
    refresh_time_seconds = slow_paint and 1 or 0.1,
}

function DownloadDialog:init()
    self.dimen = Screen:getSize()
    self.last_redraw_time = 0

    local width = Screen:getWidth() - Screen:scaleBySize(80)

    local vertical_group = VerticalGroup:new{}

    self.title_widget = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.title_container = CenterContainer:new{
        dimen = Geom:new{
            w = width,
            h = self.title_widget:getSize().h,
        },
        self.title_widget,
    }
    table.insert(vertical_group, self.title_container)

    if self.description and self.description ~= "" then
        self.description_widget = TextWidget:new{
            text = self.description,
            face = Font:getFace("xx_smallinfofont"),
            max_width = width,
        }
        self.description_container = CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = self.description_widget:getSize().h,
            },
            self.description_widget,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vertical_group, self.description_container)
    end

    if self.progress_max and self.progress_max > 0 then
        self.progress_bar = ProgressWidget:new{
            fillcolor = Blitbuffer.COLOR_BLACK,
            width = width,
            height = Screen:scaleBySize(18),
            padding = Size.padding.large,
            margin = Size.margin.tiny,
            percentage = 0,
        }
        table.insert(vertical_group, self.progress_bar)
    end

    if self.buttons then
        local button_table = ButtonTable:new{
            width = width,
            buttons = self.buttons,
            zero_sep = true,
            show_parent = self,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(vertical_group, button_table)
    end

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            padding_bottom = self.buttons and 0 or nil,
            background = Blitbuffer.COLOR_WHITE,
            vertical_group,
        },
    }
end

function DownloadDialog:reportProgress(progress)
    if not self.progress_bar then return end
    self.progress_bar:setPercentage(progress / self.progress_max)
    -- time.now() is an fts value measured in *seconds*. The old code compared
    -- the delta against refresh_time_seconds * 1000 * 1000, i.e. a threshold of
    -- 100000 seconds, so after the very first callback the dialog never
    -- repainted again -- a large download would sit at 0% until it finished.
    local now = time.now()
    local elapsed = now - self.last_redraw_time
    if self.progress_bar.percentage >= 1 or elapsed >= self.refresh_time_seconds then
        self.last_redraw_time = now
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setTitle(title)
    self.title = title or ""
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.title)
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setDescription(desc)
    self.description = desc or ""
    if self.description_widget and self.description_widget.setText then
        self.description_widget:setText(self.description)
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:show()
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    UIManager:close(self, "ui")
end

M.DownloadDialog = DownloadDialog

-- ============================================================
-- 检查文件路径是否在排除目录中
-- ============================================================
function M.is_path_excluded(file_path, exclude_dirs)
    if not file_path or not exclude_dirs or #exclude_dirs == 0 then
        return false
    end
    
    local function normalize_path(path)
        path = path:gsub("\\", "/")  
        path = path:gsub("/+$", "")   
        return path
    end
    
    local normalized_file = normalize_path(file_path)
    
    for _, exclude_dir in ipairs(exclude_dirs) do
        local normalized_exclude = normalize_path(exclude_dir)
        if normalized_file:find(normalized_exclude, 1, true) == 1 then
            local next_char = normalized_file:sub(#normalized_exclude + 1, #normalized_exclude + 1)
            if next_char == "/" or next_char == "" then
                return true
            end
        end
    end
    
    return false
end

-- ============================================================
-- Bookshelf integration: automatically enter selection mode and retrieve selected file list for batch operations
-- ============================================================
--
-- The previous implementation hunted the UIManager window stack for an entry
-- with widget.name == "bookshelf" and then drove widget._selection:isActive()
-- / widget:_rebuild(). None of that exists in KOReader: FileManager has no
-- `name` field, no `_selection` and no `_rebuild`. The moment such a widget was
-- found, the first call raised
--   "attempt to index a nil value (field '_selection')"
-- These helpers now use the real FileManager API (selected_files +
-- onToggleSelectMode) and no-op when the FileManager is not on screen.

local function get_file_manager()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then return nil end
    local fm = FileManager.instance
    if not fm or not UIManager:isWidgetShown(fm) then return nil end
    return fm
end


function M.isBookshelfShowing()
    return get_file_manager() ~= nil
end

function M.bookshelfEnterSelection()
    local fm = get_file_manager()
    if not fm then
        return false
    end
    if not fm.selected_files then
        fm:onToggleSelectMode(true)
    end
    return true
end

-- Leave selection mode, but only when we are actually in it.
--
-- FileManager:onToggleSelectMode is a pure toggle:
--
--     if self.selected_files then
--         self.selected_files = nil            -- leave
--     else
--         self.selected_files = {}             -- ENTER
--     end
--
-- Calling it unconditionally to "clean up" after a batch therefore *enters*
-- selection mode whenever the state changed in the meantime -- the user starts
-- a batch, leaves selection mode while it runs, and comes back to a file
-- browser that has silently switched itself into selection mode with nothing
-- selected and no idea why.
--
-- Deliberately not restricted to the on-screen FileManager: an instance left
-- in selection mode while hidden comes back that way when it is shown again,
-- which is the same symptom by another route.
function M.bookshelfExitSelection()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then
        return false
    end
    local fm = FileManager.instance
    if not fm or not fm.selected_files then
        return false
    end
    return fm:onToggleSelectMode(true)
end

-- Undo the dimming that selection mode applies to file rows.
--
-- KOReader undims as part of leaving selection mode: onToggleSelectMode(true)
-- ends in file_chooser:refreshPath(). Calling updateItems(1, true) first as
-- well rebuilt the same directory twice, and on a Kindle with a few hundred
-- entries that is the difference between a visible pause and a frozen UI.
function M.undimFileRows()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then return end
    local fm = FileManager.instance
    local chooser = fm and fm.file_chooser
    if not chooser or not chooser.item_table then return end
    for _, item in ipairs(chooser.item_table) do
        if item.is_file then
            item.dim = nil
        end
    end
end

function M.bookshelfGetSelectedFiles()
    local fm = get_file_manager()
    if not fm or not fm.selected_files then
        return {}
    end

    local files = {}
    for file, selected in pairs(fm.selected_files) do
        if selected and lfs.attributes(file, "mode") == "file" then
            files[#files + 1] = file
        end
    end
    return files
end



-- Remember the most recently opened book.
--
-- The "current book" actions fall back to this when nothing is open (e.g. from
-- the FileManager). Kept here so the startup hook in main.lua and the auto-sync
-- hook in hooks.lua cannot drift apart.
function M.remember_last_book(file)
    if type(file) ~= "string" or file == "" then return false end
    local settings = G_reader_settings:readSetting("booksync_plugin")
    if type(settings) ~= "table" then return false end
    if settings.last_book_file == file then return false end
    settings.last_book_file = file
    G_reader_settings:saveSetting("booksync_plugin", settings)
    return true
end

-- ============================================================
-- Crash traceback capture
-- ============================================================
--
-- This plugin contains every cloud operation in a pcall, which is the right
-- call for a reader app -- a failed sync must never take the book away. But it
-- has a cost: KOReader's own crash handler never sees anything, so a real crash
-- leaves a one-line "attempt to ..." with no stack, and a native crash leaves
-- nothing at all.
--
-- So: write the full Lua traceback to the plugin's own log, which the user can
-- actually open from the menu ("View Sync Log"). Must never raise -- it is
-- called from inside error handlers.
function M.log_crash(label, err)
    pcall(function()
        logger.err("booksync: " .. tostring(label) .. ": " .. tostring(err))
        local trace = debug.traceback(tostring(err), 3)
        local path = M.get_log_path()
        if not path then return end
        local f = io.open(path, "a")
        if not f then return end
        f:write("\n[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] CRASH in " .. tostring(label) .. "\n")
        f:write(trace .. "\n")
        f:close()
    end)
end

-- ============================================================
-- Safe scheduling
-- ============================================================
--
-- UIManager:nextTick / scheduleIn invoke their callback with no error boundary,
-- so anything scheduled from a menu callback can take the app down. These two
-- wrappers keep the scheduling call sites short while guaranteeing that a
-- failure is logged instead of fatal.
-- ============================================================
-- Temporary file reaper
-- ============================================================
-- Every interrupted transfer can leave something behind: a book download
-- writes "<name>.part" until it is verified, a conflict merge writes
-- "<name>.conflict", a metadata download stages into the plugin's data dir.
-- Success paths clean up after themselves, failure paths do not, and none of
-- that ever aged out -- so a device with a flaky connection accumulates dead
-- bytes that the user has no way to see or remove.
--
-- Only files whose names match our own patterns are touched, only after a day
-- old, and at most once an hour.
local TEMP_MAX_AGE = 24 * 60 * 60
local last_reap = nil
local TEMP_PATTERNS = {
    "%.part$", "%.conflict$", "%.tmp$", "^cloud_log%.tmp$",
}

local function is_temp_file(name)
    for _, pattern in ipairs(TEMP_PATTERNS) do
        if name:match(pattern) then return true end
    end
    return false
end

function M.reap_temp_files(dirs, force)
    if not force then
        local now = os.time()
        if last_reap and (now - last_reap) < 3600 then return 0 end
        last_reap = now
    end
    local removed = 0
    local now = os.time()
    for _, dir in ipairs(dirs or {}) do
        if type(dir) == "string" and dir ~= "" and lfs.attributes(dir, "mode") == "directory" then
            local ok, iter = pcall(function() return lfs.dir(dir) end)
            if ok and iter then
                pcall(function()
                    for name in iter do
                        if is_temp_file(name) then
                            local path = dir .. "/" .. name
                            local attr = lfs.attributes(path)
                            if attr and type(attr) == "table" and attr.modification
                                and (now - attr.modification) > TEMP_MAX_AGE then
                                if os.remove(path) then removed = removed + 1 end
                            end
                        end
                    end
                end)
            end
        end
    end
    if removed > 0 then
        logger.info("booksync: removed " .. removed .. " stale temporary file(s)")
    end
    return removed
end

-- The directories this plugin can leave temporaries in.
function M.temp_dirs()
    local dirs = {}
    pcall(function()
        local DataStorage = require("datastorage")
        local base = DataStorage:getDataDir()
        if type(base) == "string" and base ~= "" then
            table.insert(dirs, base .. "/metadatasync")
            table.insert(dirs, base)
        end
    end)
    pcall(function()
        local settings = G_reader_settings:readSetting("booksync_plugin")
        if type(settings) == "table" and type(settings.book_download_dir) == "string"
            and settings.book_download_dir ~= "" then
            table.insert(dirs, settings.book_download_dir)
        end
    end)
    return dirs
end

function M.nextTickSafe(label, fn)
    -- pcall the SCHEDULING call too: the old version only protected the task
    -- body, so a raise in UIManager:nextTick itself escaped -- which is exactly
    -- the "safe" wrapper being the thing that crashed the app.
    local queued, qerr = pcall(function()
        UIManager:nextTick(function()
            local ok, err = pcall(fn)
            if not ok then
                M.log_crash(tostring(label), err)
            end
        end)
    end)
    if not queued then
        M.log_crash("nextTickSafe:" .. tostring(label), qerr)
    end
    return queued
end

function M.scheduleSafe(label, delay, fn)
    local queued, qerr = pcall(function()
        UIManager:scheduleIn(delay, function()
            local ok, err = pcall(fn)
            if not ok then
                M.log_crash(tostring(label), err)
            end
        end)
    end)
    if not queued then
        M.log_crash("scheduleSafe:" .. tostring(label), qerr)
    end
    return queued
end

-- ============================================================
-- Batch runner
-- ============================================================
--
-- Every batch operation in this plugin (upload books, download books, delete
-- books, batch metadata sync) used to be hand-rolled as the same four-step
-- recursion:
--
--     UIManager:scheduleIn(0, function()
--         <do one cloud call, no pcall>
--         index = index + 1
--         UIManager:scheduleIn(0, next)
--     end)
--
-- which fails in two ways that both look like "the device froze":
--   * an error escaping the step body propagates into UIManager's task loop and
--     kills the app -- and because the step never ran `index = index + 1`, the
--     chain would have stalled anyway;
--   * the progress dialog is a modal InputContainer. If the chain dies, nobody
--     closes it, so a dead progress box is left on top of the UI.
--
-- runBatch fixes both structurally: each step is error-contained, the index
-- always advances, the dialog is always closed, and on_done always fires.
--
-- opts.items        array of items
-- opts.title        dialog title
-- opts.description  initial description
-- opts.progress_max number of progress units (defaults to #items)
-- opts.describe     function(i, item) -> string shown in the dialog
-- opts.step         function(i, item, report) -> anything; throw to record a
--                    failure and continue
-- opts.classify     function(i, item, ...results) -> "success"|"skipped"|nil,
--                    plus optional payload (name, reason, ...)
-- opts.on_done      function(summary) -- always called, even after an error
-- opts.on_error     function(err, i, item) -- optional
function M.runBatch(opts)
    local items = opts.items or {}
    local total = #items
    local progress_max = opts.progress_max or total
    local index = 1
    local completed = 0

    local summary = { success = {}, failed = {}, skipped = {}, total = total }
    local dialog
    local cancelled = false

    -- Nothing to do: bail out before building a dialog, otherwise an empty
    -- batch flashes a progress box on screen and immediately closes it.
    if total == 0 then
        if opts.on_done then
            pcall(opts.on_done, summary)
        end
        return summary
    end

    if opts.title and opts.progress_max ~= false then
        local ok_dialog, d = pcall(function()
            return DownloadDialog:new{
                title = opts.title,
                description = opts.description or " ",
                progress_max = progress_max,
                -- The dialog is modal and was built with no buttons at all, so
                -- there was no way to dismiss it. That is survivable for a
                -- short manual run and a trap for an automatic one: a batch
                -- triggered on book close or on device suspend raises the same
                -- box, and if the socket is slow the user is left staring at a
                -- progress display they cannot get rid of while the device is
                -- trying to sleep.
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "cancel",
                            callback = function()
                                cancelled = true
                                if dialog then pcall(function() dialog:close() end) end
                                dialog = nil
                            end,
                        },
                    },
                },
            }
        end)
        if ok_dialog and d then
            dialog = d
            pcall(function() dialog:show() end)
        end
    end

    local function finish()
        if dialog then
            pcall(function() dialog:close() end)
            dialog = nil
        end
        if opts.on_done then
            pcall(opts.on_done, summary)
        end
    end

    -- Every UIManager:setDirty on Android posts a callback onto the render
    -- thread. A 300-book metadata sync that repainted per item queued ~600
    -- native round trips, which is a wide window for the known KOReader
    -- Android teardown race (FORTIFY: pthread_mutex_lock called on a destroyed
    -- mutex, koreader#12010 / #10998) to land in. Throttle the batch's own
    -- repaints; DownloadDialog:reportProgress throttles the byte counter.
    local last_batch_paint = 0
    local function paint_batch()
        local now = time.now()
        if now - last_batch_paint < 0.25 then return end
        last_batch_paint = now
        if dialog then
            pcall(function() UIManager:setDirty(dialog, "ui") end)
        end
    end

    local function run_next()
        if cancelled then
            if dialog then pcall(function() dialog:close() end) end
            dialog = nil
            -- Mark the untouched remainder so the summary the user sees is
            -- honest about what actually ran.
            for i = index, total do
                local it = items[i]
                table.insert(summary.skipped, {
                    name = tostring((it and (it.name or it.title or it.file)) or ("#" .. i)),
                    reason = "cancelled",
                })
            end
            if opts.on_done then
                pcall(opts.on_done, summary)
            end
            return
        end
        if index > total then
            finish()
            return
        end

        local i = index
        local item = items[i]

        if dialog and opts.describe then
            pcall(function()
                dialog:setDescription(string.format("%d/%d: %s", i, total, tostring(opts.describe(i, item))))
            end)
            paint_batch()
        end

        -- One tick per item keeps the UI responsive and lets the dialog paint
        -- between books. The blocking network call itself is synchronous
        -- (KOReader's socket layer is), but doing it here rather than inside the
        -- originating event callback means the dialog is already on screen and
        -- its progress redraws actually get a chance to run.
        UIManager:scheduleIn(0, function()
            -- `report` is ABSOLUTE progress in whatever unit opts.progress_max
            -- uses (bytes for the book batch, items for the metadata batch).
            -- It used to ADD to the counter, and the counter was also advanced
            -- by one per item below -- so a step that reported bytes had them
            -- added on top of the item count. And no caller reported at all:
            -- every step was declared function(_, item), so a dialog configured
            -- with progress_max = total_bytes rendered completed / total_bytes
            -- for the entire run, i.e. a bar frozen near 0%.
            local reported = false
            local ok, a, b, c = pcall(opts.step, i, item, function(units)
                units = tonumber(units)
                if not units then return end
                reported = true
                completed = units
                if dialog then pcall(function() dialog:reportProgress(units) end) end
            end)

            if not ok then
                M.log_crash("batch step " .. tostring(i), a)
                if opts.on_error then
                    pcall(opts.on_error, a, i, item)
                end
                local label = item and (item.name or item.title or item.file)
                table.insert(summary.failed, {
                    name = tostring(label or ("#" .. i)),
                    reason = tostring(a),
                })
            elseif opts.classify then
                -- Every other callback here is pcall'd; this one was not. A
                -- raise here propagated into UIManager:_checkTasks(), which
                -- has no boundary of its own -- so it took the app down AND
                -- skipped index = i + 1 and finish(), leaving the modal
                -- progress dialog stuck on screen.
                local ok_c, verdict, payload = pcall(opts.classify, i, item, a, b, c)
                if not ok_c then
                    -- pcall puts the error in the first return slot.
                    logger.err("booksync: batch classify failed:", tostring(verdict))
                    table.insert(summary.failed, {
                        name = tostring((item and (item.name or item.title or item.file)) or ("#" .. i)),
                        reason = tostring(verdict),
                    })
                    verdict = nil
                end
                if verdict == "success" or verdict == "skipped" then
                    table.insert(summary[verdict], payload or { name = tostring(item) })
                elseif verdict then
                    table.insert(summary.failed, payload or { name = tostring(item) })
                end
            end

            if not reported then
                -- Item-count mode (the default): advance by one.
                completed = completed + 1
                if dialog then
                    pcall(function() dialog:reportProgress(completed) end)
                end
            end
            paint_batch()

            -- Always advance, whatever happened above.
            index = i + 1
            UIManager:scheduleIn(0, run_next)
        end)
    end

    run_next()
    return summary
end

return M