-- sortstate.lua — BookSync
--
-- The cloud book list's sort order, persisted.
--
-- This was a plain local in book_sync.lua, so the list always opened sorted
-- by name: pick "Size descending" once, close the dialog, come back, and the
-- choice is gone. On a cloud library with a few hundred books that is the kind
-- of small friction you stop noticing you are paying every single visit.
--
-- It lives in its own module rather than inline in book_sync.lua for two
-- reasons: book_sync.lua is a 2000-line module that needs a live UIManager and
-- a cloud connection just to be loaded, so a test cannot touch it; and the
-- state has an identity of its own -- it is a preference, not a side effect of
-- drawing the list.
--
-- The stored value is a number in 1..6, matching the order of the sort labels
-- in book_sync.lua. Anything else -- absent, nil, a string from a hand-edited
-- settings.reader.lua, out of range -- resolves to the default rather than
-- producing an empty sort label or a comparison that never matches.

local M = {}

local PLUGIN_KEY = "booksync_plugin"
local FIELD = "cloud_book_sort_mode"
local MODE_COUNT = 6

-- Set when the settings table could not be read or written (a corrupted
-- settings file, a read-only filesystem). The caller carries on with the
-- default rather than failing; a list that sorts the wrong way is a much
-- smaller problem than a list that will not open.
M.last_error = nil

-- Current sort mode, or the default.
function M.get()
    M.last_error = nil
    local ok, settings = pcall(function()
        return G_reader_settings:readSetting(PLUGIN_KEY)
    end)
    if not ok or type(settings) ~= "table" then
        M.last_error = "read failed"
        return 1
    end
    local mode = tonumber(settings[FIELD])
    if not mode or mode < 1 or mode > MODE_COUNT or mode % 1 ~= 0 then
        return 1
    end
    return mode
end

-- Store `mode`. Returns true when it was persisted.
function M.set(mode)
    M.last_error = nil
    mode = tonumber(mode)
    if not mode or mode < 1 or mode > MODE_COUNT or mode % 1 ~= 0 then
        mode = 1
    end
    local ok, settings = pcall(function()
        return G_reader_settings:readSetting(PLUGIN_KEY)
    end)
    if not ok or type(settings) ~= "table" then
        -- No settings table yet (fresh install, or a partial write). Start
        -- one rather than dropping the preference on the floor.
        settings = {}
    end
    settings[FIELD] = mode
    local ok_save = pcall(function()
        G_reader_settings:saveSetting(PLUGIN_KEY, settings)
    end)
    if not ok_save then
        M.last_error = "save failed"
        return false
    end
    return true
end

-- Next mode in the cycle, wrapping after the last one.
function M.next(mode)
    mode = tonumber(mode) or 1
    if mode < 1 or mode > MODE_COUNT then mode = 1 end
    return (mode % MODE_COUNT) + 1
end

M.MODE_COUNT = MODE_COUNT
M.FIELD = FIELD

return M
