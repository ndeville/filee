# Changelog

Changes in this fork (`djspiceroute/filee`) since it diverged from
[`ndeville/filee`](https://github.com/ndeville/filee). Upstream keeps no
changelog of its own; this one only covers what's fork-specific, newest
first. `git log upstream/main..main` is the exact, authoritative list —
this file is the human-readable summary of it.

## 2026-11-14

- Settings window (⌘,): toggle Filee as the default file browser, hide
  Finder's desktop icons, quit Finder when Filee launches.
- Fix: the title bar showed a black gap in full screen (an empty toolbar
  confused AppKit's title-bar sizing; hidden now while full screen).
- Fix: `Blank.docx`/`Blank.xlsx` opened in Word/Excel's Compatibility Mode
  instead of natively.
- CI: PR and issue templates, a required `test` check, and a separate
  non-blocking `perf` check for the worst-case QA suite.
- `benchmark.py`: starts Setapp first, so Path Finder and ForkLift (Setapp
  installs) don't hang at launch waiting on their license check; numbers
  refreshed.

## 2026-11-13

- Open With: option-click an app in the submenu to make it the default
  for that file extension.
- Final-review fixes: truncated-image safety, paste into a right-clicked
  folder, a tighter image-selection check.

## 2026-11-12

- Right-click menu: Cut/Copy/Paste, a real New submenu (Folder, Text
  File, blank Word Document / Excel Spreadsheet).
- Convert to JPEG (keeps EXIF orientation) and Create PDF from Selection,
  both images-only and non-destructive.
- QA: `expect`'s `menuContains`/`menuExcludes` check the right-click
  menu's actual contents.
