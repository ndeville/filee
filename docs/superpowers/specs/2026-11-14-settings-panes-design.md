# Settings window: Browser, Features, Appearance panes

## Intent and why

The Settings window (⌘,) shipped with 5 toolbar panes mirroring Path Finder's
own categories — General, Browser, Features, Appearance, Finder — but only
General and Finder got real content. The other 3 show a literal
"Nothing here yet." placeholder. Meanwhile `Config.swift`'s `Settings` struct
already has 13 fields (fonts, view defaults, hidden files, vim keys, terminal
app, window corners, thumbnail size, etc.) settable only by hand-editing
`~/.filee/settings.json` — the Settings window exists specifically so people
don't have to do that, and right now it doesn't deliver on that for most of
what's configurable.

Alongside this, driving the existing panes surfaced a real bug: clicking a
toolbar item swaps the content view but never updates
`toolbar.selectedItemIdentifier` (`SettingsWindow.swift`'s `selectPane(_:)`),
so the highlighted tab visually sticks on whichever pane was selected first.
Fixing this is bundled into this same pass since it's the same file, same
area, and was found while scoping this work.

## Goals

- Browser, Features, and Appearance panes have real, working content.
- Every `Config.swift` field with no GUI today gets one.
- A small set of new, genuinely useful behaviors — validated against Path
  Finder's and ForkLift's own preferences as prior art, not invented from
  nothing — ship alongside the pure exposure work.
- The toolbar highlight-stuck bug is fixed.

## Non-goals

- Smart Sort grouping (apps/packages/folders/files ordering) — dropped:
  needs a new reorderable-list UI component that doesn't exist anywhere in
  the app yet, plus a change to the sort comparator on a budget-tested hot
  path (10,000-file listing). Scope for a later pass if ever wanted.
- Full custom color theming (Path Finder's 9-color picker system).
- A Contextual Menu editor (already explicitly deferred when the Settings
  window first shipped).
- Dropbox / remote-volume / file-comparison integrations — contradicts the
  README's "no third-party code, no network access."
- Deep per-terminal theming (colors, cursor, startup command) — the
  terminal-app picker is the real match; the rest is out of scope.
- A keyboard-remapping UI — `keybindings.json` already does this, more
  powerfully than a simple in-app editor could.
- `columns`, `favourites`, `jumps`, `volumeIcons` are explicitly **not**
  getting a GUI control in this pass — all 4 are structured lists/maps
  (reorderable column sets, name→path pairs, letter→folder maps,
  volume-name→icon maps), not a toggle or a slider. Each would need its
  own add/remove/reorder table UI, which doesn't exist anywhere in the app
  yet. They stay `settings.json`-only, reachable via the existing
  "Edit settings.json…" menu item. "Every field gets a GUI" in this
  document's Goals section means every field *that's a plain value* —
  not these 4.

## Anti-goals

Settings becomes a sprawling, Path-Finder-depth preferences tree. Every
control here maps to something Filee already does, or a small, contained,
real behavior — never a toggle added just to fill empty space.

## Constraints

- `swift test` and `python3 qa.py` must pass before every commit (repo rule).
- `qa.py`'s `FILEE_QA_CONFLICT` env var (`Operations.swift`) must keep
  bypassing the conflict dialog for automated QA runs even after a real
  default-conflict-policy setting exists — the env var takes precedence
  over the new setting, unchanged from today.
- `Format.size(_:)` (`Formatting.swift`) is UI-only — confirmed zero use in
  `filee.py`'s CLI/agent-interface output (grepped: only 6 UI view files
  call it). The size-unit setting is purely cosmetic; the agent interface
  is unaffected. No open question here.
- **Resolved (builder-check Q1):** `Format` (FileeCore) cannot see
  `Theme.settings` (FileeMac) — FileeCore has no AppKit dependency and
  stays that way. `Format.size(_:)` gets a new parameter,
  `base1000: Bool = false`, default matching today's hardcoded behavior.
  Only the UI call sites that should respect the live setting pass it
  explicitly (`Format.size(bytes, base1000: Theme.settings.sizeUnitBase1000)`);
  everything else, including the 4 existing `Format.size(1536) == "1.5 KB"`-
  style assertions in `CoreTests.swift`, keeps compiling and passing
  unchanged. No mutable static flag in FileeCore — no precedent for that
  pattern there, and it'd be a second source of truth to keep in sync.
- New `Config.swift` fields follow the existing pattern: `public var`,
  `decodeIfPresent(...) ?? d.<field>` in the decoder, a sensible default
  that matches today's hardcoded behavior (nothing changes for someone who
  never opens Settings).

