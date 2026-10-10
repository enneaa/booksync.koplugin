local _ = require("gettext")

-- SINGLE SOURCE OF TRUTH for the display name.
-- Everything user-facing (plugin manager, menu entry, gesture titles) reads
-- this via the `fullname` field PluginLoader merges onto the module, so
-- renaming later is a one-line change here.
--
-- `name` is the plugin's own id and must match the folder name on disk
-- (booksync.koplugin), because that is what KOReader installs and lists.
--
-- `plugin_id` is the G_reader_settings key holding every setting (cloud
-- directory, naming rules, exclude list, all auto-sync toggles), and it is
-- read as a literal string from a dozen modules.
--
-- There is deliberately no migration code for a rename. Changing plugin_id
-- now means existing installations start from default settings, which is the
-- intended behaviour for a clean break -- but it is a one-way door, so treat
-- it as a major-version decision rather than a cosmetic edit.
return {
    name = "booksync",
    fullname = _("BookSync"),
    -- Not wrapped in _(): it is a settings key, not display text. Translating
    -- it would look up a catalogue entry and could hand a different string to
    -- G_reader_settings, so the configuration would silently stop being read.
    plugin_id = "booksync_plugin",
    description = _([[Sync books and metadata (annotations, reading progress, etc.) between devices.]]),
    version = "v1.47.0"
}
