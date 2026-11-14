# Settings window — design

## Intent

Filee has no GUI settings. `⌘,` ("Settings…") opens `settings.json` in a text
editor (`AppDelegate.openConfig`, wired in `BrowserWindow.swift:477`). SPEC.md
Phase 1.5 lists "default file viewer switch" with exit criterion "Path Finder
cancelled". The user reviewed Path Finder's own Settings window (General,
Browser, Features, Appearance, Finder panes) and wants GUI equivalents for 3
of Path Finder's toggles that Filee currently lacks a GUI for (or lacks
entirely), plus a window to hold them.

## Goals

1. "Set as default file browser" — GUI toggle for the `NSFileViewer` global
   default the README already documents as a manual `defaults write` command.
2. "Hide Finder's desktop" — new feature: toggle Finder's desktop icons off/on.
3. "Quit Finder when Filee launches" — new feature: quit Finder.app on Filee
   launch, with the Time-Machine-style caveat Path Finder shows.
4. A real AppKit Settings window to host these (and future panes), replacing
   the text-editor shortcut on `⌘,`.

## Non-goals / anti-goals

- The Contextual Menu customization pane (Path Finder's 2-column
  show/hide/reorder picker) — explicitly deferred, separate scope.
- Populating General/Browser/Appearance panes with unrelated settings that
  already live in `settings.json` (font, corners, etc.) — out of scope for
  this pass; those panes exist as empty/placeholder tabs so the window's
  shape matches Path Finder's, but only Finder pane (and General, for item 1)
  get real content.
- Anti-goal: don't imply Filee can fully replace Finder. Per README, macOS
  doesn't let another app handle `open <folder>` or Dock folder clicks — the
  "default file browser" toggle only ever promises "Reveal in Finder" (and
  similar OS hooks) will open Filee instead.

## Constraints

- No AppKit/SwiftUI split in the codebase — `FileeMac` is pure AppKit.
  `FileeCore` has no AppKit import (it's a plain Swift package, unit-tested
  standalone). The window itself is AppKit-only code in `FileeMac`; any new
  persisted field goes in `FileeCore/Sources/FileeCore/Config.swift`.
- `swift test` (FileeCore) and `python3 qa.py` must pass before commit.
- Keep new code in new files where possible, so `git pull upstream main`
  (`ndeville/filee`) stays low-conflict.
- Nothing personal in tracked files (per `CLAUDE.md`).

## Approaches considered

**Window chrome: toolbar-switched panes vs. a tab view vs. a sidebar list.**
Path Finder's reference screenshot shows a classic macOS preferences window:
a row of icon buttons in the toolbar, one per pane, each swapping the window's
content view. That's also what System Settings' pre-Ventura "Preferences"
style and most AppKit apps use (`NSToolbar` with a dictionary of
`NSToolbarItem` → content `NSView`, no `NSTabView` chrome visible). Given the
explicit reference (General / Browser / Features / Appearance / Finder as
toolbar icons, not a sidebar), I'm building it that way: `NSWindowController`
+ `NSToolbar`, one `NSView` subclass per pane, swapped in a fixed-size content
area. This matches the picture and is the smallest amount of new AppKit
plumbing. A sidebar-list style (newer System Settings) wasn't what was shown
and would be more chrome for no benefit here.

**Where "set as default file browser" lives — stored setting vs. live OS read.**
This isn't really a Filee preference; it's a live reflection of
`defaults read -g NSFileViewer` (another app can change it, e.g. by running
the same command for itself). The toggle reads the current value when the
pane appears and writes/deletes the global default directly on click — it is
NOT a new field in `settings.json`/`Settings` (FileeCore). Same reasoning for
"Hide Finder's desktop": it reflects `defaults read com.apple.finder
CreateDesktop`, written via `defaults write ... && killall Finder` on toggle.
Both shell out via `Process` to `/usr/bin/defaults`, the same command the
README already documents — no custom preference-file parsing, no extra risk.

**"Quit Finder when Filee launches" — this one *is* a Filee preference**,
since it's an action Filee takes at its own launch time, not a reflection of
external state. It becomes a new field on `FileeCore.Settings`:
`quitFinderOnLaunch: Bool` (default `false`), persisted in `settings.json`
like every other setting. Wired in `AppDelegate`'s launch path: if true, after
launch completes, quit Finder (`NSRunningApplication` for bundle id
`com.apple.finder`, `.terminate()` — gentler than `killall`, lets Finder clean
up). The pane shows the same caveat text Path Finder shows (static label
under the toggle): some OS features (Time Machine, etc.) may not work
correctly without Finder running.

**Pane placement.** "Set as default file browser" goes in **General** (it's
a broad, app-identity-level toggle, the same place most macOS apps put
"default app" switches). "Hide Finder's desktop" and "Quit Finder when Filee
launches" go in **Finder** (both are about Filee's relationship to Finder.app
specifically — matches Path Finder's own grouping). Browser and Appearance
panes are created but left as a simple "Nothing here yet" placeholder label,
so the toolbar's shape matches the 5-pane reference without inventing content
nobody asked for.

## What's decided (recap)

- `NSWindowController` + `NSToolbar`, 5 toolbar items (General, Browser,
  Features, Appearance, Finder), one `NSView` per pane, swapped in place.
  New file: `FileeMac/Sources/SettingsWindow.swift`.
- `⌘,` / "Settings…" menu item now opens this window (`AppDelegate.shared.
  showSettingsWindow()`) instead of `settings.json` in a text editor. The
  text-editor path moves to a new, key-less command ("Edit settings.json…")
  so power users keep direct file access; `Keyboard Shortcuts…` and
  `Custom Actions…` are unaffected.
- Item 1 (default file browser) and item 2 (hide Finder desktop): live
  `defaults`-backed toggles, no new `Settings` field, implemented via a small
  `FinderIntegration` helper (new file, `FileeMac/Sources/FinderIntegration.swift`)
  wrapping `/usr/bin/defaults` calls + the bundle id `com.nicolasdeville.filee`
  already used elsewhere in the repo (`AppDelegate.swift`, `project.yml`).
- Item 3 (quit Finder on launch): new `Settings.quitFinderOnLaunch: Bool`
  field (default `false`) in `FileeCore/Sources/FileeCore/Config.swift`,
  wired into `AppDelegate`'s launch sequence.
- Toggling "Hide Finder's desktop" relaunches Finder (`killall Finder`) to
  apply immediately — Path Finder does the same. This closes any open Finder
  windows; a confirmation alert before the kill says so, matching the
  severity of a disruptive-but-reversible action.
- No new unit-testable logic beyond `Settings` codec round-trip (already
  covered by the existing `Settings` Codable test pattern) and the
  `FinderIntegration` value-parsing (pure functions, testable in
  `FileeCore` — actually these need `Process`, which only runs in
  `FileeMac`, so this helper is not unit-tested under `swift test`; verified
  manually via `qa.py`/manual run instead, and kept side-effect-free except
  in the 2 toggle actions).

## What's left to the builder

- Exact pane view layout (labels, spacing, checkbox vs. switch control —
  `NSSwitch` is available on the deployment target, matches System Settings'
  modern look and is the better fit than a checkbox here).
- Exact wording of the "default file browser" caveat text (base it on the
  README's existing sentence) and the Finder-quit caveat (base on Path
  Finder's own wording, paraphrased, not copied verbatim).
- Whether the "Hide Finder's desktop" kill-Finder confirmation is a sheet or
  an `NSAlert` run modally — builder's call, `NSAlert` is simpler and matches
  existing patterns in this codebase (check `Operations.swift` / `ActionRunner.swift`
  for the existing alert style before adding a new one).