## Approaches considered

1. **Pure exposure only** (ship the 13 existing fields, nothing else).
   Smallest, zero behavior risk, but leaves real, validated gaps (no
   spring-loaded folders, no conflict-policy choice) that both reference
   apps have and that came up naturalLy while researching this.
2. **Exposure + everything Path Finder/ForkLift have** (including Smart
   Sort, full theming, Dropbox panel, Contextual Menu editor). Rejected:
   contradicts Filee's stated minimal/no-third-party identity, and several
   items (full theming, Contextual Menu editor) were already ruled out
   earlier in this project's life.
3. **Exposure + a short, validated list of new behaviors** (picked): the
   13 existing fields, plus spring-loaded folders, reveal-in-Filee
   behavior, default conflict policy, file-size unit, and tab-bar
   auto-hide. Each of the 5 new behaviors is small, maps to a real gap
   found by comparing against Path Finder and ForkLift's actual shipped
   preferences (not guessed), and was reviewed with the person using the
   app before being locked in.

## What's decided

### Bug fix (do first, smallest, unblocks visual verification of everything else)

`SettingsWindow.swift`'s `selectPane(_:)`:
```swift
@objc private func selectPane(_ sender: NSToolbarItem) {
    window?.contentView = panes[sender.itemIdentifier.rawValue]
    window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
}
```
(`toolbar` in `init` is a local variable, never stored as a property.)

### Browser pane

