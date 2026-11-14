# Settings window: Browser, Features, Appearance panes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Nothing here yet." placeholders in the Settings window's Browser, Features, and Appearance panes with real controls — exposing 13 existing `Config.swift` fields that have no GUI today, adding 5 small new behaviors validated against Path Finder's and ForkLift's own preferences, and fixing a toolbar highlight bug found while scoping this work.

**Architecture:** Core logic (new `Settings` fields, `Format.size`'s new parameter, conflict-policy short-circuit, reveal-behavior branch, tab-bar visibility, spring-load hover timer) lands first, each independently testable; the 3 panes' UI, which only wires existing controls to that logic, lands last, one task per pane.

**Tech Stack:** Swift 6, AppKit, FileeCore (no AppKit, no third-party deps) + FileeMac.

**Spec:** [docs/superpowers/specs/2026-11-14-settings-panes-design.md](../specs/2026-11-14-settings-panes-design.md)

## Global Constraints

- `swift test` and `python3 qa.py` must pass before every commit.
- `FILEE_QA_CONFLICT` (env var, `Operations.swift`) must keep overriding any configured default conflict policy — unchanged precedence.
- `Format.size(_:)` stays in FileeCore with no AppKit dependency; no mutable static settings state added to FileeCore.
- New `Settings` fields follow the existing pattern exactly: `public var`, a default in `init()` matching today's hardcoded behavior, `decodeIfPresent(...) ?? d.<field>` in the decoder — someone who never opens Settings sees no behavior change.
- The agent CLI's `filee reveal` (`AppDelegate.route(_:)`'s `"reveal"` case) always lands in the active pane, regardless of the new reveal-behavior setting — its documented contract in `CLAUDE.md` doesn't change.
- Spring-loaded folders ship on `ListView`, `ColumnsView`, `ThumbnailsView` only — the Sidebar's own drag-destination delegate is out of scope.
- Smart Sort grouping, full custom color theming, a Contextual Menu editor, and any network/third-party integration are explicitly not part of this plan.

## Review Focus

