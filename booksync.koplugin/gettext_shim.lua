-- gettext_shim.lua — BookSync
--
-- Plugin-scoped translation layer.
--
-- The previous i18n.install() wrote the plugin's zh_CN.po entries straight into
-- KOReader's shared GetText.translation / GetText.context tables. Those tables
-- are the *core* ones -- every KOReader module holds a reference to the same
-- table -- so any msgid shared between the plugin and core got hijacked
-- app-wide. The shipped .po alone collides on:
--
--     Settings  Continue  Cancel  Search  Delete  Back  Unknown
--
-- which silently turned KOReader's own menus into Chinese (or the reverse,
-- depending on locale) the moment the plugin was initialised.
--
-- This shim keeps the plugin's catalogue private: look it up first, fall back
-- to KOReader's real gettext for everything else. Core strings are never
-- touched.

-- pcall, not a bare require: every module does local _ = module("gettext_shim")
-- at FILE SCOPE, so a raise here propagates out of module() -> out of the
-- dofile in the caller -> the plugin does not load at all. The shim's own
-- translations table is entirely self-contained, so losing core gettext should
-- degrade to English, not take the whole plugin down with it.
local ok_gettext, GetText = pcall(require, "gettext")
if not ok_gettext or type(GetText) ~= "table" then
    GetText = {
        translation = {},
        context = {},
    }
    local function identity(s) return s end
    GetText.gettext = GetText.gettext or identity
    GetText.pgettext = GetText.pgettext or identity
    GetText.ngettext = GetText.ngettext or function(s, p, n) return n == 1 and s or p end
    GetText.npgettext = GetText.npgettext or function(s, c, p, n) return n == 1 and s or p end
end

local M = {}

M.translations = nil
M.contexts = nil

local function t(str)
    return type(str) == "string" and str or nil
end

-- Translation lookup. Kept as a named function so the module can also be
-- called directly: every plugin module does `local _ = dofile(...shim...)` and
-- then `_("...")`, which only works if the returned table has a __call
-- metamethod (KOReader's real gettext has one).
function M.translate(str)
    local s = t(str)
    if not s then return str end
    if M.translations then
        local hit = M.translations[s]
        if hit and hit ~= "" then return hit end
    end
    return GetText(s)
end

-- Extraction no-ops, kept so the .po tooling still sees the right shape.
function M.N_(str) return str end

function M.ngettext(msgid, plural, n)
    if M.translations and M.translations[msgid] then
        return M.translations[msgid]
    end
    return GetText.ngettext and GetText.ngettext(msgid, plural, n) or msgid
end

function M.pgettext(ctx, str)
    local s = t(str)
    if not s then return str end
    if M.contexts and M.contexts[t(ctx)] and M.contexts[t(ctx)][s] then
        return M.contexts[t(ctx)][s]
    end
    return GetText.pgettext and GetText.pgettext(ctx, str) or str
end

function M.npgettext(ctx, msgid, plural, n)
    if M.contexts and M.contexts[t(ctx)] and M.contexts[t(ctx)][msgid] then
        return M.contexts[t(ctx)][msgid]
    end
    return GetText.npgettext and GetText.npgettext(ctx, msgid, plural, n) or msgid
end

-- Install (or refresh) the plugin catalogue for a given language.
function M.setCatalog(translations, contexts)
    M.translations = translations
    M.contexts = contexts
end

return setmetatable(M, {
    __call = function(_unused, str) return M.translate(str) end,
})