| Control | Field / wiring |
|---|---|
| Show hidden files by default | `Config.showHidden` |
| Default view for new tabs (List/Columns/Thumbnails) | `Config.defaultView` |
| New tabs open in (folder chooser) | `Config.newTabPath` |
| Reveal in Filee: "Use active pane" (today's only behavior) vs "Open in a new tab" | new `Settings.revealInNewTab: Bool` (default `false` = today's behavior unchanged). **Resolved (builder-check Q2):** scoped to OS-triggered reveals only — `application(_:open:)` and `handleReveal(_:reply:)` (a separate AppleEvent handler from `handleURL`'s `filee://` routing). The agent CLI's `route(_:)` `"reveal"` case (`filee reveal`) keeps landing in the active pane unconditionally, per its documented contract in `CLAUDE.md` — `filee.py`'s `cmd_reveal` shells `open -g -a Filee "filee://reveal?..."`, delivered through the exact same `route(_:)` path as any other `filee://` URL, so the exemption has to live in `route(_:)` itself, not be inferred from "which call site this is." `AppDelegate.reveal(_:front:)` gets a new parameter (`respectTabPreference: Bool`, default `true`); the CLI call site passes `false` explicitly. The new-tab path must still select a revealed file after opening its parent folder — `newTab(path:)` takes no selection argument today, so this needs its own follow-up select once the tab's listing loads, matching what the in-place path already does |
| Spring-loaded folders (on/off only) | new `Settings.springLoadedFolders: Bool`. **Revised:** uses AppKit's native `NSSpringLoadingDestination` protocol, not a hand-rolled timer — a plain `Timer` schedules in the default run-loop mode, which drag-tracking doesn't use, so it would likely never fire mid-drag. Confirmed against Apple's documentation: the native protocol has no delay parameter at all; AppKit follows the user's system-wide Accessibility → Pointer Control spring-loading delay (the same one Finder uses), so there's no in-app delay setting to add. **Resolved (builder-check Q3):** wired into `ListView`, `ColumnsView`, and `ThumbnailsView` (the 3 peer views `defaultView` already treats as equal). The Sidebar's own drag-destination delegate (favourites/volumes) is explicitly out of scope for this pass — separate code path, can follow up later if wanted |

### Features pane

| Control | Field / wiring |
|---|---|
| Vim keys | `Config.vimKeys` |
| Terminal app | `Config.terminalApp`. A pre-existing inconsistency this exposes for the first time: `BrowserWindow.swift`'s `openTerminal(at:)` already respects this setting, but `ActionRunner.swift`'s custom-action terminal commands hardcode Ghostty regardless — fix `ActionRunner.swift` to respect it too, now that a GUI control makes the mismatch visible |
| "Edit keybindings.json…" / "Edit actions.json…" buttons | call `AppDelegate.openConfig` with `keybindingsURL`/`actionsURL`, same pattern as the existing "Edit settings.json…" menu item |
| Default conflict policy: Always Ask (default) / Keep Both / Replace / Skip | new `Settings.defaultConflictChoice: ConflictChoice?` (nil = always ask, today's only behavior). The real type in `FileeCore/Sources/FileeCore/FileOperations.swift` is `ConflictChoice` (`replace, keepBoth, skip, stop`) — needs `Codable` added (it's `Sendable`-only today). The existing conflict-alert code path in `Operations.swift` checks the new field before showing the dialog — `FILEE_QA_CONFLICT` still checked first and still wins, unchanged |

### Appearance pane

| Control | Field / wiring |
|---|---|
| File list font + size | `Config.fontName`, `Config.fontSize` |
| Interface font | `Config.uiFontName` |
| Sidebar font size | `Config.sidebarFontSize` |
| Thumbnail size | `Config.thumbnailSize` |
| New-today marker | `Config.newTodayMarker` |
| Window corners + highlight radius | `Config.windowCorners`, `Config.cornerRadius` |
| Theme (System/Light/Dark) | existing `AppDelegate.setTheme(_:)` |
| File size unit (Base 10 / Base 2) | new `Settings.sizeUnitBase1000: Bool` (default `false` = today's Base-2 behavior unchanged); `Formatting.swift`'s `Format.size(_:)` reads it instead of the hardcoded `1024`. Toggling it must also refresh `PaneController`'s cached free-space text and the selection status bar, both of which cache a formatted string rather than recomputing it live |
| Tab bar auto-hide when there's a single tab | new `Settings.hideSingleTabBar: Bool` (default `false`); a visibility condition in `TabStrip`, reconciled with `PaneController.layout()`'s manual frame math (not Auto Layout) and with `typeBar` sharing the same row |

### Finder pane

Unchanged.

## What's left to the builder

- Exact control types/layout within each pane (switches vs checkboxes,
  grouping, labels) — follow the visual style already established in the
  General and Finder panes (`paneView(title:rows:)`, `labeledSwitch(...)`
  helpers in `SettingsWindow.swift`); add new small helpers
  (labeled picker, labeled slider) as needed, matching that existing style.
- Whether the font/terminal-app pickers use `NSPopUpButton` with enumerated
  options or a different AppKit control — builder's call, consistent with
  the rest of the window.
- Test coverage: each new behavior needs at least one QA check (the
  pre-existing gap Codex flagged — no QA coverage for Settings-driven
  behavior at all, not just this feature) covering: reveal-in-new-tab,
  conflict-policy default, size-unit formatting, tab-bar auto-hide. Spring-
  loaded folders is harder to QA-script (needs a simulated drag) — a
  manual-test note in the plan is acceptable if scripting it cleanly isn't
  worth the time; flag it as a ruling if so.
- `AppDelegate.updateSettings(_:)` is `private` today and doesn't trigger a
  live refresh of open windows when called (it sets `Theme.settings` before
  writing the file, so the file-watcher's own `changed` comparison is
  always false for a GUI-triggered write) — this has been invisible since
  no existing GUI setting needed a live refresh. Fix needed as part of this
  work: make it `internal`, and give it the same refresh the file-watcher's
  reload path already does, explicitly, rather than relying on the watcher.
