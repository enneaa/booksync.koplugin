local M = {}

-- Ordering key for an annotation, used only to sort the merged list.
local function get_sort_key(anno)
    if type(anno.page) == "string" then
        local nums = {}
        for num in anno.page:gmatch("%d+") do
            table.insert(nums, string.format("%08d", tonumber(num)))
        end
        while #nums < 10 do
            table.insert(nums, "00000000")
        end
        return table.concat(nums, "|")
    end
    
    if type(anno.page) == "number" then
        local page = anno.page
        local y = 0
        local x = 0
        if anno.pos0 and type(anno.pos0) == "table" then
            y = anno.pos0.y or 0
            x = anno.pos0.x or 0
        end
        return string.format("pdf|%08d|%010.2f|%010.2f", page, y, x)
    end
    
    return ""
end

-- Numeric progress used to decide which device is further into the book.
--
-- The original code compared `last_xpointer` as a *string*:
--     if cloud_xp > local_xp then
-- XPointers look like "/body/DocFragment[3]/body/div/p[7]/text.0.5" and share no
-- ordering whatsoever, so "take the further value" actually meant "whichever
-- string happens to sort higher" -- devices would keep overwriting each other's
-- reading position with a regression. Compare real progress instead, and fall
-- back to the xpointer string only when neither side has usable numbers.
local function progress_rank(data)
    local pct = tonumber(data.percent_finished)
    local page = tonumber(data.last_page)
    if pct then return { 1, pct, page or 0 } end
    if page then return { 1, 0, page } end
    return nil
end

-- prefer_cloud_position: "Overwrite" mode. It means "the cloud's reading
-- position wins even when it is behind", NOT "delete everything the cloud
-- does not have". Local-only annotations are always kept -- see
-- override_merge below.
function M.merge(local_path, cloud_path, prefer_cloud_position)
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not local_data and not cloud_data then
        return nil
    end
    
    if not local_data then
        return cloud_data
    end
    
    if not cloud_data then
        return nil
    end
    
    local_data.annotations = M.merge_annotations(
        local_data.annotations or {},
        cloud_data.annotations or {}
    )
    
    if local_data.annotations and #local_data.annotations > 0 then
        table.sort(local_data.annotations, function(a, b)
            local ka, kb = get_sort_key(a), get_sort_key(b)
            if ka == kb then return false end
            return ka < kb
        end)
    end
    
    M.merge_progress(local_data, cloud_data, prefer_cloud_position)
    M.merge_stats(local_data, cloud_data)
    M.merge_summary(local_data, cloud_data)
    
    local_data.last_merged = os.date("%Y-%m-%d %H:%M:%S")
    
    return local_data
end

function M.override_merge(local_path, cloud_path)
    local local_data = M.load_metadata(local_path)
    local cloud_data = M.load_metadata(cloud_path)
    
    if not cloud_data then
        return nil
    end
    
    if not local_data then
        return cloud_data
    end
    
    local result = local_data

    -- Annotations are a UNION, never a replacement. The previous version copied
    -- a list of field names wholesale, so any annotation the cloud did not have was
    -- silently destroyed -- and combined with a cloud copy that was frozen
    -- (see the If-None-Match fix in cloudapi.lua) that turned "download with
    -- overwrite" into "restore a months-old snapshot over everything I have
    -- read since". Losing notes is not something an "Overwrite" button should
    -- be able to do.
    result.annotations = M.merge_annotations(
        local_data.annotations or {},
        cloud_data.annotations or {}
    )
    if #result.annotations > 0 then
        table.sort(result.annotations, function(a, b)
            local ka, kb = get_sort_key(a), get_sort_key(b)
            if ka == kb then return false end
            return ka < kb
        end)
    end

    -- Bookmarks and the book summary are the same on both sides by definition;
    -- taking the cloud copy is safe because neither can lose local-only data.
    for _, field in ipairs({ "bookmarks", "summary" }) do
        if cloud_data[field] ~= nil then
            result[field] = cloud_data[field]
        end
    end

    -- The reading position follows the cloud, even if it is behind.
    M.merge_progress(result, cloud_data, true)

    M.merge_stats(result, {})

    return result
