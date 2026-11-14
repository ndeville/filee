# Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Filee a real AppKit Settings window (General/Browser/Features/Appearance/Finder toolbar panes) with 3 working toggles: set as default file browser, hide Finder's desktop, quit Finder on Filee launch.

**Architecture:** `NSWindowController` + `NSToolbar` (`.preference` style) swapping one `NSView` per pane, matching Path Finder's reference screenshot. A new `FinderIntegration` enum wraps `/usr/bin/defaults` + `NSRunningApplication` for the 2 live-OS-state toggles (not stored in `settings.json`). A new `Settings.quitFinderOnLaunch: Bool` field (FileeCore) backs the 1 toggle that's a genuine Filee preference, wired into `AppDelegate`'s launch sequence.

**Tech Stack:** Swift, AppKit, `NSToolbar`, `NSSwitch`, `Process` (shelling to `/usr/bin/defaults` and `killall`), `NSRunningApplication`.

**Spec:** `docs/superpowers/specs/2026-11-13-settings-window-design.md`

## Global Constraints

- `swift test` (FileeCore) and `python3 qa.py` must pass before every commit.
- Never point QA or this feature's manual testing at real folders or the real Finder session in a way that disrupts the user — `quitFinderOnLaunch` must never fire during `FILEE_QA=1` runs (AppDelegate already gates several launch behaviors on `qa`; this flag joins that gate).
- Bundle id is `com.nicolasdeville.filee` (`project.yml:42`); read it via `Bundle.main.bundleIdentifier` with that literal as fallback, don't hardcode only the literal.
- New code in new files where possible (`FinderIntegration.swift`, `SettingsWindow.swift`) so `git pull upstream main` stays low-conflict.
- No AppKit in `FileeCore` — the new `Settings` field is plain `Codable`, no system calls there.
- Nothing personal in tracked files.

## Review Focus

- **Finder not running when a toggle is read/written.** `defaults read com.apple.finder CreateDesktop` and `-g NSFileViewer` work whether or not Finder is currently running (they read a plist, not a live process) — but `killall Finder` when Finder isn't running must not crash or alert; treat "no matching processes" as success, not failure.
- **`quitFinderOnLaunch` during `FILEE_QA=1`.** Must stay off during QA regardless of the stored setting, or every `python3 qa.py` run kills the developer's real Finder session mid-work. This is the highest-severity miss in this plan.
- **Window reopened while already open.** `⌘,` while the Settings window is already key should bring it forward, not spawn a second window.
- **Toggle state goes stale.** Another app (or a Terminal command, as the README documents) can change `NSFileViewer`/`CreateDesktop` while the Settings window is closed. Panes must re-read live state on `windowDidBecomeKey`/pane-appear, not only at window construction.
- **User cancels the "hide Finder's desktop" confirmation.** The switch must visually revert to its prior state, not show "on" while the underlying default is untouched.

---

## Task 1: `Settings.quitFinderOnLaunch` field + test

