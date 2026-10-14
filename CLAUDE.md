# CLAUDE.md - Filee

Filee is Nic's native macOS file manager: it replaces Path Finder. `SPEC.md` is the source of truth for what it does and why. Read it before you change behaviour.

The repo is public. Personal paths, scripts and notes live in `.private/` and `CLAUDE.local.md`, both git-ignored. Read `CLAUDE.local.md` when it exists.

## Layout

```
FileeCore/        Swift package, no AppKit: DirectoryLister (getattrlistbulk), FileOps and Transfer (copyfile,
                  undo records), Renamer, Archive (ditto), CustomAction, Config, Fuzzy, NaturalOrder, Keys,
                  FavouriteTree (the sidebar's favourites nested by path).
                  Unit tests in FileeCore/Tests.
FileeMac/Sources/ AppKit app. AppDelegate (menus, config, state), BrowserWindow (commands, status bar),
                  Pane (tabs, path field, filter), FolderModel, ListView / ColumnsView / ThumbnailsView,
                  Sidebar, Palette, RenameSheet, InfoPanel, Operations, ActionRunner, QuickLook, HotKey,
                  FileWatch (FSEvents), Commands (catalog + key map), QAHarness, Profile,
                  Toast (messages), TransferPanel (copy and move progress), TitleBar (logo, name, folder),
                  TypeFilterBar (the tab's file-type filter; the families are FileTypeFilter in FileeCore; each button shows the icon of the family's default app, loaded in the background: 75 ms).
assets/AppIcon.svg The app icon (1024 px, full canvas) with the name "Filee" (Lato Black 200, as in Notee's icon).
                  assets/AppIcon-small.svg: without the name, for 16 to 64 px. Both are generated from
                  assets/AppIcon-art.svg by ~/ai/_shared/nicai-design/app_icon.py (command in build.sh step 1).
                  build.sh rebuilds the .icns when either changes.
FileeMac/Resources/Logo.png The title bar icon: assets/TitleBarLogo.svg (the rounded red tile, which stands out on the red bar) at 128 px (rsvg-convert).
assets/nicai/     NicAI Design kit, vendored by nicai_design.py. Never edit by hand.
project.yml       XcodeGen project. The .xcodeproj is generated: don't edit it, don't commit it.
qa.py             End-to-end QA on fixture folders in $TMPDIR/filee-qa.
benchmark.py      Filee vs Finder, Path Finder and ForkLift (launch, open a 10,000-file folder, memory, app size). A Swift
                  probe (in the script) times the first files on screen with ScreenCaptureKit and Vision OCR. Writes
                  assets/benchmark/ (results.json, the apps' icons, the README chart in light and dark). Quits and reopens a running Filee.
screenshots.py    README screenshots (assets/screenshots/, light and dark) and the header icon. Builds made-up projects in
                  /Users/Shared/Studio, runs the app read-only with the QA ops demoVolumes, capture and renderView (the type filter close-up, drawn at 3x), captures with
                  screencapture, deletes the folder. Run it again after a visible change.
.private/         Git-ignored, never pushed: signing.env, Nic's action
                  scripts, the old history bundle, HANDOVER.md (fsearch research), references/.
```

No brand logos ship with the app. A folder shows its own icon in the sidebar from a `.filee-icon.svg` or `.filee-icon.png`
inside it (`Icons.folderIconFiles`); a volume's logo comes from `volumeIcons` in `settings.json`.

## Commands

```bash
./build.sh                # Release build into build/Filee.app, signed with FILEE_SIGN_IDENTITY (ad hoc without)
./build.sh --install      # also copy it to /Applications/Filee.app (quits a running Filee first)
./build.sh --test         # run the FileeCore unit tests first
python3 qa.py             # all QA suites (about 1 min); python3 qa.py --only ops
python3 screenshots.py    # README screenshots, light and dark (about 2 min, the window comes to the front)
cd FileeCore && swift test
```

## Rules for this repo