end

-- Compile a chunk of Lua source into a callable.
-- `load` only accepts a string from Lua 5.2 onwards; on a plain 5.1 build the
-- call raises "bad argument #1 to 'load' (function expected, got string)".
-- LuaJIT tolerates it, but there is no reason to depend on that.
local _loadstring = loadstring or load

-- Sidecars are pure data ("return { ... }"), but they arrive from the cloud,
-- and we were executing that source with full privileges. pcall does not help:
-- os.exit(), io.remove() and the debug library are *legal* calls, so a
-- truncated-then-repaired file, a misconfigured server serving something that
-- happens to parse, or a tampered sidecar could terminate or rewrite the reader
-- while looking like a plain crash. Running the chunk with an empty global
-- environment costs nothing -- the data format needs no globals -- and turns
-- that class of failure into an ordinary "invalid metadata" rejection.
local _setfenv = setfenv
local _sandboxed = {}
local function sandboxed(func)
    -- NOTE: getfenv(0) is the *current* function's environment, which for the
    -- main chunk IS the real global table -- using it isolates nothing. It has
    -- to be a genuinely fresh, metatable-free table.
    if _setfenv then
        pcall(_setfenv, func, _sandboxed)
    end
    return func
end

function M.load_metadata(path)
    local f = io.open(path, "r")
    if not f then 
        return nil 
    end
    
    local content = f:read("*all")
    f:close()
    
    if type(content) ~= "string" then return nil end

    -- strip UTF-8 BOM
    content = (content:gsub("^\239\187\191", ""))
    
    local func = _loadstring(content, "metadata")
    if not func then
        return nil
    end
    sandboxed(func)
    
    local ok, result = pcall(func)
    if not ok or type(result) ~= "table" then
        return nil
    end
    
    return result
end


-- Union the two annotation lists, keeping the newer copy of anything that
-- exists on both sides.
--
-- The previous version stored local annotations in a `key -> entry` map, so two
-- local annotations that hashed to the same key silently overwrote each other
-- and one was lost before the merge even started. The map is now local-only and
-- multi-valued, and cloud entries are consumed as they match, which dedupes
-- across devices (the actual goal) without ever dropping two local highlights.
function M.merge_annotations(local_annos, cloud_annos)
    -- Both lists are optional at this level. Every caller in the plugin passes
    -- `or {}`, but this is a public function and ipairs(nil) is a hard error
    -- rather than an empty result.
    local_annos = local_annos or {}
    cloud_annos = cloud_annos or {}

    local merged = {}
    local local_by_key = {}

    local function get_time(anno)
        return anno.datetime_updated or anno.datetime or "0"
    end

    for i, anno in ipairs(local_annos) do
        local key = M.get_annotation_key(anno)
        if key then
            local bucket = local_by_key[key]
            if not bucket then
                bucket = {}
                local_by_key[key] = bucket
            end
            -- Remember where this anno landed in `merged` so a cloud copy can
            -- replace it in place later.
            table.insert(bucket, { anno = anno, merged_index = i, consumed = false })
        end
        table.insert(merged, anno)
    end

    for _, anno in ipairs(cloud_annos) do
        local key = M.get_annotation_key(anno)
        local bucket = key and local_by_key[key] or nil
        local consumed = false
        if bucket then
            -- Take the newest local entry that has not already been taken.
            --
            -- The `not entry.consumed` test is the whole point. A key is not a
            -- uniqueness constraint: for a non-PDF document the key is
            -- `kind|page`, so EVERY highlight on page 5 has the same key. Two
            -- highlights written on two different devices therefore arrive as
            -- two cloud annotations sharing one key, and the previous version
            -- let both of them replace the SAME local entry -- the second
            -- overwrote the first, so the first cloud highlight vanished with
            -- no error anywhere. It was the same silent loss as the old
            -- local-side overwrite bug, moved to the cloud side.
            --
            -- Marking the entry consumed means each local annotation can be
            -- superseded at most once, and a cloud annotation with no local
            -- entry left to replace is kept rather than dropped.
            local best_local
            for _bi, entry in ipairs(bucket) do
                if not entry.consumed and
                   (not best_local or get_time(entry.anno) > get_time(best_local.anno)) then
                    best_local = entry
                end
            end
            if best_local then
                best_local.consumed = true
                consumed = true
                if get_time(anno) > get_time(best_local.anno) then
                    merged[best_local.merged_index] = anno
                end
            end
        end
        if not consumed then
            table.insert(merged, anno)
        end
    end

    return merged
