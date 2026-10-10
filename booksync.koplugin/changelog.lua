-- Post-update "What's New" bullet lists, keyed by version string.
-- Add an entry for each release with noteworthy changes.
-- Omit a version to show no changelog on that update.
--
-- Example:
-- ["0.1.0"] = {
--     "New feature added",
--     "Bug fix for ...",
-- },

return {
["1.47"] = {
    "The automatic all-books download now starts 1 second after launch instead of 3",
},
["1.46"] = {
    "When KOReader keeps its metadata in a central folder, an all-books scan that came back empty now retries against the book directory. A book only has an entry there once it has been opened on this device, so a library of never-opened books used to report 'No books to sync'",
},
["1.45"] = {
    "An automatic all-books sync now says when it starts, not only when it finishes. On a slow connection the end-of-run line arrived minutes later, and a run in progress looked exactly like one that never began",
    "A failed scan, a crash and a sync that could not start are now reported on screen. They used to go to the log file only, so the run just vanished",
},
["1.44"] = {
    "The all-books scan no longer freezes the screen. Walking the book directory used to run to completion in one go, and every file costs a provider check plus a metadata read. It now works in small steps, handing the screen back to KOReader in between",
},
["1.42"] = {
    "An automatic all-books run now says what it did. It runs in the background, so the progress dialog is suppressed and the only trace was the 'Last sync' line, which meant a download that worked and one that never ran looked identical",
},
["1.40"] = {
    "Fixed 'On app start' properly. KOReader loads plugins from inside the file browser's own constructor and only assigns the browser instance at the very end of it, so BookSync was installing itself one step too late to see the startup it was waiting for -- which is why the setting never did anything, on any launch that started in the library",
},
["1.39"] = {
    "Fixed the same dead 'current folder' lookup in the manual all-books scan. It only appeared to work because a last opened book was on record to fall back on; a fresh install would have asked you to open a file browser you were already standing in",
},
["1.38"] = {
    "Fixed 'On app start: download metadata for ALL books'. KOReader builds the file browser before plugins load, so the plugin was never there to see the one startup it cared about, and the feature did nothing until you left the library and came back",
    "Fixed the 'current folder' fallback when deciding what to scan: it asked the file browser for a field that no longer exists, so it always came up empty",
    "An all-books run that has nowhere to scan now says so, instead of returning in silence",
    "Moved 'Last sync' to the bottom of the BookSync menu, as a footer under the actions",
},
["1.37"] = {
    "Fixed the long-press menu hanging. BookSync was adding its row to the file browser from a 2-second timer, so it could write into the button table while KOReader was reading that same table to build the menu. Registration now happens when the browser is created, with no polling",
    "Moved 'Last sync' out of the More Settings submenu to the top of the BookSync menu, where it can be read without opening a submenu",
},
["1.36"] = {
    "Turning 'Buttons in the long-press menu' back on now takes effect right away. It used to do nothing until the BookSync menu was opened again, which made the switch look broken",
},
["1.35"] = {
    "Fixed the long-press menu hanging on opening: BookSync added a single row holding three buttons, which on a narrow screen left each one too small for its label and sent KOReader's button layout into its shrink-and-redraw path. The entries are now one per row, like KOReader's own",
    "Shortened the long-press menu labels",
},
["1.34"] = {
    "New setting: turn the long-press menu entries on or off, in case that menu misbehaves on your device",
    "The setting takes effect the next time the BookSync menu is opened; no restart needed",
},
["1.33"] = {
    "Fixed the long-press menu on a book not always closing: it dismissed the dialog belonging to a file browser that had already been replaced, so the menu could stay on screen and ignore every tap",
    "Opening the plugin menu no longer leaves a background timer behind each time it is opened while the file browser is not on screen yet",
},
["1.32"] = {
    "Faster book downloads: the existence and size of each file was looked up with up to three separate stat calls; now it is one",
    "Opening a book is faster when auto-download is on: the sync log was allowed to grow to 512 KB and is rewritten in full on every entry, so a write cost about four times what it should. The cap is now 128 KB, which still holds over a thousand entries",
    "Turning a page no longer looks up the current page number when auto-upload-on-chapter is switched off",
},
["1.31"] = {
    "Fixed the file browser switching itself into selection mode on its own. The cleanup that runs after a batch was toggling selection mode unconditionally, so a batch that finished after you had already left selection mode turned it back on",
    "The post-batch cleanup no longer rebuilds the file list twice, which showed up as a freeze on folders with many books",
},
["1.30"] = {
    "Restored the built-in cloud storage picker, which had been dropped on the assumption that KOReader removed it. It did not, and on builds that still ship it the plugin now opens that picker again instead of reporting that no cloud storage dialog is available",
    "The cloud book list now remembers how you sorted it, instead of going back to name A-Z every time the list is opened",
},
["1.29"] = {
    "Rewrote the sync notifications to be shorter and to say what happened: success lines name the result (updated / uploaded) instead of repeating the action, failures lead with the actual reason, and network errors read as \"Offline\" instead of a full sentence",
    "Removed the \"Merge\" label from download notifications, since all downloads now merge and there is no mode left to report",
    "Fixed \"Sync failed\" notifications, which previously gave no reason at all",
    "Shortened pre-sync setup hints to one line each while keeping the action to take",
},
["1.0"] = {
    "Added book sync functionality, allowing batch upload, download, or deletion of cloud books",
    "Added gesture shortcuts, allowing quick actions and quick settings via gestures",
    "Fixed potential state confusion in file browser selection mode when using gesture shortcuts",
    "Fixed crash issue with PDF documents during merge update",
    "Fixed issue where some annotations might lose rendering during merge update",
    "Optimized note update issues during merge update",
    "Added function to clear cloud sync logs",
    "Fixed potential format confusion issue when enabling Record Cloud Sync for sync logs",
    "Removed mutual exclusion restriction for auto upload and auto download, allowing both to be enabled simultaneously",
    "Added online update feature",
    "Changed overwrite update from complete overwrite to optional overwrite, allowing choice to keep local document settings",
},

["1.1"] = {
    "Fixed online update crash issue on Android",
},

["1.2"] = {
    "Fixed the issue where synchronization failed when opening a book for the first time",
    "Added support for setting an independent cloud directory for books (separate from metadata cloud directory)",
},

["1.3"] = {
    "Added pre-flight checks for network and configuration",
    "Added Worry-Free Sync Mode quick toggle for metadata",
    "Fixed path concatenation issues for sync logs, metadata and temporary folders",
    "Removed debug logs",
},

["1.4"] = {
    "Added English support: Menu changed to English with Chinese translation",
    "Progress bar for upload/download: Upload progress by book count, download progress by bytes",
    "Manual and auto sync download modes are no longer shared: Prevents temporary switching of download mode in manual sync from affecting automated sync tasks",
    "Optimized update channel: Added three update sources options - GitHub (Latest), GitHub (Pre-release), Gitee (Latest)",
},

["1.4.1"] = {
    "Added changelog.lua to track version history",
    "Optimize plugin module loading path and fix naming conflict with other plugins",
},
["1.4.2"] = {
    "Fix: support all KOReader formats in book validation (including .fb2.zip)",
    "Non-touch navigation for the cloud book dialog",
},
["1.4.3"] = {
    "Added Auto Sync Exclude Directories feature",
    "Optimized gesture registration: merged reader/filemanager paired gestures into unified general gestures",
},
["1.4.4"] = {
    "Added quick folder navigation to cloud book dialog for switching cloud directories",
    "Optimized upload/download/delete progress dialogs with book name and progress counter display",
    "Add auto WiFi prompt and retry for network-dependent operations",
    "Optimize cloud book dialog refresh logic for better K3/e-ink experience",
    "Wrap page navigation for K3/e-ink devices",
    "Display release notes when new version is found",
    "Improved Chinese translations",
},
["1.4.5"] = {
    "Integrate with Bookshelf: batch operations now auto-enter Bookshelf selection mode and retrieve selected books",
    "Fix garbled text when truncating Chinese folder paths in cloud book dialog navigation",
    "Optimization: Repaint the progress bar once a second on non-touch Kindles to improve download progress feedback",
    "Improved Chinese translations",
},
["1.4.6"] = {
    "Fix Nutstore WebDAV 750-file limit causing incomplete cloud book list",
    "Add upload/download metadata(CL) and upload book(CL) actions to the long-press menu",
    "Add batch upload/download metadatas(CL) and batch upload books(CL) to the selection-mode Plus menu",
},
["1.5.0-crashfix"] = {
    "Fix: cloud API calls are now error-boundary protected - a failed request no longer takes down KOReader",
    "Fix: removed the reader teardown/reopen sandwich that crashed when applying downloaded metadata; now uses ReaderUI:reloadDocument()",
    "Fix: onClose / onSuspend hooks are no longer re-wrapped on every visit to the plugin menu (was stacking N layers and leaking finalized plugin instances)",
    "Fix: progress dialog now repaints during large downloads (time comparison used the wrong unit, so it froze after the first frame)",
    "Fix: metadata download now actually persists when Documents > Book Metadata Folder is set to 'hash' (the sidecar lost its doc_path and was written to the filesystem root)",
    "Fix: no longer hijacks KOReader's own UI strings - plugin translations are scoped to the plugin (Settings/Continue/Cancel/Search/Delete/Back were leaking app-wide)",
    "Fix: bookmark selection helpers no longer call a non-existent FileManager API",
    "Fix: merge no longer drops annotations that share a page, and no longer lets a stale cloud xpointer overwrite a further reading position",
    "Fix: 'goto' replaced with portable control flow so the plugin loads on Lua builds without 5.2 compatibility",
    "Performance: module loading is now cached (package.loaded) instead of recompiling ~8k lines of Lua every time a menu was drawn; utils.lua went from 150 recompilations per 10 menu visits to 1",
    "Fix: cloud access no longer depends on KOReader's private apps/cloudstorage modules, which were removed in the 2024.x reorganisation - WebDAV now talks to the server directly and works on every KOReader version",
    "Fix: cloud account/directory picker works on the new cloudstorage.koplugin layout",
    "Fix: batch operations can no longer stall or leave a stuck progress dialog when an item fails; every step is error-contained and the dialog is always closed",
    "Fix: batch book download no longer blocks the UI thread for the whole transfer",
    "Fix: log-sync debounce no longer wedges after a single failure",
    "Fix: plugin event handlers (page turn, scroll, suspend, gestures) can no longer propagate an error into the reader",
},
["1.6.0"] = {
    "Renamed to Cloud Library Sync. The display name now lives in exactly one place (_meta.lua); the settings key is unchanged so nothing is reset",
    "Upload/download current book metadata now also work from the FileManager, falling back to the last opened book (the book-file entry already did)",
    "The last opened book is now recorded from app start, so that fallback is populated on a fresh install instead of only after the plugin menu has been opened once",
    "Removed the Overwrite/Merge submenu from Download current/all books metadata: the mode is set once in Settings and the active mode is shown inline. The two entries previously disagreed - one silently rewrote the setting, the other did not",
    "New trigger: On app start - upload the last read book's metadata and/or pull metadata for all books, once per KOReader launch, deferred until the network is available instead of prompting for Wi-Fi at boot",
    "Renamed the ambiguous 'On opening' trigger to 'On opening a book' so the two entries with that label (current book vs all books) are distinguishable",
},["1.7.0"] = {
    "Renamed the plugin to BookSync and the install folder to booksync.koplugin",
    "Settings are preserved: the internal plugin_id is deliberately unchanged because it is the settings storage key. The two standalone settings named after the old plugin (device id, update source) are migrated on first launch",
    "Self-update looks for booksync.koplugin first and falls back to cloudlibrary.koplugin, so renaming does not break updating before the repository is renamed",
    "Existing gesture bindings keep working: gesture event ids are unchanged. The labels in Settings > Gesture management now read BookSync",
    "The sync log files keep their old names so existing logs stay readable",
},
["1.7.1"] = {
    "Completed the rename: the internal plugin_id is now booksync_plugin and the log files are now booksync_*.txt",
    "Nothing is lost. The entire settings table, the device id and the update source are migrated from the old names on first launch, and the existing log file is moved rather than orphaned",
    "Gesture bindings keep working: gesture event ids are left unchanged on purpose. They are stored in KOReader's core gestures.lua, renaming them would unbind every gesture, and the label you see is built from the plugin name anyway",
},
["1.7.2"] = {
    "Crashes and cloud errors are now written to the plugin's own log with a full Lua traceback, instead of only to logger (which KOReader's crash handler never sees, because every cloud call is pcall-contained). Read them with View Sync Log",
    "Refreshing the FileManager after a batch is now protected: the instance can be stale by the time a long download finishes, and refreshPath on a dead FileChooser is a native crash on Android that pcall cannot catch",
},
["1.7.3"] = {
    "Renamed the Auto Download settings group to Auto Download Metadata. Every trigger in it fetches .sdr sidecars only; the old heading made it look like book files were downloaded automatically too",
},
["1.8.0"] = {
    "A download is no longer accepted on the strength of an HTTP 200 alone. An empty file is deleted and reported as a failure, instead of being left on disk where every later run would see 'already downloaded' and skip the book permanently",
    "A failed Dropbox download no longer leaves a truncated file behind, and a failed Dropbox upload now removes the partial object from the cloud so the next attempt is not skipped as 'already in cloud'",
    "The failure summary no longer shows raw Lua errors. Every reason is a sentence, grouped and counted, in a stable order, with a pointer to the sync log for the technical detail",
},
["1.8.1"] = {
    "Long batches no longer repaint the progress dialog once per item. On Android every repaint posts to the render thread, and a 300-book metadata sync was queueing hundreds of native round trips",
},
["1.13.1"] = {
    "Removed unreachable code: a second and third copy of the filename sanitiser, a dialog-rebuild helper nothing called, an unused results table, and a loader for KOReader's WebDAV module that nothing used",
    "The build now fails on a function that is defined and never called, and on a second implementation of the filename rule",
},
["1.13.0"] = {
    "Removed the self-updater. It shelled out to \"unzip\" through os.execute, which is not present on every KOReader build and is restricted on Android, and no test had ever covered the extraction path. Update by replacing the plugin folder from the release ZIP",
    "The plugin no longer runs any external command",
    "Directory creation goes through KOReader's own frontend/util.makePath instead of a hand-rolled recursive mkdir",
},
["1.12.2"] = {
    "Fix: every automatic trigger in the auto-sync menu was passed to the toggle helper with its two arguments swapped. The menu displayed \"auto_upload_on_open\" instead of \"On opening a book\", and because the label was used as the settings key, none of the switches could actually be turned on: the flag was written to a junk entry named after the translated text",
    "The i18n check now renders both menus and fails on a row that shows a settings key, an untranslated label, or a group left empty by a removed setting",
},
["1.12.1"] = {
    "Drop the compatibility layer: the cloud name is now looked up exactly once, with no fallback to the old names and no re-use of an existing name on upload. Simpler, and one request per download instead of up to three",
},
["1.12.0"] = {
    "Cloud naming is now fixed: metadata is stored as Title_Author, and a book file keeps the name it already has on the device. The four naming settings are gone",
    "No backward compatibility: a cloud written under an older naming rule is not migrated, and the files left there are not touched. The rule is applied as written from the first run",
    "Two independent implementations of the naming rule (one in remote.lua, one in book_sync.lua) are merged into a single module, so they can no longer drift apart",
},
["1.11.6"] = {
    "Fix: 11 interface strings were never added to the Chinese catalogue, so they showed up as raw English in the middle of a Chinese menu. Five of them sat in the background-sync help panel right next to the auto-download settings; the rest were download and write failure messages",
    "The regression suite now drives the real gettext and fails if any user-visible string is missing from the catalogue",
},
["1.11.5"] = {
    "Fix: downloading a book whose name already exists on this device crashed with \"attempt to call local '_' (a number value)\" instead of saying the file was skipped. Three batch callbacks named a parameter `_`, which is this plugin's gettext function, so the failure-reason string tried to call the item's position number",
    "The build now rejects any file that shadows `_`, so this cannot come back",
},
["1.11.4"] = {
    "Fix: \"Sync on app resume\" could crash the moment it fired. The helper it needs was defined thirty lines further down the file, so the name resolved to an empty slot and the very first call raised. It never worked, in any session",
},
["1.11.3"] = {
    "Fix: saving metadata for the open book could fail with a crash even when it worked. A status flag was declared twice in one code path and not at all in the other, so a successful write read an unset value and took the failure branch instead",
    "Fix: the settings-flush, resume and chapter-change triggers could still do nothing on a launch where you had not opened the plugin menu. The lazy loader that was meant to cover exactly that case was itself outside its own error boundary, so it failed before it could build anything",
    "Fix: \"What does this switch do?\" on any auto-sync toggle, and any book title longer than 60 characters in a batch run, could both crash on a missing reference",
    "The gesture \"Quick Settings\" entry is no longer a stale copy of the settings menu. It was copied once, never updated, and had quietly lost the background-activity switch and the re-download setting -- so from a gesture you could not reach the two controls you are most likely to need when something has gone wrong. It now uses the same menu as the gear icon, so it cannot fall behind again",
    "Reading the menu no longer rebuilds it from scratch on every tap; the previous dialog is closed before a new one opens",
},
["1.11.2"] = {
    "The sync log no longer grows without limit. Every entry re-read and rewrote the whole file, so a device that syncs often was copying an ever-larger string each time and the log viewer was then handed all of it at once. It is now capped, keeps the newest records, and says so at the cut",
    "Opening the plugin menu no longer re-reads and re-parses the whole translation file when the language has not changed. That happened on every single menu entry and built a fresh table of several hundred strings for nothing",
    "The long-press menu entries are appended instead of forced into a fixed row position. The plus dialog's row count belongs to KOReader and changes between versions, so a fixed slot displaced a core button and moved ours under Cover Browser mode",
    "Opening the plugin menu no longer writes to your settings. The one-shot latch that suppresses a redundant download was being cleared there, which made \"open the menu\" a way to repair a stuck latch -- and a latch left set by an interrupted reload silently made the NEXT book skip its auto-download",
    "Removed a settings flag that was written on every configuration change and never read anywhere, along with the nine calls that only existed to write it. It also reported \"auto sync enabled\" while looking at four of the twenty-plus triggers",
    "Deleted about a hundred lines of code nothing referenced",
},
["1.11.1"] = {
    "Closing a book or going to sleep no longer puts a modal progress box on the screen. The \"all books\" triggers fire at exactly those two moments, so a batch raised automatically appeared on a screen that was already being torn down or put to sleep -- with no cancel and nobody watching. Background runs now work quietly and report the result; anything you start yourself still shows progress as before",
    "Uploading on book close is now delivered the way KOReader intends. The plugin declares the close-document event instead of only wrapping KOReader's own reader teardown, so it stops depending on a method it does not own. The wrap is kept as a fallback, and whichever of the two arrives first does the work -- it cannot upload twice",
},
["1.11.0"] = {
    "Uploads no longer overwrite what another device saved in between. The plugin now asks the server for the file's tag when it lists the cloud folder, and sends it back when uploading, so a file another device wrote while you were syncing comes back as \"changed\" instead of being silently replaced. It merges the other device's notes and position into yours and tries again. Nothing extra is required from the server, and nothing extra appears in your cloud folder -- it is the same mechanism KOReader's own WebDAV support uses",
    "If that keeps happening the upload gives up and says so rather than trying forever, and your local file is never touched",
    "A sync that could not run because another one was already in progress is no longer thrown away. It is now remembered and retried once things settle, and if it was still pending when KOReader was closed it is picked up on the next launch. Previously closing a book and then suspending dropped the second request without a word, so the last position you actually read was never backed up",
    "Leftover temporary files from interrupted transfers now clean themselves up after a day. Book downloads write to a \".part\" file and a conflicted merge writes a \".conflict\" file until they are verified; those were only removed on the success path, so a device with a flaky connection slowly filled up with files you could neither see nor delete",
},
["1.10.1"] = {
    "The \"sync on settings flush\", \"sync on resume\" and \"sync on chapter change\" triggers now actually fire. KOReader delivers these on the plugin object itself, which has no sync engine and no open book attached, and \"has an open book\" was being answered by whichever screen you last opened the plugin menu from -- so anyone who set the plugin up from the file browser got nothing from them, silently, for as long as they kept using it that way",
    "Chapter tracking no longer resets against a stale copy, so the first page of a newly opened book is no longer mistaken for a chapter change and no longer triggers a pointless upload",
},
["1.10.0"] = {
    "CRITICAL: the in-app updater had never actually worked. It extracted the archive into the plugin's own directory instead of the plugins folder, so the new version landed one level too deep, the installed code never changed, and a full copy of the plugin was deposited inside itself on every attempt -- while it reported success every time",
    "CRITICAL: a failed update can no longer brick the plugin. Installation now unpacks into a staging folder, checks that every Lua file in it actually compiles, and only then swaps the whole folder into place. A corrupt download or a full disk used to leave a zero-byte or half-written module that stopped the plugin loading -- with the new version number already showing, so a later \"check for updates\" reported the broken install as up to date",
    "\"Background activity: OFF\" now actually stops the background sync. The switch was only consulted when deciding whether to install the startup hooks, so closing a book, suspending, opening a book, editing a note, resuming and the periodic flush all carried on making network requests while the message said \"the plugin now only runs when you ask it to",
    "The all-books trigger can no longer die silently for a session. If the scan found no books, or failed, the guard was never released, and every later app-start, open, close and resume all-books trigger did nothing at all with no message",
},
["1.9.3"] = {
    "CRITICAL: downloading could destroy the book you already had. With \"Re-download books that already exist locally\" switched on, the local file was deleted BEFORE the plugin checked whether the cloud was reachable, so any failure after that point -- offline, wrong password, unsupported provider -- lost your only copy and downloaded nothing. Downloads now go to a temporary file and only replace what is already there once the new copy is verified on disk",
    "A truncated download is no longer reported as \"Download successful\". A 200 response with a short body was shown as a green tick and counted as a pass by the batch, leaving a corrupt book in your library",
    "Cloud log upload does something now. It was calling the download function, which overwrote the log it had just prepared with the cloud copy and then deleted it, so \"Enable Cloud Sync Log\" silently did nothing in the upload direction and still reported success",
    "Browsing your cloud library no longer changes where your books are uploaded to. Navigating into a subfolder used to write the folder you were looking at into your settings as the configured Book Cloud Directory, with no confirmation",
    "The \"All auto sync disabled\" shortcut really disables everything. It turned off four switches and said so, while fourteen triggers -- every app-start, chapter, flush and open upload, and the whole upload-all and download-all family -- stayed armed",
},
["1.9.2"] = {
    "Long operations can be cancelled. The progress box is modal and had no buttons at all, so there was no way to dismiss it. That is survivable for a run you started yourself, and a trap for one you did not: closing a book or going to sleep can raise the same box, and if the network is slow you are left staring at a progress display you cannot get rid of",
    "Cancelling stops the remaining items, still reports the result so the summary is not lost, and lists what was not attempted instead of silently reporting fewer books than you asked for",
},
["1.9.1"] = {
    "The download progress bar now moves. It is sized in BYTES, but the step that accumulates bytes ignored the progress callback entirely, so it showed completed-books / total-bytes and sat near zero for the whole run. Progress is also reported as an absolute value now -- it used to be added on top of a per-item counter, so a step reporting bytes had them counted twice",
    "A book that was only partly downloaded is no longer stranded forever. Any non-empty leftover was assumed complete, so a transfer that died at 400 KB of a 3 MB book left a file that every later run refused to replace, with no way out except deleting it by hand. Leftovers shorter than the cloud's advertised size are re-fetched; when the server reports no size, the old conservative skip still applies",
    "Downloading metadata for a book you have never opened now works. It refused every such book and told you to open it first, which is exactly the action the feature exists to make unnecessary -- restoring your notes onto a book you just copied to the device",
    "After the plugin is reloaded, its automatic triggers talk to the current objects again. The hook markers live on KOReader's own tables, so they were never re-created, and every trigger kept calling the instance that had already been torn down: changing a setting in the reloaded plugin had no effect on syncing at all",
    "The \"all books\" guard is no longer released while its batch is still running, and the recorded sync time is now when the batch actually finished rather than when it was queued",
    "Writing a log entry no longer saves a setting. Logging ran on the close and suspend paths and would create and persist a device id as a side effect",
    "A batch step's result classifier and a failed task scheduling are both contained now, so neither can leave the progress dialog stuck on screen with the batch half done",
},
["1.9.0"] = {
    "CRITICAL: uploading metadata to WebDAV sent the header If-None-Match: * on every request. Under RFC 7232 a server must answer 412 when that header is present and the file already exists -- so the FIRST upload worked and every upload after it failed. Combined with the fix below, your cloud copy was frozen at whatever it held the first time",
    "CRITICAL: \"Download and overwrite\" no longer deletes your notes. It replaced the whole annotation list with the cloud copy, so any note the cloud did not have was destroyed, and it reported success while doing it. It now keeps every local note, unions them with the cloud, and only the reading position follows the cloud. Combined with the frozen cloud above, opening a book could have replaced 41 notes with 1",
    "Metadata files arriving from the cloud are no longer executed with full privileges. A corrupt, misconfigured or tampered file could call os.exit, delete files or run shell commands and the pcall would not have caught it, because those are ordinary calls -- it looked exactly like a reader crash. The data format is a plain table and needs no globals, so it is now loaded in an isolated environment",
    "A failed local write is no longer reported as a success. The result of writing the metadata file was discarded in seven places, so a full disk, a read-only mount or a settings error produced a green tick and no retry. All of them now propagate the failure and tell you what happened",
    "Opening a book can no longer be blocked by the plugin. Two settings reads and one settings write sat outside every error boundary, directly in front of KOReader's own open-book entry point, and the settings write re-encodes and rewrites the whole settings file to disk. A failure there meant the tap did nothing at all",
    "Duplicate BookSync rows in the gear menu are gone. The menu-order table belongs to KOReader core and is a shared singleton, and the entry was added again on every visit to the plugin menu",
    "A crash inside a batch step's result classifier no longer takes the app down or leaves the progress dialog stuck on screen forever; it is now recorded as that item's failure and the batch carries on",
    "The two scheduling helpers only protected the task, not the scheduling call itself -- the \"safe\" wrapper was in one case the thing that could crash the app. Both are contained now, and a sync guard can no longer stay stuck for the rest of the session if a task fails to be queued",
    "A path ending in a slash no longer crashes the upload path, a failed document parse is logged instead of silently uploading your book under its filename, the bookmark wrapper can no longer throw into the note-taking path, and the translation shim degrades to English instead of preventing the plugin from loading at all",
},
["1.8.10"] = {
    "Every metadata transfer now reports its real HTTP status, not \"Unknown error\". Six call sites were each handling 404, 401 and everything-else by hand; one of them had been fixed earlier and five had not, so the same failure looked different depending on which path it took. They all route through one mapping now",
    "403 and 405 are named as a path or permission problem, 507 as a full device, 413 as too large for the server, and any other status still shows its number, each with something to do about it",
},
["1.8.9"] = {
    "Fix: merging reading progress erased a good local value with nil. A sidecar written by an older KOReader carries last_xpointer but no percent_finished, while a newer one carries percent_finished and, for some formats, no xpointer. The cloud position was adopted with all three fields assigned unconditionally, so the exact reading position was lost and the book reopened somewhere arbitrary. Each field is now copied only when the cloud side actually has it",
    "The one-time rename migration is now guarded by the marker it was already writing, instead of re-running its body on every launch, and its indentation matches what it does",
    "16 more menu and error strings are translated; the Chinese UI no longer falls back to English for them",
},
["1.8.8"] = {
    "New: Settings > General > Background activity. Turning it on installs no automatic triggers at all -- nothing on start, nothing on open, close or suspend, nothing on returning to the library -- and only what you ask for from the menu runs. Menu actions and existing settings are untouched",
},
["1.8.7"] = {
    "Removed the cloud connection check that 1.8.5 added, and the HTTP-status plumbing that existed only to support it",
},
["1.8.6"] = {
    "Fix: transfers sent a malformed URL and the server answered 400 Bad Request. remote.get_cloud_path builds an absolute URL, and the WebDAV adapter treated it as a path relative to the server address, producing https://host/https%3A%2F%2Fhost%2F...%E4%B9%A6.epub. Listing kept working (it passes a relative path), which is why the connection check passed while every upload and download failed",
    "Fix: the same mistake on Dropbox doubled the folder in the path",
},
["1.8.5"] = {
    "New: Check cloud connection / Check book cloud connection. \"The cloud feels broken\" is unactionable because the same symptom covers no network, wrong credentials, a wrong folder, a dead server, and a download directory that exists but cannot be written. The check walks the real code path and stops at the first thing that is actually wrong",
    "A metadata transfer failure no longer reports Unknown error for every status: the real HTTP code now reaches the message, the same way it already did for book downloads",
},
["1.8.4"] = {
    "Fixed: the failure summary rendered as \"[Failurereason1]...\" in Chinese. It was building the line with string.format around a translated format string, and the Chinese catalogue uses positional %1 %2 %3; it now uses KOReader's template helper like the rest of the plugin",
    "A download failure no longer collapses into one opaque sentence: 403, 405, 507, 413 and 409 are now named as what they are (wrong path or credentials, device out of space, file too large, folder missing), and any other status still shows its number",
},
["1.8.3"] = {
    "A size mismatch between the cloud listing and the downloaded file no longer fails the download, and never deletes the file. Earlier versions removed books over a getcontentlength hint that servers and proxies do not always match",
    "Fixed: the skip-if-present check now distinguishes a real book from a 0-byte leftover, a path that was added in 1.8.0 but never actually reached",
    "New setting: Re-download books that already exist locally. Books left half-written by an earlier failed transfer are non-empty, so the batch was skipping them forever; this replaces them without hunting through the download folder",
},

}
