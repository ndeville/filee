# Filee

A native macOS file manager: 2 panes, tabs, keyboard first, fast and light. I built it with Claude Code to replace Path Finder, and I use it every day. The story and the numbers are in my note [Filee: my own file manager for macOS](https://notes.nicolasdeville.com/nicai/filee/).

This is personal software. It does what I need on my Mac and nothing else. I don't offer support, and I read issues and pull requests when I have time. Fork it and make it yours.

## What it does

- 2 panes with tabs, and 3 views: a list with an expandable tree, Miller columns and thumbnails.
- Type letters to filter the folder. ⌘K opens a palette with every command, folder and file.
- A file-type filter per tab: PDF, PowerPoint, Word, Excel, Markdown, video or images.
- Batch rename, custom actions (any script on a key), undo for file operations, a drop stack and a global hotkey.
- Favourites nest by path. A folder shows its own icon in the sidebar when it holds a `.filee-icon.svg` or `.filee-icon.png`.
- Launch in about 0.2 s, a 10,000-file folder listed in under 100 ms, about 80 MB of memory.

## Requirements

- macOS 26 on Apple silicon.
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- `rsvg-convert` (`brew install librsvg`), only to rebuild the app icon after you change its SVG.

## Build

```bash
./build.sh --install          # builds build/Filee.app and copies it to /Applications
open /Applications/Filee.app
```

Without a signing identity, `build.sh` signs the app ad hoc. It runs, but macOS asks again for folder access after each rebuild. To sign with your own Developer ID certificate, set the identity before you build:

```bash
export FILEE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

You can also put that line in `.private/signing.env`, which git ignores.

## Test

```bash
cd FileeCore && swift test    # unit tests
python3 qa.py                 # end-to-end QA on fixture folders, about 1 minute
```

`qa.py` drives the real app in the background on folders it creates in `$TMPDIR/filee-qa`. It never touches your files and never takes the keyboard, so you can keep working while it runs.

## Default file viewer

To make "Reveal in Finder" from any app open Filee:

```bash
defaults write -g NSFileViewer com.nicolasdeville.filee
```

To go back to Finder: `defaults delete -g NSFileViewer`. macOS doesn't let another app open folders in place of Finder, so `open <folder>` and Dock folders still open Finder windows.

## Daily keys

| Key             | Does                                 | Key          | Does                          |
| -               | -                                    | -            | -                             |
| Type letters    | Filter the folder (Esc clears)       | ⌘K           | Command palette               |
| ↩               | Open                                 | ⌘↑           | Enclosing folder              |
| Tab             | Switch pane                          | ⌘G or ⌘L     | Type or paste a path          |
| ⌘1 / ⌘2 / F1    | Single / dual / toggle               | ⌘3 ⌘4 ⌘5     | Thumbnails / columns / list   |
| ⌘C / ⌘X / ⌘V    | Copy / cut / paste files             | F5 / F6      | Copy / move to the other pane |
| ⌘R              | Rename (several: batch rename)       | ⇧⌘N          | New folder                    |
| ⌘⌫              | Move to Trash (⌘Z puts back)         | Space        | Quick Look                    |
| ⇧⌘D             | Copy path                            | ⌃⌘T          | Terminal here                 |
| ⌘H / ⌥⌘D        | Home / Downloads                     | ⌘J then a key | Jumps from `settings.json`   |
| ⌘B              | Show or hide the sidebar             | ⌘+ / ⌘- / ⌘0 | Bigger / smaller / default    |
| ⌃⌘L             | Switch light or dark theme           | ⌃⌥⌘F         | Bring Filee to the front      |
| ⇧⌘F             | Add or remove folder in Favourites   | ⌘E           | Eject the volume              |

The full list is in **Filee > Keyboard Shortcuts…** and in `SPEC.md` section 4.2.

## Configuration

`~/.filee/` holds 4 files. Filee reloads the first 3 when you save them:

- `settings.json`: fonts, favourites, jumps, columns, volume icons.
- `keybindings.json`: your keys, in VS Code's format, on top of the defaults.
- `actions.json`: custom actions, for example `["/usr/bin/shasum", "-a", "256", "{path}"]`.
- `state.json`: windows, tabs and view per folder.

## Develop

`SPEC.md` is the specification. `CLAUDE.md` holds the layout, the rules and the AppKit lessons, for you and for Claude Code.

## Licence

MIT. See `LICENSE`.