- Spring-loading must not activate on a non-folder drop target (a file, empty space): `springLoadingEntered(_:)`/`springLoadingUpdated(_:)` return `.disabled` unless the hovered item is a folder — a reasonable person dragging over a file in the list shouldn't have it "spring open."
- `filee reveal` (the CLI) must land in the active pane even when "reveal in new tab" is turned on — the one path explicitly exempted; a reasonable automation script relying on the documented contract must not silently start accumulating tabs.
- `Format.size(_:base1000:)` on a negative/sentinel byte count (FolderModel's unmeasured-folder-size marker, `-1`) still returns `"--"` regardless of `base1000` — a reasonable person browsing without having calculated folder sizes must not see a nonsense number.
- `FILEE_QA_CONFLICT` wins over a configured default conflict policy — a reasonable person who sets a personal default (say, "Keep Both") and then runs `qa.py` must still get deterministic, scripted QA behavior, not their personal default interfering.
- Closing a tab down to 1 while "hide tab bar when single tab" is on hides the bar immediately, not only when a pane is first created — a reasonable person expects the bar to react live, the same way it already reacts live to opening a 2nd tab.

---

### Task 1: Fix the Settings toolbar highlight bug

**Files:**
- Modify: `FileeMac/Sources/SettingsWindow.swift:195` (`selectPane(_:)`)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new — pure bug fix, no new surface for later tasks.

- [ ] **Step 1: Manually reproduce** — open Settings (⌘,), click through General → Browser → Finder → General. Confirm the toolbar's highlighted icon doesn't follow the clicks (stays on whichever was selected first).
- [ ] **Step 2: Fix `selectPane(_:)`**

```swift
@objc private func selectPane(_ sender: NSToolbarItem) {
    window?.contentView = panes[sender.itemIdentifier.rawValue]
    window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
}
```

(`toolbar` in `init` is a local variable, never stored as a property — `window?.toolbar` is the only way to reach it. The earlier draft of this fix used a bare `toolbar?.` which doesn't compile.)

- [ ] **Step 3: Manually verify** — repeat Step 1's click sequence; the highlighted icon now follows every click.
- [ ] **Step 4: Run `python3 qa.py --only browse`** (exercises the app launching/settings path; confirms nothing else broke)

Expected: passes (1 pre-existing unrelated failure, "Esc closes the palette after a click in its list", is expected and not caused by this change).

- [ ] **Step 5: Commit**

```bash
git add FileeMac/Sources/SettingsWindow.swift
git commit -m "fix: Settings toolbar highlight now follows the selected pane"
```

---

### Task 2: New `Settings` fields

**Files:**
- Modify: `FileeCore/Sources/FileeCore/Config.swift`
- Modify: `FileeCore/Sources/FileeCore/FileOperations.swift` (`ConflictChoice`)
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`

**Interfaces:**
- Produces (for later tasks to read/write via `Theme.settings.<field>`):
  - `Settings.revealInNewTab: Bool` (default `false`)
  - `Settings.springLoadedFolders: Bool` (default `false`) — on/off only. `NSSpringLoadingDestination` (Task 7's chosen approach) has no delay parameter at all; AppKit times the hover itself, following the user's system-wide Accessibility → Pointer Control spring-loading delay, the same one Finder uses. No `springLoadDelay` field — there's nothing in Filee to set it on.
  - `Settings.defaultConflictChoice: ConflictChoice?` (default `nil` = always ask)
  - `Settings.sizeUnitBase1000: Bool` (default `false`)
  - `Settings.hideSingleTabBar: Bool` (default `false`)
  - `ConflictChoice` gains `String, Codable` conformance (was `Sendable` only): `case replace, keepBoth, skip, stop`

- [ ] **Step 1: Write the failing tests** in `CoreTests.swift` — this file is `XCTestCase`-based (`import XCTest`, `XCTAssertEqual`), not Swift Testing; follow `testCornerSettings()`'s exact existing pattern (a local `decode` closure, `XCTAssertEqual`), not `#expect`:

```swift
func testNewSettingsPaneFieldsDefault() throws {
    let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    let d = try decode("{}")
    XCTAssertEqual(d.revealInNewTab, false)
    XCTAssertEqual(d.springLoadedFolders, false)
    XCTAssertNil(d.defaultConflictChoice)
    XCTAssertEqual(d.sizeUnitBase1000, false)
    XCTAssertEqual(d.hideSingleTabBar, false)
}

func testNewSettingsPaneFieldsRoundTrip() throws {
    let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    let s = try decode(#"""
    {"revealInNewTab": true, "springLoadedFolders": true,
     "defaultConflictChoice": "keepBoth", "sizeUnitBase1000": true, "hideSingleTabBar": true}
    """#)
    XCTAssertEqual(s.revealInNewTab, true)
    XCTAssertEqual(s.springLoadedFolders, true)
    XCTAssertEqual(s.defaultConflictChoice, .keepBoth)
    XCTAssertEqual(s.sizeUnitBase1000, true)
    XCTAssertEqual(s.hideSingleTabBar, true)
    // An old, minimal settings.json (pre-dating these fields) must still decode cleanly to defaults:
    let old = try decode(#"{"fontSize": 16}"#)
    XCTAssertEqual(old.fontSize, 16)
    XCTAssertNil(old.defaultConflictChoice)
}
```

- [ ] **Step 2: Run `cd FileeCore && swift test --filter testNewSettingsPaneFields`**

Expected: FAIL — fields don't exist yet.

- [ ] **Step 3: Implement.** In `FileOperations.swift`, change `public enum ConflictChoice: Sendable` to `public enum ConflictChoice: String, Codable, Sendable`. In `Config.swift`'s `Settings` struct, add the 5 fields listed above; in `init()`, set each to its default; in the decoder, add (matching the existing style, e.g. line 86's `vimKeys` for the plain-Bool fields):

```swift
revealInNewTab = try c.decodeIfPresent(Bool.self, forKey: .revealInNewTab) ?? d.revealInNewTab
springLoadedFolders = try c.decodeIfPresent(Bool.self, forKey: .springLoadedFolders) ?? d.springLoadedFolders
defaultConflictChoice = try c.decodeIfPresent(ConflictChoice.self, forKey: .defaultConflictChoice) ?? d.defaultConflictChoice
sizeUnitBase1000 = try c.decodeIfPresent(Bool.self, forKey: .sizeUnitBase1000) ?? d.sizeUnitBase1000
hideSingleTabBar = try c.decodeIfPresent(Bool.self, forKey: .hideSingleTabBar) ?? d.hideSingleTabBar
```

- [ ] **Step 4: Run `cd FileeCore && swift test`**

Expected: PASS, all tests including the 2 new ones.

- [ ] **Step 5: Commit**

```bash
git add FileeCore/Sources/FileeCore/Config.swift FileeCore/Sources/FileeCore/FileOperations.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift
git commit -m "feat: add Settings fields for the Browser/Features/Appearance panes"
```

---

### Task 3: `Format.size` size-unit parameter

**Files:**
- Modify: `FileeCore/Sources/FileeCore/Formatting.swift`
- Modify (call sites, pass the live setting): `FileeMac/Sources/TransferPanel.swift`, `FileeMac/Sources/Pane.swift`, `FileeMac/Sources/FileView.swift`, `FileeMac/Sources/BrowserWindow.swift`, `FileeMac/Sources/Sidebar.swift`, `FileeMac/Sources/InfoPanel.swift`
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: nothing from Task 2 directly (FileeCore can't see `Theme.settings`) — the 6 call-site files read `Theme.settings.sizeUnitBase1000` themselves and pass it in.
- Produces: `Format.size(_ bytes: Int64, base1000: Bool = false) -> String`

- [ ] **Step 1: Write the failing tests** — `XCTestCase`/`XCTAssertEqual` style, matching the rest of `CoreTests.swift` (this file has no Swift Testing import):

```swift
func testFormatSizeBase1000() {
    // 1536 formats to "1.5 KB" in BOTH modes (1536/1024 = 1536/1000 rounds the same) — it doesn't
    // actually distinguish them. 1_500_000 does: 1.5 MB at /1000 vs 1.4 MB at /1024, no rounding
    // boundary ambiguity either way.
    XCTAssertEqual(Format.size(1_500_000, base1000: true), "1.5 MB")
    XCTAssertEqual(Format.size(1_500_000, base1000: false), "1.4 MB")
}

func testFormatSizeBase1000NegativeStaysPlaceholder() {
    XCTAssertEqual(Format.size(-1, base1000: true), "--")
}

func testFormatSizeDefaultParameterUnchanged() {
    // existing call style, no base1000 argument, must still compile and pass
    XCTAssertEqual(Format.size(1536), "1.5 KB")
}
```

- [ ] **Step 2: Run `cd FileeCore && swift test --filter testFormatSizeBase1000`**

Expected: FAIL — no `base1000` parameter yet.

- [ ] **Step 3: Implement.** Add a `base1000: Bool = false` parameter to `Format.size(_:)`; when `true`, divide by 1000 instead of 1024 at each unit step (same loop structure, same digit-rounding rule, just a different divisor). The existing `bytes < 0` and `bytes < 1024`/`< 1000` boundary checks follow the same `base1000`-selected divisor.
- [ ] **Step 4: Run `cd FileeCore && swift test`**

Expected: PASS, all tests including the 4 pre-existing `Format.size` assertions (unaffected — they call the 1-argument form, which still defaults to base-2).

- [ ] **Step 5: Wire the 6 UI call sites.** In each of `TransferPanel.swift`, `Pane.swift`, `FileView.swift`, `BrowserWindow.swift`, `Sidebar.swift`, `InfoPanel.swift`, change each `Format.size(x)` call to `Format.size(x, base1000: Theme.settings.sizeUnitBase1000)`.
- [ ] **Step 5a: Refresh the 2 places that cache a formatted size string instead of recomputing it.** `PaneController`'s free-space text (`Pane.swift:217`'s `freeText`, built by `updateFreeSpace()` at line 381) and `BrowserWindowController.selectionChanged(in:)` (`BrowserWindow.swift:255`, the status-bar selection size) both only recompute on their own trigger (a folder change, a selection change) — toggling the setting alone won't touch either until something else happens to. Add `updateFreeSpace()` to the end of `PaneController.styleChanged()` (`Pane.swift:655`, the existing "a setting changed, refresh everything" hook — it already re-runs the tab/path/type-filter/count refreshes there), and have whatever calls `pane.styleChanged()` after a settings reload also call `selectionChanged(in: pane)` for that window's active pane.
- [ ] **Step 6: Run `cd FileeCore && swift test && cd .. && ./build.sh --test`**

Expected: PASS, builds clean.

- [ ] **Step 7: Commit**

```bash
git add FileeCore/Sources/FileeCore/Formatting.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift FileeMac/Sources/TransferPanel.swift FileeMac/Sources/Pane.swift FileeMac/Sources/FileView.swift FileeMac/Sources/BrowserWindow.swift FileeMac/Sources/Sidebar.swift FileeMac/Sources/InfoPanel.swift
git commit -m "feat: Format.size supports base-1000 units, wired to a live setting"
```

---

### Task 4: Default conflict policy

**Files:**
- Modify: `FileeMac/Sources/Operations.swift`
- Modify: `FileeMac/Sources/QAHarness.swift:233-249` (the `"settings"` step's poll — see Step 1a)
- Test: `python3 qa.py` addition (new `expect`/`settings` steps in the `ops` suite, `qa.py`'s `suites()` function)

**Note:** `QAHarness.swift`'s `"settings"` step writes `settings.json` then polls `Theme.settings` until the write lands — but the poll's `switch k` only actually checks `"windowCorners"` and `"cornerRadius"` by name; every other key falls to `default: return true` and reports "loaded" after a flat 0.2s regardless of whether the write really landed. Every new field this plan's QA steps set via `{"op": "settings", "set": {...}}` (this task's `defaultConflictChoice`, Task 5's `revealInNewTab`, Task 6's `hideSingleTabBar`, Task 10's `sizeUnitBase1000` if tested the same way) needs its own `case` added to that switch, or its QA step is flaky/meaningless — it'll "pass" before the setting actually takes effect.

**Interfaces:**
- Consumes: `Settings.defaultConflictChoice: ConflictChoice?` (Task 2).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Read `Operations.swift`'s existing conflict-resolution code** (the `FILEE_QA_CONFLICT` check, around line 13) to find the exact spot the interactive alert is shown.
- [ ] **Step 1a: Extend `QAHarness.swift`'s `"settings"` poll** (lines 244-247's `switch k`) with cases for `"defaultConflictChoice"` (compare `s.defaultConflictChoice?.rawValue == v as? String`), `"revealInNewTab"` and `"hideSingleTabBar"` (compare `Bool`), so this task's and Tasks 5/6's new QA steps actually wait for the write instead of racing it.
- [ ] **Step 2: Write the failing QA steps.** In `qa.py`'s `"ops"` suite, add (following the existing `{"op": "settings", "set": {...}}` / `{"op": "expect", ...}` pattern used for `windowCorners`/`cornerRadius` in the `"browse"` suite): set `defaultConflictChoice` to `"keepBoth"`, trigger a name-conflicting copy, and `expect` the operation completes without the alert sheet appearing (both copies exist, no `sheetVisible` or equivalent — match whatever QAHarness already reports for a visible sheet; if nothing does yet, add a minimal `sheetVisible: Bool` field to QAHarness's expectation output, following the existing pattern for other UI-state fields like `pathEditing`).
- [ ] **Step 3: Run `python3 qa.py --only ops`**

Expected: FAIL — setting is ignored today, the alert still shows.

- [ ] **Step 4: Implement.** In `Operations.swift`, before showing the interactive alert: if `ProcessInfo.processInfo.environment["FILEE_QA_CONFLICT"]` is set, keep today's behavior unchanged (env var wins, per the Global Constraints). Otherwise, if `Theme.settings.defaultConflictChoice` is non-nil, use it directly and skip the alert. Only show the alert when both are absent.
- [ ] **Step 5: Run `python3 qa.py --only ops`**

Expected: PASS.

- [ ] **Step 6: Add the Review Focus test** — `FILEE_QA_CONFLICT` set AND `defaultConflictChoice` set to a different value: confirm the env var's choice wins (this is exactly how every other `qa.py` suite already runs, so this is really confirming no regression — run `python3 qa.py --only ops` again with both set via the test harness's existing env-var mechanism and a settings.json default, and `expect` the env var's outcome).
- [ ] **Step 7: Commit**

```bash
git add FileeMac/Sources/Operations.swift qa.py
git commit -m "feat: a default conflict-resolution policy skips the alert when set"
```

---

### Task 5: Reveal-in-new-tab behavior

**Files:**
- Modify: `FileeMac/Sources/AppDelegate.swift` (`reveal(_:front:)`, `application(_:open:)`, and `route(_:)`'s `"reveal"` case)
- Modify: `FileeMac/Sources/QAHarness.swift` (new op, see Step 1)
- Test: `python3 qa.py` addition (new steps in an existing suite, or a small new one)

**Interfaces:**
- Consumes: `Settings.revealInNewTab: Bool` (Task 2).
- Produces: `AppDelegate.reveal(_ url: URL, front: Bool = true, respectTabPreference: Bool = true)`.

**Important — the CLI's `filee reveal` and a real Finder/default-browser reveal are NOT the same test.** `filee.py`'s `cmd_reveal` shells `open -g -a Filee "filee://reveal?path=...&rid=..."` (`filee.py:136`) — that's delivered as a GetURL AppleEvent into `handleURL` → `route(_:)`'s `"reveal"` case, exactly like `qa.py`'s existing `{"op": "url", "url": "filee://reveal?..."}` step (`qa.py:982`) already tests. There is no way to distinguish "the CLI called this" from any other `filee://reveal` URL at that point — the exemption has to live in `route(_:)` itself (pass `respectTabPreference: false` there), and testing it means using the existing `{"op": "url", ...}` mechanism, not inventing a new one.

A *real* OS-triggered reveal (Finder's "Reveal in Filee" once Filee is the default viewer, or any app handing Filee a folder/file path) arrives through `application(_:open:)` with plain file URLs — never through `filee://` at all. `QAHarness.swift` has no way to simulate that today; it needs a new op.

- [ ] **Step 1: Add a `QAHarness` op to simulate an OS-triggered reveal.** Something like `{"op": "revealPath", "path": "<path>"}` that calls `AppDelegate.shared.reveal(URL(fileURLWithPath: path), front: true)` directly — bypassing `route(_:)` entirely, the way `application(_:open:)` does.
- [ ] **Step 2: Write the failing QA steps.** Set `revealInNewTab: true` via `{"op": "settings", "set": ...}` (now polled correctly per Task 4's Step 1a). Use the new `revealPath` op on a **folder** and `expect` a new tab opened (tab count increased) at that path. Use it again on a **file** and `expect` a new tab opened at the file's parent folder *with the file selected* — the Review Focus/Codex-flagged case: the new-tab path must not silently drop the existing file-selection behavior. Separately, use the existing `{"op": "url", "url": "filee://reveal?path=...&rid=..."}` step and `expect` the active pane's path changed in place — no new tab, confirming the CLI exemption holds regardless of the setting.
- [ ] **Step 3: Run the new QA steps**

Expected: FAIL — `reveal(_:front:)` has no new-tab branch yet.

- [ ] **Step 4: Implement.** Add `respectTabPreference: Bool = true` to `reveal(_:front:respectTabPreference:)`. When `respectTabPreference` is `true` and `Theme.settings.revealInNewTab` is `true`, open a new tab instead of navigating the active pane in place. `w.activePane.newTab(path: String? = nil)` (`Pane.swift:422`) takes no file-selection argument — today's in-place `reveal(_:)` selects the revealed file after navigating (`url.deletingLastPathComponent().path, select: [url.path]`), and the new-tab path must not lose that: call `newTab(path: <folder>)`, then select the file in the new tab the same way the in-place branch already does, once the new tab's listing has loaded (mirror whatever `navigate(to:select:)` does for the in-place case — don't drop the selection just because the destination is a new tab). Folders (no file to select) just need `newTab(path: <folder>)`. The 2 real OS-triggered call sites — `application(_:open:)` and `handleReveal(_:reply:)` (a separate AppleEvent handler from `handleURL`'s `filee://` routing) — keep their default (`respectTabPreference: true`, unchanged call). `route(_:)`'s `"reveal"` case passes `respectTabPreference: false` explicitly.
- [ ] **Step 5: Run the new QA steps**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/AppDelegate.swift qa.py
git commit -m "feat: reveal-in-Filee can open a new tab instead of using the active pane"
```

---

### Task 6: Tab bar auto-hide for a single tab

**Files:**
- Modify: `FileeMac/Sources/Pane.swift` (`TabStrip`)
- Test: `python3 qa.py` addition

**Interfaces:**
- Consumes: `Settings.hideSingleTabBar: Bool` (Task 2).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing QA steps.** Set `hideSingleTabBar: true`, confirm a single-tab pane's tab strip is hidden; open a 2nd tab, confirm it becomes visible; close back down to 1, confirm it hides again (the Review Focus item — must react live, not just at pane creation). Use whatever QAHarness already reports for tab-strip visibility, or add a minimal field if nothing does yet, following the existing pattern (e.g. `hiddenTabs`'s precedent).
- [ ] **Step 2: Run the new QA steps**

Expected: FAIL.

- [ ] **Step 3: Implement.** `PaneController.layout()` (`Pane.swift:300`) positions everything with manual frame math, not Auto Layout — `tabStrip` and `typeBar` share the same row (`y: accentH`, `height: tabH` where `tabH = Theme.tabHeight`, a constant), and `pathField`/`crumbs`/`countLabel`/`top` are all positioned starting at `accentH + tabH + ...`. Simply zeroing `tabStrip`'s own height when hidden isn't enough — the row itself has to collapse, but `typeBar` can still be visible and needs that same row.

  In `TabStrip`, inside the existing `titles` `didSet`, set `isHidden = Theme.settings.hideSingleTabBar && titles.count <= 1`. In `PaneController.layout()`, replace the raw `tabH` constant used for the row's *reserved height* (not `tabStrip`'s or `typeBar`'s own frame heights, which can stay `Theme.tabHeight`) with:

  ```swift
  let tabRowH: CGFloat = (tabStrip.isHidden && typeBar.isHidden) ? 0 : tabH
  ```

  and use `tabRowH` wherever `tabH` currently feeds into `pathField`, `crumbs`, `countLabel`, and `top`'s y-position math (lines 314-318). This way the row only fully collapses when both `tabStrip` and `typeBar` are hidden; if `typeBar` is showing (the type-filter buttons), the row stays reserved at `Theme.tabHeight` even with a single tab.
- [ ] **Step 3a: Make the toggle live on already-open windows.** Toggling `hideSingleTabBar` in Settings must re-trigger this for every open pane, not just the next tab-count change — have the setting's write path (wherever Task 8's control calls into `AppDelegate` to persist it) iterate open windows' panes and re-run their `layout()` after reassigning `tabStrip.isHidden`.
- [ ] **Step 4: Run the new QA steps**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FileeMac/Sources/Pane.swift qa.py
git commit -m "feat: hide the tab bar when there's a single tab, live"
```

---

### Task 7: Spring-loaded folders (AppKit's native `NSSpringLoadingDestination`)

**Decision:** uses AppKit's own spring-loading protocol, not a hand-rolled timer. A plain `Timer.scheduledTimer` schedules only in the default run-loop mode, but mouse-drag tracking runs the run loop in a different mode — it would likely never fire mid-drag. `NSSpringLoadingDestination` is the API Apple built for exactly this; AppKit owns the hover timing itself. Confirmed against Apple's docs: the protocol has **no delay parameter at all** — AppKit follows the user's system-wide Accessibility → Pointer Control spring-loading delay (the same one Finder uses), not anything Filee can set. That's why there's no `springLoadDelay` field (Task 2) — `springLoadedFolders` is on/off only.

**Files:**
- Modify: `FileeMac/Sources/ListView.swift` (its `NSOutlineView`, add `NSSpringLoadingDestination` conformance)
- Modify: `FileeMac/Sources/ColumnsView.swift` (its `NSTableView`, same)
- Modify: `FileeMac/Sources/ThumbnailsView.swift` (its `NSCollectionView`, same)

**Interfaces:**
- Consumes: `Settings.springLoadedFolders: Bool` (Task 2).
- Produces: nothing new for later tasks.

The protocol (confirmed from Apple's documentation — `developer.apple.com/documentation/appkit/nsspringloadingdestination`):

```swift
protocol NSSpringLoadingDestination: NSObjectProtocol {
    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo)       // required
    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo)                 // required
    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions // optional
    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions // optional
    func springLoadingExited(_ draggingInfo: any NSDraggingInfo)                            // optional
}
```

A view can be both a drag-and-drop destination (today's `validateDrop`/`acceptDrop`, unchanged) and a spring-loading destination at once — Apple's docs say so explicitly; this task adds the 2nd on top of the 1st, nothing about the existing drop handling changes.

**Open implementation question for the builder to settle by testing against the real view, not by guessing:** whether to register the whole `NSOutlineView`/`NSTableView`/`NSCollectionView` itself as the one spring-loading destination (reusing the exact same drag-location → row/item hit-testing `validateDrop` already does, inside `springLoadingUpdated(_:)`, to track which row is currently under the cursor) — this plan's working assumption, since it mirrors how these views already act as a single `NSDraggingDestination` rather than one per row — or whether per-row conformance is needed. Confirm the simpler whole-view approach works before reaching for anything more granular.

- [ ] **Step 1: Wire `ListView.swift`'s outline view.** Add `NSSpringLoadingDestination` conformance. `springLoadingEntered(_:)` and `springLoadingUpdated(_:)`: hit-test `draggingInfo.draggingLocation` to a row/item the same way `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)` already does; return `.enabled` if `Theme.settings.springLoadedFolders` is on and that item is a folder, `.disabled` otherwise (Review Focus: never activate on a file or empty space). `springLoadingActivated(true, draggingInfo:)`: re-hit-test (the protocol doesn't hand you the target, only the dragging info) and navigate into that folder — the same call path a double-click uses. `springLoadingExited(_:)`/`springLoadingActivated(false, draggingInfo:)`: no persistent state to clean up (AppKit owns the timing), but make sure nothing navigates on exit.
- [ ] **Step 2: Wire `ColumnsView.swift`'s table view** the same way, reusing its existing `validateDrop`'s row-hit-testing.
- [ ] **Step 3: Wire `ThumbnailsView.swift`'s collection view** the same way, reusing its existing `validateDrop`'s index-path hit-testing.
- [ ] **Step 4: Manually verify** in the built app: enable the setting, drag a file from one pane onto a folder in the other pane's List view, hold without releasing — the folder opens after the system's own spring-loading delay (System Settings → Accessibility → Pointer Control, if you want to shorten it for testing). Repeat for Columns and Thumbnails views. Drag over a plain file and confirm nothing happens. Turn the setting off and confirm hovering a folder no longer springs it open.
- [ ] **Step 5: Run `python3 qa.py`** (full suite — confirms nothing in normal, non-dragging list/column/thumbnail interaction broke)

Expected: 84/85 — the 1 pre-existing, confirmed-unrelated "browse" suite failure, everything else passing. Not a regression from this task's change.

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/ListView.swift FileeMac/Sources/ColumnsView.swift FileeMac/Sources/ThumbnailsView.swift
git commit -m "feat: spring-loaded folders in List, Columns, and Thumbnails views, via NSSpringLoadingDestination"
```

---

### Task 8: Browser pane UI

**Files:**
- Modify: `FileeMac/Sources/SettingsWindow.swift`
- Modify: `FileeMac/Sources/AppDelegate.swift:221` (`updateSettings`, see Step 0)

**Note:** `AppDelegate.updateSettings(_ change: (inout Settings) -> Void)` is currently `private` — the existing pattern for a single toggle (`setQuitFinderOnLaunch`) is a small dedicated wrapper function per setting, but this plan adds ~15 more fields across 3 panes. Writing 15 near-identical one-line wrappers just to work around `private` isn't worth it: drop the `private` (make it `internal`, the file's own default-access level already used elsewhere in this codebase) so `SettingsWindow.swift` can call `AppDelegate.shared.updateSettings { $0.<field> = ... }` directly for every new control, the same closure-based call each wrapper already makes internally.

**Interfaces:**
- Consumes: `Settings.showHidden`, `Settings.defaultView`, `Settings.newTabPath` (existing), `Settings.revealInNewTab` (Task 5), `Settings.springLoadedFolders` (Task 7). `SettingsWindowController.paneView(title:rows:)`, `.labeledSwitch(...)` (existing, see `SettingsWindow.swift:78,109`).
- Produces (new helpers, reused by Tasks 9 and 10):

```swift
/// 1 labeled popup, title + choices, stacked like labeledSwitch.
private func labeledPicker<T: Hashable>(title: String, options: [(T, String)], initial: T,
                                         store: (NSPopUpButton) -> Void, action: Selector) -> NSView
/// 1 labeled slider with a numeric value label, title above.
private func labeledSlider(title: String, range: ClosedRange<Double>, initial: Double,
                            store: (NSSlider) -> Void, action: Selector) -> NSView
```

- [ ] **Step 0: Drop `private` from `AppDelegate.updateSettings(_:)`** (make it `internal`).

- [ ] **Step 0a: Fix a latent live-refresh gap `updateSettings` has today, which this task is the first to actually exercise.** `updateSettings` sets `Theme.settings = s` in memory *before* writing the file (`AppDelegate.swift:221`). Separately, `loadConfig(initial:)` — the file-watcher's reload path — decides whether to refresh open windows by comparing `settings != Theme.settings` (`AppDelegate.swift:188`). Because `updateSettings` already updated `Theme.settings` first, by the time the watcher notices its own write and calls `loadConfig`, the comparison is always equal, so `changed` is `false` and the refresh block (`WindowCorners.refresh()`, every window's `styleChanged()`/`sidebar.reload()`) never runs. This has been invisible until now because the only 2 settings with a GUI control so far (`quitFinderOnLaunch`, the default-browser/hide-desktop toggles) don't need a live visual refresh — several of this plan's new fields (`sizeUnitBase1000`, `hideSingleTabBar`, the Appearance pane's fonts/corners) do.

  Fix: extract the refresh block already inside `loadConfig`'s `if changed` branch into a small shared method, e.g. `private func applySettingsRefresh()`, and call it from both places: `loadConfig`'s `if changed` branch (unchanged, for file-only edits — hand-editing `settings.json`, or `qa.py`'s `{"op": "settings"}` step, which writes the file directly without touching `Theme.settings` first) and at the end of `updateSettings`, right after it sets `Theme.settings` and writes the file. No double work: when the file watcher later fires for a GUI-triggered write, `Theme.settings` already matches, so `loadConfig`'s own `changed` check is naturally `false` and skips a second refresh.

- [ ] **Step 0b: Size the window per pane from content, not a hardcoded guess.** `SettingsWindowController`'s window has `contentMinSize == contentMaxSize == NSSize(480, 300)` (`SettingsWindow.swift:19-21`) and panes are a plain `NSStackView`, no scroll view — Task 10's ~10 Appearance controls won't fit in 300px. In `selectPane(_:)` (Task 1), after swapping `contentView`, compute the new pane's required height (the stack view's `fittingSize.height` plus the existing top/bottom insets) and call `window?.setContentSize(NSSize(width: 480, height: <that height>))`, clamped to the screen's visible frame height. Don't hardcode a per-pane height table — a miscounted row (there isn't a fixed "5 rows" for Browser, for instance) silently clips again the next time a control is added.
- [ ] **Step 1: Build `labeledPicker` and `labeledSlider`**, following `labeledSwitch`'s existing structure (title + control in an `NSStackView`, same spacing/font conventions).
- [ ] **Step 2: Replace `panes["browser"] = placeholderPane()`** with real content: a "Show hidden files by default" switch (`showHidden`), a "Default view for new tabs" picker (List/Columns/Thumbnails, `defaultView`), a "New tabs open in" row (reuse the existing default-browser pattern's caption style; a simple text field bound to `newTabPath` is enough — a folder-chooser button is a nice-to-have, builder's call), a "Reveal in Filee" picker ("Use active pane" / "Open in a new tab", `revealInNewTab`), and a "Spring-loaded folders" switch (`springLoadedFolders`) — on/off only, no delay control, since AppKit's native spring-loading has none to set (follows the system's own Accessibility delay instead).

  `BrowserWindowController.showHidden` (`BrowserWindow.swift:71`) only reads `Theme.settings.showHidden` once, in `init(state:)` — this is correct as-is and needs no live-sync fix: the control is named "by default" deliberately, meaning new windows going forward, not a global override of windows already open (which may have their own hidden-files state from the existing ⇧⌘. shortcut).
- [ ] **Step 3: Wire each control's action** to write `Theme.settings.<field>` and persist, following `toggleDefaultBrowser`/`toggleQuitFinderOnLaunch`'s existing pattern (`AppDelegate.shared.updateSettings { $0.<field> = ... }` — check the exact existing call for how settings get saved and reloaded, e.g. `setQuitFinderOnLaunch`'s implementation).
- [ ] **Step 3a: Refresh these controls in `show()`.** `SettingsWindowController.show()` (`SettingsWindow.swift:40-48`) today only refreshes the 3 General/Finder switches from live state. Add the same for each of this pane's new controls (read back from `Theme.settings` each time the window opens), so a `settings.json` hand-edit made while Settings was closed is reflected correctly the next time it opens — not just whatever the controls happened to show last.
- [ ] **Step 4: Manually verify** — open Settings, click Browser, toggle each control, quit and reopen Filee, confirm each value persisted and took effect (hidden files visible, new tabs use the chosen default view, etc.). Also close Settings, hand-edit `settings.json`, reopen Settings, confirm the controls reflect the hand-edited values (Step 3a).
- [ ] **Step 5: Run `python3 qa.py --only browse`**

Expected: 84/85 — the 1 pre-existing, confirmed-unrelated "browse" suite failure ("Esc closes the palette after a click in its list"), everything else passing. Not a regression from this task's change.

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/SettingsWindow.swift
git commit -m "feat: Browser pane — hidden files, default view, new-tab location, reveal behavior, spring-loaded folders"
```

---

### Task 9: Features pane UI

**Files:**
- Modify: `FileeMac/Sources/SettingsWindow.swift`
- Modify: `FileeMac/Sources/ActionRunner.swift:108-138` (see Step 1a)

**Interfaces:**
- Consumes: `Settings.vimKeys`, `Settings.terminalApp` (existing), `Settings.defaultConflictChoice` (Task 4). `labeledPicker` (Task 8). `AppDelegate.openConfig`, `.keybindingsURL`, `.actionsURL` (existing — same pattern as the "Edit settings.json…" menu item).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Replace `panes["features"] = placeholderPane()`** with real content: a "Vim keys" switch (`vimKeys`), a "Terminal app" text field or picker (`terminalApp`), 2 buttons ("Edit keybindings.json…", "Edit actions.json…") that call `AppDelegate.shared.openConfig(AppDelegate.shared.config.keybindingsURL)` / `.actionsURL`, and a "Default conflict policy" picker (Always Ask / Keep Both / Replace / Skip, `defaultConflictChoice`, where "Always Ask" maps to `nil` and the other 3 map to their `ConflictChoice` case).
- [ ] **Step 1a: Fix a pre-existing `terminalApp` inconsistency this control exposes for the first time.** `BrowserWindow.swift`'s `openTerminal(at:)` already respects `Theme.settings.terminalApp` — but `ActionRunner.swift`'s custom-action terminal commands (lines 108, 138) hardcode Ghostty specifically, regardless of the setting. That's been invisible with no GUI control pointing at `terminalApp`; once Settings has a picker for it, a user picking "Terminal" and seeing custom actions still launch Ghostty is a visible, confusing bug. Change `ActionRunner.swift` to use `Theme.settings.terminalApp` the same way `openTerminal(at:)` does.
- [ ] **Step 2: Wire each control's action**, same pattern as Task 8 Step 3.
- [ ] **Step 2a: Refresh these controls in `show()`**, same as Task 8 Step 3a.
- [ ] **Step 3: Manually verify** — toggle vim keys and confirm hjkl navigation responds accordingly; set a terminal app and confirm both "Open Terminal Here" *and* a custom action's terminal output use it; click both "Edit…" buttons and confirm the right file opens; set a conflict policy and confirm a conflicting copy no longer shows the alert (cross-check against Task 4's QA steps passing is sufficient; this step is about the picker itself writing the right value).
- [ ] **Step 4: Run `python3 qa.py --only browse`**

Expected: 84/85 — the 1 pre-existing, confirmed-unrelated "browse" suite failure ("Esc closes the palette after a click in its list"), everything else passing. Not a regression from this task's change.

- [ ] **Step 5: Commit**

```bash
git add FileeMac/Sources/SettingsWindow.swift
git commit -m "feat: Features pane — vim keys, terminal app, keybindings/actions editors, default conflict policy"
```

---

### Task 10: Appearance pane UI

**Files:**
- Modify: `FileeMac/Sources/SettingsWindow.swift`

**Interfaces:**
- Consumes: `Settings.fontName`, `.fontSize`, `.uiFontName`, `.sidebarFontSize`, `.thumbnailSize`, `.newTodayMarker`, `.windowCorners`, `.cornerRadius` (existing), `Settings.sizeUnitBase1000` (Task 3), `Settings.hideSingleTabBar` (Task 6), `AppDelegate.setTheme(_:)` (existing). `labeledPicker`, `labeledSlider` (Task 8).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Replace `panes["appearance"] = placeholderPane()`** with real content: font pickers/fields for `fontName`/`fontSize` and `uiFontName`, sliders for `sidebarFontSize` and `thumbnailSize`, a "New today marker" switch (`newTodayMarker`), a window-corners picker (Rounded/Square, `windowCorners`) with a corner-radius slider (`cornerRadius`), a theme picker (System/Light/Dark, calling `setTheme(_:)`), a "File size unit" picker (Base 10/Base 2, `sizeUnitBase1000`), and a "Hide tab bar when there's a single tab" switch (`hideSingleTabBar`).
- [ ] **Step 2: Wire each control's action**, same pattern as Task 8 Step 3.
- [ ] **Step 2a: Refresh these controls in `show()`**, same as Task 8 Step 3a.
- [ ] **Step 3: Manually verify** — toggle each control, confirm the file list/sidebar/window/tab-bar react live where the setting already supports live updates (corners and radius already do, per the existing `browse` QA suite's `settings` steps, and per Task 8 Step 0a's fix, every other live-affecting control here now does too); confirm the size unit switch changes how sizes display immediately, including the free-space text and the selection status bar (Task 3 Step 5a).
- [ ] **Step 4: Run `python3 qa.py --only browse`**

Expected: 84/85 — the 1 pre-existing, confirmed-unrelated "browse" suite failure ("Esc closes the palette after a click in its list"), everything else passing. Not a regression from this task's change.

- [ ] **Step 5: Run the full suite: `python3 qa.py` and `cd FileeCore && swift test`**

Expected: both green (1 pre-existing unrelated `browse` failure).

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/SettingsWindow.swift
git commit -m "feat: Appearance pane — fonts, sizes, corners, theme, size unit, tab-bar auto-hide"
```