- Push every change: `git add -A && git commit && git push`. Remote: `github.com/ndeville/filee`.
- Run `swift test` and `python3 qa.py` before a commit. Both must pass.
- Never point a QA run that writes at real folders. `qa.py` builds fixtures. For timing runs on real folders, set `FILEE_READONLY=1`.
- QA runs in the background: it never activates Filee, keeps its window at 1400x900 (not resizable, so Amethyst doesn't tile it), drops real key presses, and uses a private pasteboard. Keep it that way: Nic works while QA runs.
- Never navigate QA to `~/Downloads`, `~/Desktop` or `~/Documents`: macOS asks Nic for permission (TCC).
- `build.sh` reads the signing identity from `$FILEE_SIGN_IDENTITY` or `.private/signing.env`, so a fork signs with its own certificate. The identity isn't secret (every signed app shows it, `codesign -dv`), but it stays out of the code for that reason. What is secret: the certificate's private key, the Apple ID password and the notarisation credentials. Those never go anywhere near the repo.
- Nothing personal in tracked files: no client or employer names, no personal folders or scripts as defaults, no brand logos. Those go in `~/.filee/` or `.private/`.
- Screenshots come from `screenshots.py` only, never from Nic's real Filee: his folders, volumes and favourites must not show. The demo shows fake volumes (`demoVolumes`) for the same reason.
- Nic's builds sign with his Developer ID (from `.private/signing.env`), hardened runtime, bundle id `com.nicolasdeville.filee`. A stable signature keeps the Files and Folders and Full Disk Access grants across rebuilds. If `build.sh` warns "ad-hoc signature" on Nic's Mac, stop: `.private/signing.env` is missing.
- App icons always carry Nic's logo (the NicAI edelweiss). Icons follow the NicAI app icon layout (full canvas, name under the art: see the nicai-design skill). Edit `assets/AppIcon-art.svg` and regenerate; the options and their generator are in `output/261010-app-icon-options/`.
- ⌘H goes to the home folder, not Hide Filee (Nic's choice, 13th October 2026): the Hide menu item has no key.
- ⌘0 resets the zoom to the default size (`fontSize`, 14 pt). ⌘B, not ⌘0, toggles the sidebar. Tab names use the file list font and zoom with it.
- Nic's global App Shortcuts: ⇧⌘F is Find, ⌥⌘F is Bring All to Front. Filee has neither menu item, so the key map gets both.
- ⌘D and ⌘F are Copy and Paste through Nic's global App Shortcuts on the **Edit > Copy** and **Edit > Paste** menu titles. Never bind ⌘D or ⌘F in the key map, never rename those menu items.

## Environment variables

| Variable             | Effect                                                               |
| -                    | -                                                                    |
| `FILEE_HOME`         | Config folder instead of `~/.filee`                                  |
| `FILEE_READONLY`     | `1` blocks every file change                                         |
| `FILEE_QA`           | Path to a QA script (JSON steps); see QAHarness                      |
| `FILEE_QA_OUT`       | QA report and screenshots folder                                     |
| `FILEE_QA_KEEP_OPEN` | `1` keeps the app open after the script                              |
| `FILEE_QA_CONFLICT`  | `keepBoth`, `replace` or `skip`: answers name conflicts without a dialog |
| `FILEE_PROFILE`      | `1` logs the time of each listing, sort, view and launch phase       |
| `FILEE_DEBUG_KEYS`   | `1` logs how the key map resolves each key press                     |

## AppKit lessons (don't undo these)

- Since macOS 14, views don't clip to their bounds. A view that fills `dirtyRect` in `draw(_:)` paints over its neighbours: `ColorView` fills `bounds.intersection(dirtyRect)` and sets `clipsToBounds`.
- `NSOutlineView` can't remove its outline column: add the new columns first, set `outlineTableColumn`, then remove the old ones.
- A column view's table finds its column by index: append the column to `columns` before `reloadData`.
- `String.compare(options:)` and `localizedStandardCompare` cost 250 ms on 10,000 names. Sorting uses `NaturalOrder` keys built once per item; the filter reuses them.
- Column auto-size measures the 150 longest names and a sample of 300 rows for the other columns. Measuring every row cost 77 ms on 10,000 files.
- `getattrlistbulk` packs directory attributes only for folders and file attributes only for files. `ATTR_CMN_ERROR` sits right after the returned-attributes set, before the name.
- Mounted volume names and free space can take 150 ms on network shares: the sidebar loads them in the background.
- Layer colours (`layer.backgroundColor`) are fixed CGColors: they don't follow a theme switch. `RootView.viewDidChangeEffectiveAppearance` sets them again through `appearanceChanged()`. A new layer colour must be added there.
- The window uses a full-size content view, a transparent title bar and an empty unified toolbar (for the height): `TitleBar` sits at y=0 with the title bar's height, and everything else starts below it. QA screenshots (`cacheDisplay`) don't show the traffic lights; to see them, run a QA build with `FILEE_QA_KEEP_OPEN=1` and `screencapture -l <window id>`.
- Never draw `NSApp.applicationIconImage` or a raw `NSWorkspace` icon in the window: AppKit decodes its 1024 px representations and the footprint grew 35-65 MB (budgets failed). The title bar uses the 128 px `Logo.png`; sidebar icons go through `Icons.small` (a 64 px bitmap).
- Plain keys go to the sidebar while it has the keyboard: `Keymap.handle` steps aside for `SidebarOutline`, else ↩ would open the pane's selection.
- The sidebar outline draws its own chevrons and indents (`SidebarOutline`): `frameOfOutlineCell` is zero and every cell gets the full row width.
- `cacheDisplay` (QA screenshots) draws the inactive pane's 85% alpha as grey. The real window is correct.

## Facts

- 10th October 2026, measured with `qa.py`: launch 140-220 ms, 10,000-file folder listed in 66-83 ms (11 ms of system calls), filter keystroke 7-8 ms, 72 MB footprint idle with 2 panes and 5 tabs. Path Finder: 305 MB footprint.
- Real folders, read-only run: a mail export folder on Dropbox (21,361 files) lists in 250 ms (90 ms system calls on Dropbox), filter 54 ms, footprint peaks at 160-190 MB and settles at about 112 MB after leaving it. Freed malloc memory isn't returned by `malloc_zone_pressure_relief`.
- 14th October 2026, `benchmark.py` (folders of 10,000 files, median of 5): launch to files on screen 1.3 s (Path Finder 5.4 s,
  ForkLift 3.5 s), open a folder 465 ms (Finder 634 ms, Path Finder 2.8 s, ForkLift 1.6 s), memory 134 MB (Finder 200 MB,
  Path Finder 260 MB, ForkLift 208 MB). An accessibility probe slowed the apps it measured (ForkLift by 1 to 2 s): measure from the screen.
- Filee's open time: the open event arrives about 100 ms after `open`, the listing and view take about 110 ms, then about 250 ms
  pass before the next main-queue turn (layout and display of the new rows). That last part is the place to make it faster.
- `~/Dropbox` is a plain folder (legacy Dropbox), not File Provider: no TCC prompt.
- Notarisation needs a `notarytool` keychain profile, not set up yet. Local builds run without it.
