-- notify.lua — BookSync
--
-- One entry point for every user-visible message in the plugin.
--
-- Before this file the plugin had five parallel notification paths:
--
--   * UIManager:show(Notification:new{...}) inlined at 41 call sites
--   * ManualSync:showMsg  -> InfoMessage, timeout 3
--   * book_sync.show_notification -> Notification, timeout or 2
--   * AutoSync:showNotification  -> Notification, timeout 2
--   * utils.show_msg             -> InfoMessage, timeout 3
--
-- with timeouts picked per call site from {0, 2, 3, 4, 5} on instinct. Two
-- things went wrong with that: the same message read at two different speeds
-- depending on which file raised it, and the icon was baked into the msgid
-- ("✓ Upload successful"), so it was a translatable string that translators
-- could and did drop.
--
-- The rules now, in one place:
--
--   level  -> icon + timeout, decided here and nowhere else
--   icon   -> prepended at render time, never part of the msgid
--   dedup  -> identical text within DEDUP_WINDOW is shown once
--   sticky -> progress() takes over the single sticky slot; any terminal
--             level (success/error/info/hint) closes it automatically, so an
--             operation that ends by *not* reaching its own cleanup -- an
--             early return, a raised error -- can no longer leave a
--             "Downloading..." toast parked on screen forever.

local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local M = {}

-- Level presets. Order matters only for readability.
local LEVEL = {
    success = { icon = "✓", timeout = 2 },
    error   = { icon = "✗", timeout = 4 },
    info    = { icon = nil, timeout = 3 },
    hint    = { icon = nil, timeout = 4 },
    progress = { icon = nil, timeout = 0 },
}

-- Identical text inside this window collapses into one notification. Auto sync
-- runs from hooks and from a retry queue, so the same failure can be raised
-- several times inside a couple of seconds; stacking three identical toasts
-- reads as three separate problems.
local DEDUP_WINDOW = 1.5
local last_shown = {}   -- [level .. "\0" .. text] = UIManager time

local sticky = nil      -- the widget currently holding the sticky slot

-- ui/uimanager exposes :timeInEpoch(); older builds only have getTime().
local function now()
    if UIManager.timeInEpoch then
        local ok, t = pcall(UIManager.timeInEpoch, UIManager)
        if ok and type(t) == "number" then return t end
    end
    if UIManager.getTime then
        local ok, t = pcall(UIManager.getTime)
        if ok and type(t) == "number" then return t end
    end
    return os.time()
end

-- Close whatever holds the sticky slot. Safe to call when it is empty, and
-- safe to call twice.
local function closeSticky()
    if not sticky then return end
    local widget = sticky
    sticky = nil
    pcall(function() UIManager:close(widget) end)
end

M.closeSticky = closeSticky

-- Terminal levels retire the sticky slot. This is the safety net: callers
-- should still call closeSticky() when they finish cleanly, but a path that
-- dies first can no longer strand a permanent "Downloading..." on screen.
local function show(level, text, opts)
    opts = opts or {}

    if type(text) ~= "string" or text == "" then return nil end
    if opts.dedup == false then
        -- explicit opt-out still allowed below
    else
        local key = level .. "\0" .. text
        local t = now()
        local prev = last_shown[key]
        if prev and (t - prev) < DEDUP_WINDOW then return nil end
        last_shown[key] = t
    end

    -- Anything terminal means the operation is over.
    if level ~= "progress" then closeSticky() end

    local preset = LEVEL[level] or LEVEL.info
    local display = text
    if opts.icon ~= nil then
        display = (opts.icon == "" and "" or (opts.icon .. " ")) .. text
    elseif preset.icon then
        display = preset.icon .. " " .. text
    end

    local n = Notification:new{
        text = display,
        timeout = opts.timeout or preset.timeout,
    }

    if level == "progress" then
        closeSticky()
        sticky = n
    end

    UIManager:show(n)
    return n
end

-- ── public API ──────────────────────────────────────────────────────────────

function M.success(text, opts) return show("success", text, opts) end
function M.error(text, opts)   return show("error",   text, opts) end
function M.info(text, opts)    return show("info",    text, opts) end

-- Actionable guidance the user is expected to act on ("select books first",
-- "set the download directory"). Reads longer than a status line.
function M.hint(text, opts)    return show("hint",    text, opts) end

-- Sticky, occupies the single sticky slot until a terminal level arrives or
-- closeSticky() is called. Returns the widget if the caller wants to close it
-- itself.
function M.progress(text, opts) return show("progress", text, opts) end

-- Progress message that may be called repeatedly for a multi-step job; the
-- slot is reused so long steps do not leave a stack of toasts behind.
function M.progressStep(text, opts)
    opts = opts or {}
    opts.dedup = false
    return show("progress", text, opts)
end

-- Compose a prefixed line the way AutoSync does: "<title> - <operation>" with
-- an optional trailing mode. Kept here so the separator convention is in one
-- place.
-- Join the parts of a "<title> - <operation> - <mode>" line. Any part may be
-- nil or empty, in which case it is simply left out -- tostring(nil) would put
-- a literal "nil" on the screen, which is what a caller passing no title (a
-- message that is not about one book) used to get.
function M.compose(title, operation, mode)
    local parts = {}
    for _, part in ipairs({ title, operation, mode }) do
        if type(part) == "string" then
            part = part:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if part and part ~= "" then
            parts[#parts + 1] = tostring(part)
        end
    end
    return table.concat(parts, " - ")
end

return M
