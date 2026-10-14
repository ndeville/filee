---
title: Filee - specification and build plan
status: phase 1 built, QA passed, in Nic's hands
version: 1.0
created: 2026-10-10
updated: 2026-10-10
owner: Nic
---

# Filee - specification and build plan

Filee is a native macOS file manager. It replaces Path Finder first, then Find Any File and Path Finder's Size Browser. Later versions may take a part of DaisyDisk.

The 3 design goals, in order:

1. **Security.** Filee reads the whole disk. It never leaks what it reads.
2. **Speed.** Launch, list, filter and search without a perceptible wait.
3. **Keyboard first.** Every action works without the mouse.

Low memory is a hard budget under all 3 (section 1.3).

Inputs (private notes, not in this repo): the fsearch architecture and security research, an analysis of how Nic used Path Finder, and 52 decisions taken in 3 rounds of questions. The decision numbers in this spec refer to them.

---

## 1. Technology

### 1.1 Decision

| Layer           | Choice                                                     | Why                                                    |
| -               | -                                                          | -                                                      |
| Language        | Swift 6.3, 1 toolchain                                     | Same as Notee. fsearch's data structures port well      |
| UI              | AppKit, frame-based layout                                 | Fastest, lightest UI layer. Notee's lessons apply       |
| Listing         | `getattrlistbulk(2)`, FileManager as fallback              | 100s of entries per syscall, no `stat` per file         |
| List view       | View-based `NSOutlineView`                                 | Tree list, lazy children, 10,000s of rows               |
| Column view     | Own Miller columns: 1 `NSTableView` per column             | Full control of widths and keys                         |
| Thumbnails      | `NSCollectionView` + `QLThumbnailGenerator`, bounded cache | Thumbnails only for visible items                       |
| Copy and move   | `copyfile(3)` with clone and a progress callback           | APFS clones are instant, big files show progress        |
| Archives        | `/usr/bin/ditto`                                           | Zip only (decision 26), system tool                     |
| Quick Look      | `QLPreviewPanel`                                           | System previews, no own renderers                       |
| File watching   | 1 FSEvents stream per visible folder                       | Kernel-level, near zero cost                            |
| Global hotkey   | Carbon `RegisterEventHotKey`                               | Needs no Accessibility permission                       |
| Config          | JSON (comments allowed) in `~/.filee/`                     | Nic and Claude edit them, Filee reloads them live       |
| Shared logic    | Swift package `FileeCore`, no AppKit, unit tested          | Listing, operations, rename planner, keymap, fuzzy      |

Notee's code (fuzzy matcher, key chords, FSEvents hub, JSONC) is copied, not shared. The 2 apps stay independent (decision 38).

### 1.2 Process model

- Phase 1: 1 process. No helper, no socket, no index.
- Phase 2: the search engine runs inside the app for queries. A login item helper (`SMAppService`) keeps the index live while Filee is closed. App and helper talk over XPC with a code-signing requirement on both ends. No Unix socket.
- Phase 2: a `filee` CLI for name search only, allowed only for signed clients (decision 36).

### 1.3 Budgets

Path Finder today: 305 MB footprint, 486 MB resident (measured 10th October 2026). Finder: 141 MB.

| Metric                                           | Budget            |
| -                                                | -                 |
| Cold launch to a usable window                   | < 300 ms          |
| List a 10,000-file folder                        | < 150 ms          |
| Filter keystroke to screen, 10,000 files         | < 16 ms           |
| Memory footprint at idle, 2 panes, 4 tabs        | < 120 MB          |
| Thumbnail cache                                  | ≤ 40 MB, evicted  |
| Phase 2 helper at idle, index mapped             | < 150 MB          |
| Phase 2 name query, whole disk                   | p50 < 5 ms        |

`qa.py` measures every budget. A phase doesn't ship if it breaks one.

---

## 2. Phases

