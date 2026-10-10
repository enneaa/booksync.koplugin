-- naming.lua — BookSync
--
-- ONE place decides what a file is called in the cloud. Before this existed
-- there were two independent implementations of the same idea -- one in
-- remote.lua for metadata, one in book_sync.lua for book files -- which agreed
-- by hand and could drift apart silently.
--
-- The rule is fixed:
--
--   metadata  ->  Title_Author.lua
--   book file ->  the name the file already has on this device
--
-- It used to be a user setting, with three options per kind. Two things were
-- wrong with that. The options were not independent: "title" and "metadata"
-- were the same behaviour under two names, and "title_author" silently
-- collapsed into "title" whenever a book had no author. And because downloads
-- resolve the cloud name the same way uploads write it, changing the setting
-- re-pointed the lookup as well -- so an existing cloud stopped being found,
-- with nothing on screen to say why.
--
-- A fixed rule has neither problem. Nothing to keep consistent with, and
-- nothing the user can break by switching it.

local M = {}

local ILLEGAL = '[\\/:*?\"<>|%s]'
local MAX_LEN = 200

function M.sanitize(name)
    if not name or name == "" then
        return "unknown_book"
    end
    local out = name:gsub(ILLEGAL, "_")
    if #out > MAX_LEN then
        out = out:sub(1, MAX_LEN)
    end
    return out
end

-- "Title - Author" is a FILENAME convention, not part of a title. Plenty of
-- books are stored as "三体 - 刘慈欣.epub", and when that string is the title
-- -- which is what happens for any book whose doc_props never got filled in --
-- joining the author back on produced "三体_-_刘慈欣.lua": the separator was
-- preserved, then another one added, and the author appeared twice in the
-- shape "三体_–刘慈欣_刘慈欣".
--
-- So the join is about the two fields, not about a fixed template:
--   * a separator run glued to the end of the title is dropped
--   * a separator run at the start of the author is dropped
--   * if the title already ends with the author, the separator in front of it
--     becomes the join instead of adding a second one
--   * what is left, if anything, becomes the join
--
-- This only ever removes punctuation the two fields brought with them. A title
-- that does not end with its author is untouched.
-- Lua patterns match BYTES, not characters, and a character class built from
-- a multi-byte string silently becomes a class of its individual bytes. 0x93
-- is the last byte of U+2013 (en dash) -- and also the last byte of 体. So a
-- class containing "–" made "三体 - 刘慈欣" come out as "三�_刘慈欣": a byte
-- was eaten out of the middle of the title, on any Chinese title ending in a
-- character whose last byte happened to be one of the dash bytes.
--
-- The classes below are therefore ASCII only, and the unicode dashes are
-- folded to "-" by explicit byte-string replacement, which does not have that
-- failure mode.
local SPACED_JOIN = "%s+%-+%s*"

local function fold_joins(s)
    s = s:gsub(SPACED_JOIN, "_")
    return s
end

local function fold_dashes(s)
    s = s:gsub("\226\128\147", "-")   -- U+2013 en dash
    s = s:gsub("\226\128\148", "-")   -- U+2014 em dash
    s = s:gsub("\226\128\189", "-")   -- U+2015 horizontal bar
    s = s:gsub("\227\128\130", "-")   -- U+2010 hyphen
    s = s:gsub("\226\128\136", "-")   -- U+2018 left single quote
    s = s:gsub("\226\128\137", "-")   -- U+2019 right single quote
    return s
end

local SEP_TAIL = "[%s%-_]+$"
local SEP_HEAD = "^[%s%-_]+"

-- "三体 - 刘慈欣" has to become "三体_刘慈欣" and not just when the author
-- happens to be known: a book whose doc_props was never filled in gets its
-- title from the filename AND no author at all, so there is no author field to
-- strip anything against. The separator is the convention, not the data, so it
-- is folded wherever it appears.
--
-- Only a SPACED separator counts. "三体-刘慈欣" and "三体-刘慈欣" stay as they
-- are: without a space around it that is a hyphen in a name, not a join
-- between two fields. The cost of the rule is a real title containing " - "
-- losing its spacing -- "Anna Karenina - Annotated" becomes
-- "Anna_Karenina_Annotated" -- which is a name in the cloud, not the file on
-- the device, and is stable once written.
function M.metadata_name(book)
    local title = book.title
    if not title or title == "" then
        title = book.book_basename or "unknown_book"
    end

    title = fold_joins(fold_dashes(title))

    local author = book.author
    if type(author) ~= "string" or author == "" then
        author = nil
    end
    if author then
        author = fold_dashes(author):gsub(SEP_HEAD, "")
        author = author:gsub(SPACED_JOIN, "_")
        if author == "" then author = nil end
    end

    title = title:gsub(SEP_TAIL, "")
    if title == "" then
        title = fold_joins(fold_dashes(book.book_basename or "")):gsub(SEP_TAIL, "")
        if title == "" then title = "unknown_book" end
    end

    if author then
        if title:sub(-#author) == author then
            -- Already there. Keep one join, from the separator in front of it.
            if #title > #author then
                local head = title:sub(1, #title - #author):gsub(SEP_TAIL, "")
                title = (head ~= "" and (head .. "_" .. author) or author)
            else
                title = author
            end
        else
            title = title .. "_" .. author
        end
    end

    return M.sanitize(title) .. ".lua"
end

-- A book file keeps the name it already has on this device, byte for byte.
--
-- It used to run through sanitize() first, which replaces whitespace and a
-- handful of punctuation characters. That was doing real damage: a book
-- called "三体 - 刘慈欣.epub" was stored in the cloud as "三体_-_刘慈欣.epub",
-- so the download wrote a DIFFERENT filename than the one the user has been
-- looking at, and the upload-time duplicate check compared a name no local
-- file had. The name is never used for display and never has to be invented,
-- so there is nothing to make safe: it came off the filesystem, where it is
-- already exactly as legal as it needs to be.
--
-- Taking the path apart is still worth doing, because file_path is a path.
function M.book_name(book, _ext)
    local name = book.file_path:match("([^/\\]+)$")
    if not name or name == "" then
        return "unknown_book"
    end
    return name
end

return M
