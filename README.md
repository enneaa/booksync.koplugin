[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![KOReader](https://img.shields.io/badge/KOReader-plugin-8C3BFF?logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTkyIj48cmVjdCB3aWR0aD0iMTkyIiBoZWlnaHQ9IjE5MiIgcng9IjMyIiBmaWxsPSIjOGMzYmZmIi8+PHRleHQgeD0iOTYiIHk9IjEyMCIgZm9udC1mYW1pbHk9IkFyaWFsIiBmb250LXdlaWdodD0iYm9sZCIgZm9udC1zaXplPSI5NiIgZmlsbD0id2hpdGUiIHRleHQtYW5jaG9yPSJtaWRkbGUiPuKAkjwvdGV4dD48L3N2Zz4=)](https://koreader.rocks/)

# BookSync

> A KOReader plugin that syncs books and metadata (annotations, reading progress, etc.) between devices via your own cloud storage.

[简体中文](README.zh_CN.md)

## Table of Contents

- [Introduction](#introduction)
- [How Sync Works](#how-sync-works)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Cloud Naming Rules](#cloud-naming-rules)
- [Metadata Sync](#metadata-sync)
- [Book Sync](#book-sync)
- [Batch Sync](#batch-sync)
- [Automatic Sync (Metadata Only)](#automatic-sync-metadata-only)
- [Additional JSON Backup](#additional-json-backup)
- [Sync Log](#sync-log)
- [Gesture Shortcuts](#gesture-shortcuts)
- [Changelog](#changelog)
- [Contributing](#contributing)
- [Repository](#repository)

## Introduction

BookSync is a KOReader plugin — "Cloud Library" — that synchronizes books and metadata (book annotations, reading progress, etc.) between devices.

## How Sync Works

1. The plugin operates directly on the device's original metadata files. By uploading / downloading / updating metadata files, it achieves a one-time sync of book information such as annotations and reading progress.
2. It also supports batch upload / download of the books themselves, enabling a complete library sync.

## Installation

Download and extract the release ZIP, then place the `booksync.koplugin` folder into the `koreader/plugins` directory on your device.

> Releases are available from the [releases page](https://github.com/enneaa/booksync.koplugin/releases). The plugin no longer ships an in-app updater, so update by replacing the plugin folder from a release ZIP.

## Getting Started

**Prerequisites**

1. In the file browser, go to **Menu → Tools → Cloud Storage** and add a cloud storage account.
2. Plugin setup: **Menu → Tools → Cloud Library → Settings**, then select a cloud directory to store metadata files, book files, and sync log files.
   - The book cloud directory defaults to the metadata cloud directory; you can optionally select an independent one.
   - Different devices **must use the same cloud directory**, otherwise they cannot share.
3. The local book metadata folder setting should be consistent across devices (**Settings → Documents → Book Metadata Folder**). It is usually consistent by default, but if changed on one device, change it on the others too — otherwise the plugin may report that the local metadata file cannot be found.

## Cloud Naming Rules

- Metadata is stored as `Title_Author`.
- A book file keeps the name it already has on the device.
- Note: keep the naming rules consistent across devices.

## Metadata Sync

**Upload Backup** — Uploads the local metadata file (`.lua`) for a book to the cloud. If a file with the same name already exists in the cloud, it is overwritten directly.

**Download Update** — Merges unique and updated information from the cloud into local data. There is only one mode: **local annotations are never replaced by the cloud copy**.

- **Annotations**: keep all annotations from both local and cloud (highlights, underlines, bookmarks, notes, etc.), merge, update, deduplicate, and sort them.
- **Reading Status**: take the higher priority — Finished Reading > Reading > Unread.
- **Reading Progress**: take the further value (farthest progress).
- **Reading Statistics**: highlight and note counts are recalculated from the merged results.
- **Document Settings**: keep local settings.

## Book Sync

- Upload: if a file with the same name already exists in the cloud, it is overwritten directly.
- Download: if a file with the same name already exists locally, it is skipped (details can be viewed in the sync log). To force a download, delete or rename the local file first.

## Batch Sync

1. **Manual**: In the file manager, enter selection mode → check the books to sync → tap **Menu → Tools → Cloud Library → Metadata Sync / Book Sync**.
2. **Gesture shortcut**: after setting a gesture shortcut, enter selection mode directly via gesture, check the books, then execute upload / download again via gesture.

## Automatic Sync (Metadata Only)

> Only applies to the currently open book.

1. Disabled by default. Enable the corresponding mode by checking the specific options below.
2. **Auto upload backup**: automatically upload metadata to overwrite the cloud when editing annotations, closing a book, or when the device goes to sleep. (Multiple triggers can be enabled at the same time, but it is not recommended. Choose either closing the book or device sleep.)
3. **Auto download update**: automatically download metadata from the cloud when opening a book, merged into local data.
4. **Auto Sync Exclude Directories** (v1.4.3): books in specified directories will not be included in auto sync (multiple directories can be added or removed).

**Notes**

- Auto sync only syncs the metadata of the book at the triggered moment, not all books continuously.
  Example: if "Auto upload on close" is enabled, whenever a book is closed the device automatically uploads that book's metadata, overwriting the same-named metadata file in the cloud directory.
- When using this plugin for the first time, please **manually batch upload** the local metadata from your current device to the cloud before enabling auto sync.
- Downloads always merge, so annotations made on one device are never lost on another.
- Make sure your device is connected to the internet, otherwise auto sync will not work.

## Additional JSON Backup

When enabled, an additional JSON file converted from the original metadata file is uploaded alongside it. The JSON format is not a standard file for KOReader book metadata synchronization across devices; it is intended for users who want to further organize their KOReader annotations. Enable as needed.

## Sync Log

1. A sync log is generated for each sync operation and can be used to troubleshoot failures.
2. Enable **Record Cloud Sync** and the sync logs will be automatically synced to the cloud, so you can view logs from different devices. (To minimize performance impact, enable only when needed.)
3. You can clear local and cloud sync logs via the **Clear** button in the sync log view and **Menu → Tools → Cloud Library → Settings → Clear Cloud Sync Log** respectively.

> **Note:** Because this plugin directly manipulates the device's existing metadata files, if there is no local metadata file (e.g. for a book that has never been opened), it will prompt a sync failure indicating that the local metadata file was not found. In that case, open the book first and then perform the sync.

## Gesture Shortcuts

- Enter **Settings → Gestures → Gesture Manager** from the reading interface and the file browser interface respectively. Select a gesture and check the corresponding Cloud Library menu items in the Reader and File Manager.
- One-gesture download / batch download (smart mode).
- Settings are reached from the plugin menu (**Menu → Tools → BookSync → More Settings**).
- **Worry-Free Sync Mode**: one gesture to enable / disable automatic metadata sync (auto upload backup when closing a book / device sleeping; auto download and merge update when opening a book).

## Changelog

BookSync is the renamed successor to MetadataSync (v0.22). Notable changes by version:

### v1.47
- The automatic all-books download now starts 1 second after launch instead of 3.

### v1.46
- When KOReader keeps its metadata in a central folder, an all-books scan that came back empty now retries against the book directory.

### v1.45
- An automatic all-books sync now says when it starts, not only when it finishes.
- A failed scan, a crash and a sync that could not start are now reported on screen instead of only in the log file.

### v1.44
- The all-books scan no longer freezes the screen; it now works in small steps and hands the screen back to KOReader in between.

### v1.42
- An automatic all-books run now reports what it did (the progress dialog is suppressed for background runs).

### v1.40
- Fixed "On app start" properly — the plugin was installing itself too late to see the startup it was waiting for.

### v1.39
- Fixed the dead "current folder" lookup in the manual all-books scan.

### v1.38
- Fixed "On app start: download metadata for ALL books".
- Fixed the "current folder" fallback when deciding what to scan.
- An all-books run that has nowhere to scan now says so instead of returning in silence.
- Moved "Last sync" to the bottom of the BookSync menu as a footer.

### v1.37
- Fixed the long-press menu hanging (registration now happens when the browser is created, with no polling).
- Moved "Last sync" to the top of the BookSync menu.

### v1.36
- Turning "Buttons in the long-press menu" back on now takes effect right away.

### v1.35
- Fixed the long-press menu hanging on opening (entries are now one per row).
- Shortened the long-press menu labels.

### v1.34
- New setting: turn the long-press menu entries on or off.

### v1.33
- Fixed the long-press menu on a book not always closing.
- Opening the plugin menu no longer leaves a background timer behind.

### v1.32
- Faster book downloads (one stat call instead of up to three).
- Faster book opening when auto-download is on (log cap reduced to 128 KB).
- Page turns no longer look up the current page number when auto-upload-on-chapter is off.

### v1.31
- Fixed the file browser switching into selection mode on its own.
- Post-batch cleanup no longer rebuilds the file list twice.

### v1.30
- Restored the built-in cloud storage picker.
- The cloud book list now remembers how you sorted it.

### v1.29
- Rewrote sync notifications to be shorter and clearer.
- Removed the "Merge" label from download notifications.
- Fixed "Sync failed" notifications giving no reason.

### v1.13.x
- Removed the in-app self-updater (update from release ZIPs).
- The plugin no longer runs any external command.

### v1.12.x
- Fixed cloud naming: metadata is stored as `Title_Author`; book files keep their on-device name.
- Removed the four naming settings.

### v1.11.x
- Uploads no longer overwrite what another device saved in between (uses the file's ETag for conditional uploads).
- Leftover temporary files (`.part`, `.conflict`) clean themselves up after a day.
- Background auto-sync runs no longer show a modal progress box.

### v1.10.x
- Fixed several triggers that did not actually fire (settings flush, resume, chapter change).

### v1.9.x (critical fixes)
- Fixed WebDAV uploads failing after the first one (`If-None-Match: *`).
- Fixed "Download and overwrite" deleting local notes.
- Metadata files from the cloud are now loaded in an isolated environment (no code execution).
- Downloads now go to a temporary file and replace the existing one only after verification.

### v1.8.x
- Downloads are no longer accepted on HTTP 200 alone (empty files are reported as failures).
- Added cancellation for long operations.
- Added "Background activity" global setting.

### v1.7.x
- Renamed the plugin to **BookSync** and the install folder to `booksync.koplugin`. Settings are migrated on first launch.

### v1.6.0
- Renamed display name to "Cloud Library Sync".
- Added "On app start" trigger.

### v1.5.0-crashfix
- Cloud API calls are now error-boundary protected.
- Fixed several crashes (apply metadata, hook stacking, progress dialog).

### v1.4.5
- Integrate with Bookshelf plugin.
- Fix garbled text when truncating Chinese folder paths.
- Repaint the progress bar once a second on non-touch Kindles.

### v1.4.4
- Quick folder navigation in the cloud book dialog.
- Auto WiFi prompt and retry.
- Display release notes when a new version is found.

### v1.4.3
- Auto Sync Exclude Directories.
- Unified gesture registration.

### v1.4.2
- Support all KOReader formats in book validation.
- Non-touch navigation for the cloud book dialog.

### v1.4.1
- Added `changelog.lua` to track version history.
- Optimized plugin module loading path.

### v1.4
- English support with Chinese translation.
- Progress bar for upload / download.
- Three update source options (GitHub Latest / Pre-release, Gitee Latest).

### v1.3
- Pre-flight checks for network and configuration.
- Worry-Free Sync Mode quick toggle.

### v1.2
- Support for an independent book cloud directory.

### v1.1
- Fixed online update crash on Android.

### v1.0
- Added book sync (batch upload / download / delete).
- Added gesture shortcuts.
- Fixed PDF merge crash and annotation rendering issues.
- Added cloud sync log clearing.
- Added online update feature.
- Optional overwrite for document settings.

## Contributing

1. Fork this repository
2. Create a new `Feat_xxx` branch
3. Commit your code
4. Create a Pull Request

## Repository

- GitHub: https://github.com/enneaa/booksync.koplugin