| Phase | Content                                                                                   | Exit                              |
| -     | -                                                                                         | -                                 |
| 1     | Browser, views, keyboard, file operations, rename, zip, actions, drop stack, "new today"  | Nic uses Filee instead of Path Finder |
| 1.5   | Folder size view (Size Browser), Get Info details, default file viewer switch             | Path Finder cancelled             |
| 2     | Whole-disk name index, query language, search results as a folder, helper, CLI            | Find Any File retired             |
| 3     | Content index: text and code, then Office and PDF text, behind the deny-list              | Budgets met with the index live   |
| Later | DaisyDisk-style disk map, native rules engine (decision 49: revisit)                      | -                                 |

Switch-over (decision 42): Filee runs next to Path Finder. Path Finder is cancelled after 2 weeks as the default viewer without a fallback.

---

## 3. Window and layout

```
+--------------------------------------------------------------------------------+
| ● ● ●  ✿ Filee              ~/Dropbox/Work/clients                             |
+--------+-----------------------------------+-----------------------------------+
|Sidebar | [tab] [tab] [+]                   | [tab] [+]                         |
|        | ~/Dropbox/Work/clients       (path)| ~/code/output                     |
|Favour. |===================================|-----------------------------------|
|Volumes | Name            Size  Modified Kind| Name            Size  Modified    |
|Recent  | > abb            -    2 days   Fold| ...                               |
|        |   ...                              |                                   |
|Drop    |                                    |                                   |
|stack   | filter: roadmap  (3 of 412)        |                                   |
+--------+-----------------------------------+-----------------------------------+
| 3 items selected, 12.4 MB    |  Copying 2 of 9 - 1.2 GB of 4.0 GB  |  412 GB free |
+--------------------------------------------------------------------------------+
```

