-- i18n.lua — BookSync
-- Injects the plugin's .po translations directly into KOReader's GetText

local logger = require("logger")

local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")

-- ---------------------------------------------------------------------------
-- Minimal .po parser
-- ---------------------------------------------------------------------------
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local translations = {}
    local contexts = {}

    local ctx, id, str
    local in_id, in_str, in_ctx = false, false, false

    local function unescape(s)
        return s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
    end

    local function flush()
        if id and id ~= "" and str and str ~= "" then
            if ctx and ctx ~= "" then
                if not contexts[ctx] then contexts[ctx] = {} end
                contexts[ctx][id] = str
            else
                translations[id] = str
            end
        end
        ctx, id, str = nil, nil, nil
        in_id, in_str, in_ctx = false, false, false
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            if line == "" then flush() end
        elseif line:match("^msgctxt%s+\"") then
            flush()
            ctx = unescape(line:match('^msgctxt%s+"(.*)"') or "")
            in_ctx = true; in_id = false; in_str = false
        elseif line:match("^msgid%s+\"") then
            if not in_ctx then flush() end
            in_ctx = false
            id = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id = true; in_str = false
        elseif line:match("^msgstr%s+\"") then
            str = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id = false; in_ctx = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_ctx and ctx then ctx = ctx .. cont end
            if in_id and id then id = id .. cont end
            if in_str and str then str = str .. cont end
        end
    end
    flush()
    f:close()

    local count = 0
    for _ in pairs(translations) do count = count + 1 end
    for _ in pairs(contexts) do count = count + 1 end

    return translations, contexts, count
end

-- ---------------------------------------------------------------------------
-- Language detection
-- ---------------------------------------------------------------------------
local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_]+)")
    return lang or "en"
end

-- ---------------------------------------------------------------------------
-- Load .po translations
-- ---------------------------------------------------------------------------
local function loadTranslationsForLang(lang)
    if not lang or lang == "en" or lang:match("^en_") then return nil, nil end

    local function try(name)
        local path = _dir .. "locales/" .. name .. ".po"
        local t, c, n = parsePO(path)
        if t and n and n > 0 then
            return t, c
        end
        return nil, nil
    end

    local t, c = try(lang)
    if t then return t, c end

    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix and prefix ~= lang then
        return try(prefix)
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- install / uninstall
-- ---------------------------------------------------------------------------
--
-- The plugin catalogue is handed to the private shim in gettext_shim.lua.
-- It is deliberately NOT written into GetText.translation / GetText.context:
-- those are KOReader's own tables, shared by every core module, so writing
-- there hijacked core UI strings app-wide ("Settings", "Continue", "Cancel",
-- "Search", "Delete", "Back", "Unknown" all collide with the shipped .po).
--
-- The old changeLang patch is gone too -- it tested `type(mt.__index) == "table"`
-- while KOReader's gettext uses a function __index, so the condition was never
-- true and the patch silently did nothing. Re-applying the catalogue is now
-- driven by the caller, which knows when the language actually changed.

local _installed = false
local _shim = nil

-- Reuse the same package.loaded cache every other module uses, so the shim is
-- compiled once rather than on each install()/refresh().
local function currentShim()
    if _shim then return _shim end
    local cached = package.loaded["booksync.gettext_shim"]
    if cached then
        _shim = cached
        return cached
    end
    local dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")
    local ok, shim = pcall(dofile, dir .. "gettext_shim.lua")
    if ok and shim then
        package.loaded["booksync.gettext_shim"] = shim
        _shim = shim
        return shim
    end
    return nil
end

local function install()
    if _installed then return end

    local shim = currentShim()
    if not shim then
        logger.warn("booksync i18n: shim not found — falling back to KOReader strings")
        return
    end

    local translations, contexts = loadTranslationsForLang(detectLang())
    shim.setCatalog(translations, contexts)

    _installed = true
end

local loaded_lang = nil

-- Re-read the catalogue for `lang` (nil = current setting) and push it into
-- the shim.
--
-- init() calls this on every entry into the plugin menu, and parsing a
-- ~35 KB .po into a fresh 400-entry table each time is pure waste unless the
-- language actually changed -- which is the only reason this function exists.
-- The comment above it claimed to be checking for that and never did.
local function refresh(lang)
    local shim = currentShim()
    if not shim then return end
    local target = lang or detectLang()
    if target == loaded_lang then return end
    local translations, contexts = loadTranslationsForLang(target)
    shim.setCatalog(translations, contexts)
    loaded_lang = target
end

local function uninstall()
    local shim = currentShim()
    if shim then
        shim.setCatalog(nil, nil)
    end
    _installed = false
end

return {
    install = install,
    uninstall = uninstall,
    refresh = refresh,
    getLang = detectLang,
}