end

-- Identity of an annotation for cross-device dedup.
--
-- Includes the drawer so a bookmark and a highlight on the same page are no
-- longer treated as the same object (the old key was just the page for
-- non-PDF docs and "pdf|bookmark|<page>" for PDF, so those collided and one
-- was dropped on every merge).
function M.get_annotation_key(anno)
    if not anno then
        return nil
    end

    local kind = type(anno.drawer) == "string" and anno.drawer
        or (anno.type == "bookmark" and "bookmark" or "highlight")

    if type(anno.page) == "string" then
        return kind .. "|" .. anno.page
    end

    if anno.pos0 and type(anno.pos0) == "table" then
        return string.format("%s|pdf|%d|%.2f|%.2f",
            kind, anno.pos0.page or 0, anno.pos0.x or 0, anno.pos0.y or 0)
    end

    if type(anno.page) == "number" then
        return string.format("%s|pdf|bookmark|%d", kind, anno.page)
    end

    return nil
end

function M.merge_progress(local_data, cloud_data, prefer_cloud_position)
    local local_rank = progress_rank(local_data)
    local cloud_rank = progress_rank(cloud_data)

    -- "Take the further value": only adopt the cloud position when it is
    -- genuinely ahead on real numbers. With no numeric progress on either side
    -- we keep the local position rather than guessing from xpointer text.
    -- Overwrite mode skips the comparison and follows the cloud.
    if cloud_rank and (prefer_cloud_position or not local_rank or
        cloud_rank[2] > local_rank[2] or
        (cloud_rank[2] == local_rank[2] and cloud_rank[3] > local_rank[3])) then
        -- Copy field by field, skipping whatever the cloud side does not have.
        -- Assigning unconditionally erased good local values with nil: an old
        -- sidecar written by an older KOReader carries last_xpointer but no
        -- percent_finished, while a newer one carries percent_finished but no
        -- xpointer for some formats. Merging those two wiped the exact reading
        -- position and the book reopened at an arbitrary place.
        for _, field in ipairs({ "last_xpointer", "last_page", "percent_finished" }) do
            if cloud_data[field] ~= nil then
                local_data[field] = cloud_data[field]
            end
        end
    end
end

function M.merge_stats(local_data, cloud_data)
    local highlights = 0
    local notes = 0
    for _, anno in ipairs(local_data.annotations or {}) do
        if anno.drawer then
            if anno.note and anno.note ~= "" then
                notes = notes + 1
            else
                highlights = highlights + 1
            end
        end
    end
    
    if not local_data.stats then
        local_data.stats = {}
    end
    local_data.stats.highlights = highlights
    local_data.stats.notes = notes
end

function M.merge_summary(local_data, cloud_data)
    local summary = local_data.summary or {}
    local cloud_summary = cloud_data.summary or {}
    
    local priority = {
        ["complete"] = 3,
        ["reading"] = 2,
        ["new"] = 1,
    }
    
    local local_pri = priority[summary.status] or 0
    local cloud_pri = priority[cloud_summary.status] or 0
    
    if cloud_pri > local_pri then
        summary.status = cloud_summary.status
        if cloud_summary.modified then
            summary.modified = cloud_summary.modified
        end
    end
    
    local_data.summary = summary
end

return M