- **Sidebar logos**: a folder with a `.filee-icon.svg` or `.png` inside shows that image; Dropbox shows the Dropbox logo.
- **Title bar**: a tall red strip in the app icon's gradient (darker in dark mode): the app icon and "Filee" in white right of the traffic lights, the active pane's folder in the centre. An empty unified toolbar gives it its height. The window's own title is hidden; the strip still moves the window and zooms it on a double-click.
- 1 window. 2 panes side by side; ⌘1 shows 1 pane, ⌘2 shows 2 (decisions 5 and 43). ⌘N opens a second window.
- Each pane has its own tabs, path bar, view and history.
- **Active pane** (decision 11): a 3 px red accent bar across the top of the active pane, and its path in bold. The inactive pane is dimmed to 85%. Tab switches the active pane.
- **Path bar** (decision 13): the folder path as clickable folders, from the home folder down (outside home: from the volume or Macintosh HD). It uses the file list's font and size, as the tab names do, and grows with ⌘+. The current folder is highlighted like a selected row (red in the active pane, grey in the other) and red arrows separate the folders. A click on a folder goes there and selects the folder you came from. A drop on a folder moves or copies into it (Finder's rules: move on the same volume, copy across volumes, ⌥ copies). Folders that don't fit fold into `…`, a menu. 1 view draws the whole path: no disk access, a new layout only when the path or the width changes (under 1 ms). A click on the current folder or the free space after it, ⌘L or ⌃G makes it editable with all of it selected, ready for a paste, with Tab completion. Enter goes there; a file path goes to its folder and selects the file. A pasted path can carry quotes, `file://` or shell escapes. The copy button right of the folder in the title bar copies the active pane's full path (from `/`).
- **File-type filter**: right of each pane's tabs, All, then 1 button per family: PDF, PowerPoint, Word, Excel (with CSV), Markdown, video, images. Each button shows the icon of the app that opens the family on this Mac (Word, Excel, Notee); when 2 families share an app (PDF and images in Preview), the later one takes an installed fallback (Photos), so no 2 buttons look the same. A click shows only that family in the active tab, a 2nd click (or All) shows everything again. Folders always show. The filter stays with the tab from folder to folder, applies to every view and to expanded folders in the list, and shows in the item count ("PDF · 3 items"). New tabs and launches start with All. Also in **View** and ⌘K ("Show Only PDF Files"). Hidden in a pane narrower than 420 px.
- **Status bar**: selection count and size, free space on the volume.
- **Messages** (copied path, moved to Trash, errors): a pill at the bottom centre of the window, in large type with inverted colours (black in light mode, white in dark mode, red for errors). A copied path shows in full on a second line. It goes after 2.5 s, errors after 6 s.
- **Copy and move progress**: a panel above the status bar, 1 row per running copy or move: item `n of m` and its name, a red progress bar, bytes done of total, speed, time left, and a cancel button. The finished row turns green at 100% and goes after 2 s (5 s for an error).
- **Look** (decision 14): NicAI Design. Black, white, red accent, Lato for the interface. Light and dark follow macOS until you switch: ⌃⌘L, the moon or sun button at the right of the title bar, the half-circle button at the right of the status bar, or **View > Switch Light or Dark Theme** pins the other theme; **View > Use System Theme** follows macOS again. The choice is kept in `state.json`. The bar over the active pane is red in light and white in dark.
- **App icon**: a white folder with the NicAI edelweiss in red, on the red body (`assets/AppIcon.svg`, Nic's pick on 10th October 2026: concept 7). The red plate fills the whole canvas, like every Nic app icon since 12th October 2026. From 128 px up, the name "Filee" sits under the folder in Lato Black, the same font, size and position as the name in Notee's icon. Every Nic app icon carries his logo.
- **Font** (decision 10): the file list font and size live in `settings.json`. Default: SF Pro 13 pt. Folders bold, aliases and symlinks italic, extensions always shown (as in Path Finder today).
- Window frame, panes, tabs and views come back at launch.

### 3.1 Views

| Key | View       | Notes                                                                         |
| -   | -          | -                                                                             |
| ⌘3  | Thumbnails | Grid, thumbnail size 64-384 px with ⌘+ and ⌘-, per folder                     |
| ⌘4  | Columns    | Miller columns. → enters a folder, ← goes back. Each column fits its content  |
| ⌘5  | List       | Tree list: → expands a folder in place, ← collapses (decision 7). ⌥⌘→ expands all folders 1 level per press, ⌥⌘← collapses all |

- The view is remembered per folder. A folder with no saved view uses the default (list).
- Folders where Path Finder used icon view (image folders) open in thumbnails on first visit if more than half the items are images.

### 3.2 List columns (decision 8)

Visible by default: name, size, modified, kind. Available: date added, created, extension, items (folder entry count). A right-click on the header shows or hides a column. Dates are relative under 7 days ("today 14:05", "yesterday", "3 days ago"), else `2026-10-08 14:05`. Sizes use base 2 (as Path Finder today), shown as "KB/MB/GB".

### 3.3 Auto-size (decision 9)

Every column fits its content, every time the folder loads or changes. The name column fits the longest name, up to the space left by the other columns. Nothing is stored per folder. Dragging a column edge is allowed but lasts only until the next folder.

### 3.4 "New today" marker (decision 50)

A file or folder added to its folder today shows a red dot before its name. "Today" starts at 00:00 local time; at midnight every pane refreshes, so the markers reset each day. Date added comes from the file system (`ATTR_CMN_ADDEDTIME`), with the creation date as fallback. Nothing is written to disk. Nic turns off the 2 Hazel red-tag rules.

---

## 4. Keyboard

### 4.1 Rules

- The keymap sees every key before the views and menus (as in Notee).
- **Typing filters** (decision 17): a letter or digit starts a fuzzy filter on the current folder. Esc clears it. ↑↓ move in the filtered list. Enter opens. A bar at the top of the list shows the typed text in large bold type with a blinking red caret, the match count and the keys (Esc, ⌫). Spaces show as `·`.
- Copy (⌘D) and Paste (⌘F) come from Nic's global App Shortcuts, which act on the **Edit > Copy** and **Edit > Paste** menu items. Filee keeps those 2 menu titles and binds nothing else to ⌘D or ⌘F. Hammerspoon's `editKeysTap` presses the same menu items.
- `~/.filee/keybindings.json` applies on top of the defaults, in VS Code's format. `"-command"` removes a default key.
- Folder jumps use the ⌘J prefix: `⌘J K`, `⌘J A`. A plain `g` prefix can't work, because letters start the filter.

### 4.2 Default keymap

Path Finder keys are kept wherever Nic set one (decision 15).

| Key        | Command                                | Key        | Command                               |
| -          | -                                      | -          | -                                     |
| ↩ / ⌘O     | Open (folder: enter, file: default app) | ⌘↑ / ⌘↓    | Enclosing folder / last item          |
| ⌘[ / ⌘]    | Back / forward                         | Tab        | Switch active pane                    |
| ⌘L / ⌘G / ⌃G | Edit path / go to folder             | ⌘K         | Command palette                       |
| ⌘H         | Home                                   | ⌥⌘D        | Downloads                             |
| ⌘J D / ⌘J H | Jumps: Downloads / Home (`jumps`)     |            |                                       |
| ⌘1 / ⌘2    | Single pane / dual pane                | ⌘3 ⌘4 ⌘5   | Thumbnails / columns / list           |
| ⌘T / ⌘W    | New tab / close tab                    | ⇧⌘] / ⇧⌘[  | Next / previous tab                   |
| ⌘D / ⌘X / ⌘F | Copy / cut / paste (menu)            | ⇧⌘D        | Copy path                             |
| F5 / F6    | Copy / move to the other pane          | ⌘R         | Rename (1 item) / batch rename (more) |
| ⇧⌘N        | New folder, next to the selected item  | ⌥⌘N        | New text file                         |
| ⌘⌫         | Move to Trash                          | ⇧⌘⌫        | Empty Trash (confirm)                 |
| ⌘Z / ⇧⌘Z   | Undo / redo                            | ⌘E         | Eject volume                          |
| Space      | Quick Look                             | ⌃⌘I        | Get Info                              |
| ⇧⌘I        | Show invisible files                   | ⇧⌘R        | Reload                                |
| ⌥⌘F / ⇧⌥⌘F | Keyboard to Favourites / Volumes       | ⌥⌘R        | Reveal in Finder                      |
| ⌃⌘T        | Open Ghostty here                      | ⌃⌘D        | Add selection to drop stack           |
| ⌃⌘S        | Calculate folder sizes                 | ⌃⌘C        | Compress to zip                       |
| ⌘A         | Select all                             | ⌘,         | Settings                              |
| ⌘+ / ⌘-    | Zoom files, tab names, type icons      | ⌘0         | Default size (`fontSize`, 14 pt)      |
| ⌃⌥⌘F       | Bring Filee to the front (global)      | ⌃⌘L        | Switch light or dark theme            |
| F1         | Toggle single or dual pane (Fn+= on the Kinesis, as in Path Finder) | ⇧⌘F | Add or remove the selection's folder in Favourites |
| ⌥⌘→ / ⌥⌘←  | Expand all / collapse all (tree list)  |            |                                       |

Vim keys (`hjkl`) are off and available as a setting (decision 19).

### 4.3 Command palette

⌘K opens 1 box over the window. It matches, fuzzy, in this order: commands (with their key), custom actions, favourites and jumps, recent folders, items in the current folder. Enter runs the top hit. Esc (from the field or the list), ⌘K, ⌘W, ⌘. or a click outside the palette closes it: the palette never stays open without the keyboard.

---

## 5. File operations

### 5.1 Rules

- Every operation runs off the main thread. The status bar shows progress; Esc on the status bar or the palette command "Cancel operation" stops it between files.
- Copy uses `copyfile` with `COPYFILE_CLONE`: an instant clone on the same APFS volume, a real copy elsewhere, progress in bytes.
- A move on the same volume is a rename. A move across volumes is a copy, then a delete of the source only when the copy succeeded.
- Name conflicts: a sheet asks Replace, Keep both ("name 2.ext") or Skip, with "apply to all".
- No copy verification in phase 1 (decision 23: parked).
- Trash only (decision 27). No permanent delete. ⇧⌘⌫ empties the Trash after a confirmation.
- Undo (decision 24): rename, move, trash (put back), new folder and copy (the copy goes to the Trash). ⌘Z and ⇧⌘Z, 50 steps, for the session.
- Copy and paste: ⌘D puts the selected files on the pasteboard (with their paths as text, for other apps). ⌘F pastes files into the active folder. ⌘X marks them, then ⌘F moves them.
- F5 and F6 copy or move the selection to the other pane's folder. With 1 pane shown, they ask for a folder in the palette.
- Drag and drop: between panes, to and from other apps, to the drop stack. ⌥ forces copy, ⌘ forces move.

### 5.2 Batch rename (decisions 25, 45, 46)

⌘R with more than 1 item selected opens the rename sheet. The preview shows old and new names live; a conflict shows in red and blocks the rename.

| Mode            | Effect                                                                                       |
| -               | -                                                                                            |
| Sequence        | 1 base name for all: `261008-world-summit-ai` gives `261008-world-summit-ai_01.jpg`, `_02` ... |
| Find and replace | Plain text or regex, case sensitive or not                                                   |
| Prefix date     | Insert `YYMMDD-` from the capture date                                                       |
| Slugify         | Lower case, accents removed, spaces and `_` to `-`                                           |
| Case            | lower, UPPER, Title                                                                          |

Sequence rules:

- Numbers follow the pane's current sort order and start at `_01`.
- The width follows the count: 2 digits up to 99 files, 3 up to 999, and so on.
- Extensions stay as they are.
- 1 selected file gets no number.
- `YYMMDD` in the base name is replaced with each file's capture date: EXIF `DateTimeOriginal` for photos, else the creation date. A typed date stays as typed.

Renames run in 2 steps through temporary names, so swaps (`a`→`b`, `b`→`a`) work. 1 undo step reverts the whole batch.

### 5.3 Archives (decision 26)

Zip only, through `ditto`. ⌃⌘C compresses the selection to `<name>.zip` (1 item) or `Archive.zip` (several), next to the items. "Extract here" (palette, context menu) unpacks into a folder named after the zip.

### 5.4 Custom actions (decisions 28, 47, 48)

`~/.filee/actions.json` lists actions. Each one shows in the palette and the context menu, and can have a key.

```json
{
  "name": "Optimise image (1920 px)",
  "command": ["~/scripts/venv/bin/python", "~/scripts/resize_image.py", "{path}"],
  "extensions": ["jpg", "jpeg", "png", "heic", "webp"],
  "mode": "background",
  "each": true,
  "key": null
}
```

- `{path}` is 1 selected path, `{paths}` all of them, `{dir}` the current folder, `{name}` and `{stem}` the name parts.
- `each: true` runs the command once per file, 2 at a time.
- Filee also puts the selected paths on the clipboard before it runs an action, 1 per line, because Nic's older scripts read the clipboard.
- `mode: background` runs without a window, shows ✅ or ❌ in the status bar, writes the output to `~/.filee/logs/actions.log` and refreshes the folder. `mode: terminal` opens the command in Ghostty, for scripts that ask questions.
- The command runs directly, never through a shell, unless the action says `"shell": true`.
- Filee never runs an action on its own. Every run starts from a key, the palette or a menu.

Default actions at first launch, as examples: open in TextEdit, compare 2 files (`opendiff`), SHA-256 checksum, make executable. Nic's own actions (uploads, transcription, image scripts, recorder import) live in his `~/.filee/actions.json`.

### 5.5 Other file features

- Get Info (⌃⌘I): path, size (folders computed), item count, dates (created, modified, added), kind, image dimensions, media duration. A panel, not a window per file.
- Folder sizes (⌃⌘S): computes the size of every folder in the listing in the background and fills the size column. Cached until the folder changes.
- Open in: Ghostty at the folder (⌃⌘T), Notee for `.md`, CotEditor for text, default app otherwise.
- Copy path variants in the palette: full path, `~` path, name, Markdown link.

---

## 6. Sidebar and drop stack

Sidebar sections (decision 12):

- **Favourites** from `settings.json`. Default: Home (by its own name), Desktop, Documents, Downloads, Applications. ⇧⌘F (**Go > Add or Remove Folder in Favourites**) adds the folder that holds the selection, or removes it when it's already there; a message says which. Dragging a folder to the section adds it too.
  - The favourites show as a tree from the root: each favourite sits under the closest favourite that contains it (Clients under Work, Work under Home). A folder that holds 2 or more favourites without being one shows as a grey branch (`Dropbox`); a chain of them shows as 1 row (`Dropbox/Work`, or `…/T/filee-qa` past 2 folders). Siblings sort by path.
  - A chevron folds and unfolds a favourite. The folded ones are kept in `state.json`.
  - A folder with a `.filee-icon.svg` or `.filee-icon.png` inside shows that image: the icon syncs with the folder (Dropbox, git). A folder named Dropbox shows the Dropbox logo (the app's icon). Another folder with its own Finder icon (a shared Dropbox folder) shows that icon. A grey branch keeps a logo in full colour. Folders under `/Volumes` keep the plain icon: network shares can be slow.
- **Keyboard**: ⌥⌘F moves the keyboard to Favourites, ⇧⌥⌘F to Volumes (both in ⌘K and the Go menu). The row of the current folder is selected, else the first row. ↑↓ move, ←→ fold and unfold, ↩ opens the row in the active pane and gives the keyboard back, Esc or Tab goes back without opening.
- **Volumes**: every mounted volume, with free space (none for network shares, which report 0) and an eject button on everything under `/Volumes`. ⌘E ejects the selected volume.
  - Each volume has its own icon: a word in its name picks the symbol (vid: film, mus: music note, scan, doc, backup, photo, personal), else its kind (network share, external, internal). Each gets its own colour, the same from launch to launch. `volumeIcons` in `settings.json` sets a symbol or an image file by volume name: `{"Omarchy": "terminal", "Sony": "~/.filee/icons/sony.png"}`. An image file also applies to every volume whose name contains the key ("Sony" matches "SONY ICD").
- **Recent**: the last 10 folders visited.
- **Drop stack**: a holding list. ⌃⌘D adds the selection. Drag items out, or use the palette: "Copy stack here", "Move stack here", "Clear stack". The stack survives a restart.

The sidebar toggles with ⌘B. Drag its right edge to change its width (160-480 px, default 260, kept in `state.json`). `sidebarFontSize` in `settings.json` sets its text size (default 14 pt); rows and icons scale with it.

---

## 7. Search (phases 2 and 3)

The engine follows fsearch's architecture, rewritten in Swift, with the security model of section 7.2.

### 7.1 Scope

- Name index (decision 31): the startup disk and USB disks. NAS shares only when Nic adds them. Firmlinks crossed, mount points not.
- Content index (decisions 32, 33): text and code under `$HOME`, Dropbox in, iCloud Drive out. Phase 3 adds Office and PDF text under `~/Dropbox` and `~/ai`.
- iCloud placeholders are never downloaded (`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` off).

### 7.2 Security requirements

| # | Requirement                                                                                                         |
| - | -                                                                                                                   |
| 1 | Deny-list before any content read: `.env*`, `*.pem`, `*.key`, `*.p12`, `id_*`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`, keychains, browser databases. User rules on top |
| 2 | No socket. XPC with code-signing requirements both ways. The CLI is a signed client                                  |
| 3 | Every length and offset in an index file is checked against the file size at load. Header checksum. Rebuild on failure |
| 4 | Index files `0600`, folder `0700`                                                                                    |
| 5 | Query text and results are never logged                                                                             |
| 6 | Tests from day 1                                                                                                    |
| 7 | Developer ID signing, hardened runtime, stable bundle id                                                            |

### 7.3 Results

Results show in the active pane as a virtual folder (decision 34). Every file action works on them. The query language follows fsearch: fuzzy by default, `'exact`, `^prefix`, `suffix$`, `!exclude`, and the filters `ext:` `type:` `in:` `size:` `mtime:` `re:` `path:`.

---

## 8. Configuration

`~/.filee/` (`FILEE_HOME` moves it), folder `0700`:

| File               | Content                                                            | Reload |
| -                  | -                                                                  | -      |
| `settings.json`    | Fonts, favourites, jumps, show invisibles, vim keys, default view  | Live   |
| `keybindings.json` | Key overrides, VS Code format                                      | Live   |
| `actions.json`     | Custom actions                                                     | Live   |
| `state.json`       | Window frame, panes, tabs, views per folder, recent folders, stack | -      |
| `logs/actions.log` | Output of background actions                                       | -      |

---

## 9. Quality

- `FileeCore` unit tests: listing against FileManager, rename planner (sequence, dates, conflicts, swaps), conflict names, copy and move with progress, undo, zip round trip, keymap parser, fuzzy filter, action command expansion.
- `qa.py` drives the built app with scripted steps (`FILEE_QA`) on fixture folders in `$TMPDIR/filee-qa`. It never touches real folders. Each suite writes a report and screenshots.
- `qa.py --budgets` measures launch, listing, filter and memory against section 1.3.
- `FILEE_READONLY=1` blocks every write: for any run against real folders.

---

## 10. Build and release

- XcodeGen project (`project.yml`), `./build.sh` builds, `./build.sh --install` copies to `/Applications/Filee.app`.
- Bundle id `com.nicolasdeville.filee`. Signed with the identity in `FILEE_SIGN_IDENTITY` (or `.private/signing.env`, git-ignored), hardened runtime, so macOS permission grants survive rebuilds. Without one, `build.sh` signs ad hoc.
- Notarisation: needs a `notarytool` keychain profile (open item 1). Not needed to run locally built builds.
- Repo: `github.com/ndeville/filee`, MIT licence. Every change is pushed.

---

## 11. Open items

| # | Item                                                                                                     |
| - | -                                                                                                        |
| 1 | Notarisation profile: Nic runs `xcrun notarytool store-credentials filee` once (Apple ID app password)   |
| 2 | Hazel: Nic turns off the 2 red-tag rules (Downloads, Dropbox) once "new today" works for him             |
| 3 | Done 13th October 2026: `NSFileViewer` is Filee, and Hammerspoon moves new Finder windows to Filee (README) |
| 4 | Hazel clean-up of 9 unused folders (decision 52), by Nic                                                 |

---

## 12. Build status (10th October 2026)

Phase 1 is built, signed and installed at `/Applications/Filee.app`.

### 12.1 Measured against the budgets

| Metric                                      | Budget   | Measured                     |
| -                                           | -        | -                            |
| Cold launch to a usable window              | < 300 ms | 140-220 ms                   |
| List a 10,000-file folder                   | < 150 ms | 66-83 ms (11 ms system calls) |
| Filter keystroke, 10,000 files              | < 16 ms  | 7-8 ms                       |
| Footprint idle, 2 panes, 5 tabs             | < 120 MB | 72 MB                        |
| Footprint after a 21,361-file folder, idle  | -        | about 112 MB (peak 190 MB)   |

### 12.2 QA

`swift test`: 23 unit tests. `qa.py`: 5 suites, 51 checks on the real app (browse, filter, ops, rename, budgets), all passing. They cover the 3 views, panes, tabs, history, jumps, invisible files, the filter, copy and move between panes, conflicts, undo and redo, Trash and put back, new folder, zip and extract, duplicate, Edit menu copy, cut and paste, the drop stack, custom actions (from a key, and an external program with the path argument), sequence rename with dates, inline rename, auto-sized columns and image folders opening as thumbnails.

Not covered by automated QA, to check by hand: drag and drop, Quick Look, the command palette's results, Get Info, eject, Empty Trash, the global hotkey, and terminal actions in Ghostty.

### 12.3 Not built yet

- Phase 1.5: Size Browser view, default file viewer switch.
- Phases 2 and 3: search.
- A draggable divider between the panes.