**Files:**
- Modify: `FileeCore/Sources/FileeCore/Config.swift` (the `Settings` struct: property, default-init, decode-init, doc comment block above `fileText`)
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`

**Interfaces:**
- Produces: `Settings.quitFinderOnLaunch: Bool` (default `false`), decoded like every other optional field (`decodeIfPresent(Bool.self, forKey: .quitFinderOnLaunch) ?? d.quitFinderOnLaunch`).

- [ ] **Step 1: Write the failing test** — add to `CoreTests.swift`, next to `testCornerSettings`:

```swift
func testQuitFinderOnLaunchDefaultsFalse() throws {
    let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
    XCTAssertEqual(try decode("{}").quitFinderOnLaunch, false)
    XCTAssertEqual(try decode(#"{"quitFinderOnLaunch": true}"#).quitFinderOnLaunch, true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd FileeCore && swift test --filter testQuitFinderOnLaunchDefaultsFalse`
Expected: FAIL (build error — `quitFinderOnLaunch` not a member of `Settings`)

- [ ] **Step 3: Add the field** in `Config.swift`: `public var quitFinderOnLaunch: Bool` next to the other `Bool` settings (near `vimKeys`/`newTodayMarker`), default `false` in `init()`, decoded in `init(from:)` following the existing `decodeIfPresent ?? d.<field>` pattern. No change needed to `fileText`'s doc-comment header (it already says "every field optional") — add 1 inline comment above the property only if its purpose isn't obvious from the name (it is; skip the comment).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd FileeCore && swift test --filter testQuitFinderOnLaunchDefaultsFalse`
Expected: PASS

- [ ] **Step 5: Run the full FileeCore suite**

Run: `cd FileeCore && swift test`
Expected: all tests PASS (in particular `testDefaultFilesParse`'s `XCTAssertEqual(settings, Settings())` must still hold — it will, since both sides get the same new default)

- [ ] **Step 6: Commit**

```bash
git add FileeCore/Sources/FileeCore/Config.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift
git commit -m "feat: add quitFinderOnLaunch setting"
```

---

## Task 2: `FinderIntegration` helper

**Files:**
- Create: `FileeMac/Sources/FinderIntegration.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Task 3 and Task 4):
  - `FinderIntegration.isDefaultFileViewer() -> Bool`
  - `FinderIntegration.setDefaultFileViewer(_ on: Bool)`
  - `FinderIntegration.isDesktopHidden() -> Bool`
  - `FinderIntegration.setDesktopHidden(_ hidden: Bool)` — writes the default AND relaunches Finder (`killall Finder`, ignoring "no such process")
  - `FinderIntegration.quitFinder()` — used by Task 4 at launch; terminates Finder if running, does nothing if it isn't

No unit tests: this file only wraps `Process`/`NSRunningApplication` calls against the real OS and has no pure logic to isolate from them (`FileeCore` has no AppKit/Process access, so this can't move there). Verified manually (Task 5's manual check) and via `qa.py`'s normal full-suite run (which must keep passing with this file compiling in).

- [ ] **Step 1: Write `FinderIntegration.swift`**

```swift
import AppKit

/// Wraps the Terminal commands README.md documents for "make Filee the default file
/// viewer" and Path Finder's "hide Finder's desktop" / "quit Finder" toggles.
enum FinderIntegration {
    static var filleeBundleID: String { Bundle.main.bundleIdentifier ?? "com.nicolasdeville.filee" }

    static func isDefaultFileViewer() -> Bool {
        defaultsRead(["-g", "NSFileViewer"]) == filleeBundleID
    }

    static func setDefaultFileViewer(_ on: Bool) {
        if on {
            defaultsRun(["write", "-g", "NSFileViewer", filleeBundleID])
        } else {
            defaultsRun(["delete", "-g", "NSFileViewer"])
        }
    }

    static func isDesktopHidden() -> Bool {
        defaultsRead(["read", "com.apple.finder", "CreateDesktop"]) == "0"
    }

    static func setDesktopHidden(_ hidden: Bool) {
        defaultsRun(["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        relaunchFinder()
    }

    static func quitFinder() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.terminate()
    }

    private static func relaunchFinder() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Returns stdout trimmed, or nil if the key isn't set / the command failed.
    private static func defaultsRead(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args.first == "read" ? args : ["read"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func defaultsRun(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
```

`isDesktopHidden`'s absent-key case is already correct as written: `defaultsRead` returns `nil` when `CreateDesktop` was never set, and `nil == "0"` is `false` — matching Finder's real default (icons shown). Confirm this with a manual read on a machine where the key has never been set (Task 5, Step 5) before relying on it.

- [ ] **Step 2: Add the file to the Xcode project**

Run: `xcodegen generate` (or whatever `build.sh` does internally — check `build.sh` step order) so `project.yml`'s `FileeMac/Sources` glob picks up the new file.

- [ ] **Step 3: Build to confirm it compiles**

Run: `./build.sh --test` (builds + runs FileeCore tests; a FileeMac compile error surfaces here even though FileeMac itself has no test target)
Expected: build succeeds

- [ ] **Step 4: Commit**

```bash
git add FileeMac/Sources/FinderIntegration.swift
git commit -m "feat: add FinderIntegration helper for NSFileViewer and Finder desktop/quit toggles"
```

---

## Task 3: Settings window (General + Finder panes populated, Browser/Features/Appearance placeholders)

**Files:**
- Create: `FileeMac/Sources/SettingsWindow.swift`

**Interfaces:**
- Consumes: `FinderIntegration` (Task 2), `Theme.settings` / `AppDelegate.shared` (Task 4 wires the quitFinderOnLaunch read/write through a new `AppDelegate` method — this task's Finder pane calls `AppDelegate.shared.setQuitFinderOnLaunch(_:)` and reads `Theme.settings.quitFinderOnLaunch`, both of which Task 4 adds; if Task 4 hasn't landed yet when this task is built standalone, stub the call or sequence Task 4 first).
- Produces: `final class SettingsWindowController: NSWindowController` with `static let shared = SettingsWindowController()` (lazy singleton) and `func show()` (creates/reuses the window, calls `makeKeyAndOrderFront`, and refreshes both toggle panes' live state before showing).

- [ ] **Step 1: Build the window shell**

`SettingsWindowController`: `NSWindow` with `styleMask: [.titled, .closable]`, fixed content size (pick ~480×300 — adjust once panes are laid out), `toolbarStyle = .preference`. An `NSToolbar` with 5 `NSToolbarItem`s (`general`, `browser`, `features`, `appearance`, `finder` identifiers), each with a label ("General", "Browser", "Features", "Appearance", "Finder") and an SF Symbol image (`gearshape`, `safari`, `wrench.and.screwdriver`, `paintbrush`, `folder` — adjust to taste, not spec-critical). Selecting a toolbar item swaps the window's `contentView` to that pane's view (keep all 5 pane views constructed once, held in an array/dict, swap via `contentView =`). Default-select `general` on first open.

- [ ] **Step 2: Build the General pane**

One `NSView` (`NSStackView`, vertical) containing: a bold section label ("Default File Browser"), an `NSSwitch` + title label ("Set Filee as the default file browser"), and a wrapping caption `NSTextField` (non-editable, secondary color, smaller font) with the caveat text:
"Other apps' \"Reveal in Finder\" will open Filee instead. macOS still opens Finder for the Dock and for apps that open folders directly — Filee can't fully replace Finder."
Switch state comes from `FinderIntegration.isDefaultFileViewer()` on pane refresh; its action calls `FinderIntegration.setDefaultFileViewer(sender.state == .on)`.

- [ ] **Step 3: Build the Finder pane**

Same `NSStackView` pattern, 2 rows:
1. "Hide Finder's Desktop" switch + caption ("Removes desktop icons until you turn this back on. Finder quits and reopens to apply the change."). Action: before flipping the switch's visible state, run an `NSAlert` (`.warning`, message "Hide Finder's desktop icons?", informative text "This quits and reopens Finder. Any open Finder windows will close.", buttons "Hide Desktop" / "Cancel"). On "Hide Desktop" (or on turning it back on — only confirm when turning ON, turning off needs no confirmation since it's just restoring the default and still relaunches Finder, but isn't destructive so skip the alert there): call `FinderIntegration.setDesktopHidden(_:)`, then re-read `isDesktopHidden()` to set the switch's actual resulting state. On "Cancel": revert the switch to its pre-click state without calling `FinderIntegration`.
2. "Quit Finder When Filee Launches" switch + caption ("Some macOS features, like Time Machine, may not work correctly while Finder isn't running."). Action: calls `AppDelegate.shared.setQuitFinderOnLaunch(sender.state == .on)` (Task 4). State comes from `Theme.settings.quitFinderOnLaunch` on pane refresh.

- [ ] **Step 4: Build Browser/Features/Appearance placeholder panes**

Each: a single centered `NSTextField` (non-editable, secondary color), text "Nothing here yet.".

- [ ] **Step 5: Wire live-state refresh**

`SettingsWindowController.show()` re-reads `FinderIntegration.isDefaultFileViewer()`, `FinderIntegration.isDesktopHidden()`, and `Theme.settings.quitFinderOnLaunch`, pushing them into the 3 switches, every time it's called (covers "window reopened" and "state went stale while closed" from Review Focus) — not just on first construction.

- [ ] **Step 6: Build to confirm it compiles**

Run: `./build.sh --test`
Expected: build succeeds (the `AppDelegate.shared.setQuitFinderOnLaunch` call will only resolve once Task 4 lands — if building Task 3 before Task 4, add a private no-op stub matching that signature here and delete it in Task 4, or simply do Task 4 first; recommended order is Task 4 before Task 3's Step 1, despite the numbering, since Task 3 depends on its interface)

- [ ] **Step 7: Commit**

```bash
git add FileeMac/Sources/SettingsWindow.swift
git commit -m "feat: add Settings window with General and Finder panes"
```

---

## Task 4: Wire launch behavior + menu

**Files:**
- Modify: `FileeMac/Sources/AppDelegate.swift` (`applicationDidFinishLaunching`, add `setQuitFinderOnLaunch`, `buildMenus`'s Filee submenu)
- Modify: `FileeMac/Sources/Commands.swift` (command catalog)
- Modify: `FileeMac/Sources/BrowserWindow.swift` (the `perform` switch)

**Interfaces:**
- Consumes: `SettingsWindowController.shared.show()` (Task 3), `FinderIntegration.quitFinder()` (Task 2), the existing `updateSettings(_:)` private helper in `AppDelegate.swift:216`.
- Produces: `AppDelegate.setQuitFinderOnLaunch(_ on: Bool)`, `AppDelegate.showSettingsWindow()`.

- [ ] **Step 1: Add `AppDelegate.showSettingsWindow()` and `setQuitFinderOnLaunch(_:)`**

```swift
func showSettingsWindow() { SettingsWindowController.shared.show() }

func setQuitFinderOnLaunch(_ on: Bool) { updateSettings { $0.quitFinderOnLaunch = on } }
```

Place both near `openConfig` (`AppDelegate.swift:206`).

- [ ] **Step 2: Gate Finder-quit on launch, skipping QA**

In `applicationDidFinishLaunching` (`AppDelegate.swift:41`), after the existing `let qa = ProcessInfo.processInfo.environment["FILEE_QA"] != nil` line: add `if !qa && Theme.settings.quitFinderOnLaunch { FinderIntegration.quitFinder() }`. Place it after `w.showWindow(nil)`/`makeKeyAndOrderFront` so Filee's own window is already up before Finder quits (avoids any flash of no frontmost app).

- [ ] **Step 3: Repoint the `openSettings` command, add `editSettingsFile`**

In `Commands.swift`, change the title of the existing `openSettings` entry (it keeps its id and `cmd+,` key — no key-map/menu-validation changes needed) from `"Open Settings (settings.json)"` to `"Settings…"`, and add a new entry directly after it: `.init(id: "editSettingsFile", title: "Edit settings.json…", key: nil, args: nil)`.

In `AppDelegate.swift`'s `buildMenus()`, the Filee submenu's `cmd("Settings…", "openSettings")` line stays as-is (title already matches); add `cmd("Edit settings.json…", "editSettingsFile")` right after it.

Add `"editSettingsFile"` to the `commandsWhileEditing` set (`AppDelegate.swift:541`), alongside the existing `"openSettings"`.

- [ ] **Step 4: Repoint the `perform` switch**

In `BrowserWindow.swift`, change:
```swift
case "openSettings": AppDelegate.shared.openConfig(AppDelegate.shared.config.settingsURL)
```
to:
```swift
case "openSettings": AppDelegate.shared.showSettingsWindow()
case "editSettingsFile": AppDelegate.shared.openConfig(AppDelegate.shared.config.settingsURL)
```
(leave the adjacent `openKeybindings`/`openActions` lines untouched).

- [ ] **Step 5: Build**

Run: `./build.sh --test`
Expected: build succeeds, FileeCore tests pass

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/AppDelegate.swift FileeMac/Sources/Commands.swift FileeMac/Sources/BrowserWindow.swift
git commit -m "feat: wire Settings window into the Filee menu and quit Finder on launch"
```

---

## Task 5: Manual verification + QA suite

**Files:** none (verification only)

- [ ] **Step 1: Run the full automated check**

Run: `./build.sh --test && python3 qa.py`
Expected: both pass. `qa.py` must not kill the real Finder — confirms the `!qa` gate from Task 4 Step 2 works.

- [ ] **Step 2: Manual run — General pane**

Launch the built app (`open build/Filee.app` or `./build.sh --install` then open it). `⌘,` opens the Settings window on the General pane. Toggle "Set Filee as the default file browser" on; in Terminal, `defaults read -g NSFileViewer` should print the app's bundle id. Toggle off; the key should be gone (`defaults read -g NSFileViewer` errors "does not exist").

- [ ] **Step 3: Manual run — Finder pane, hide desktop**

Switch to the Finder pane. Toggle "Hide Finder's Desktop" on — confirm the alert appears, confirm "Hide Desktop" hides real desktop icons (Finder visibly relaunches). Toggle off — icons return, no confirmation alert. Click "Cancel" on a subsequent on-toggle attempt — switch visually reverts, desktop icons stay as they were.

- [ ] **Step 4: Manual run — quit Finder on launch**

Toggle "Quit Finder When Filee Launches" on. Quit and relaunch Filee (not via `FILEE_QA`) — Finder should quit shortly after Filee's window appears. Toggle off, relaunch again — Finder should stay running (if it was running).

- [ ] **Step 5: Manual run — reopen / stale state**

With the Settings window open on Finder pane, run `defaults write com.apple.finder CreateDesktop -bool false && killall Finder` directly in Terminal. Close and reopen the Settings window (`⌘,` again, or close then `⌘,`) — the "Hide Finder's Desktop" switch should now read "on" without needing an app restart.

- [ ] **Step 6: `python3 screenshots.py` is NOT required for this feature** (it only screenshots the main browser window, not Settings) — skip unless the user asks for it.

- [ ] **Step 7: Final commit (if Step 1-5 required fixes)**

```bash
git add -A
git commit -m "fix: settings window polish after manual verification"
```
(Skip this step entirely if no fixes were needed.)
