# Type-Filter Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `TypeFilterBar` button always shows an icon recognizable as its file family, even when no real app for that family is installed or macOS hands back an incidental, unrelated app (ChatGPT for `.pptx`, Xcode-beta for `.md`).

**Architecture:** Add a pure, testable "is this app's bundle ID a legitimate opener for this family" allow-list and a per-family bundled-fallback-icon name to `FileTypeFilter` (FileeCore, no AppKit). `TypeFilterBar.findAppIcons()` (FileeMac) checks the allow-list before trusting `NSWorkspace`'s answer; on a miss (or no app at all) it loads a small bundled Apple-icon PNG instead of the real app's icon. The existing colored-badge function stays as a true last-resort (bundled PNG fails to load).

**Tech Stack:** Swift, AppKit, `NSWorkspace`, `UniformTypeIdentifiers`, XCTest, XcodeGen (`project.yml`).

**Spec:** [docs/superpowers/specs/2026-11-15-type-filter-icons-design.md](../specs/2026-11-15-type-filter-icons-design.md)

## Global Constraints

- Never bundle a third-party (non-Apple) brand logo — CLAUDE.md's "no brand logos" rule, amended only for Apple's own icons per the spec.
- A genuinely recognized, installed app's icon must keep showing exactly as it does today (no regression for Microsoft Word/Excel, VLC, etc.).
- `cd FileeCore && swift test` and `python3 qa.py` must pass before every commit.
- Bundled icons are small, pre-sized PNGs (128px) — never draw a raw 1024px icon in the window (AppKit lesson in `CLAUDE.md`).
- Any manual fixture files for visual verification go in `~/FileeTest` only, never a real folder.

## Review Focus

- Markdown's allow-list must exclude Xcode even though Xcode can open `.md` — showing a dev-tool hammer icon for "Markdown" is the exact complaint that started this — covered by Task 1's negative test.
- Two families must never end up pointing at the same bundled fallback icon name (two buttons would look identical) — covered by Task 1's uniqueness test.
- A bundled PNG that fails to load (missing/corrupt asset) must still render something, not a blank button or a crash — the existing colored-badge function must stay reachable as a last resort; Task 3 preserves it rather than deleting it.
- The existing real-icon dedup/substitution (two families both genuinely resolving to the same installed app, e.g. Preview for both PDF and Images) must keep working unchanged — Task 3's manual verification exercises this case explicitly.
- A family with literally no app registered for it at all (fresh Mac, nothing installed) must land on the bundled fallback, not a missing image — already implied by the allow-list miss path, exercised in Task 3's manual verification.

---

### Task 1: FileeCore — recognized-app allow-list and fallback-icon names

**Files:**
- Modify: `FileeCore/Sources/FileeCore/FileTypeFilter.swift`
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`

**Interfaces:**
- Produces: `FileTypeFilter.recognizedAppBundleIDs: Set<String>` — real, known bundle identifiers that are legitimate openers for this family.
- Produces: `FileTypeFilter.bundledFallbackIconName: String?` — the base filename (no extension) of this family's bundled Apple-icon PNG in `FileeMac/Resources/TypeIcons/`; `nil` only for `.all`.

- [ ] **Step 1: Write the failing tests**

Add to `CoreTests.swift`:

```swift
func testFileTypeFilterRecognizedApps() {
    XCTAssertTrue(FileTypeFilter.powerpoint.recognizedAppBundleIDs.contains("com.apple.iWork.Keynote"))
    XCTAssertFalse(FileTypeFilter.powerpoint.recognizedAppBundleIDs.contains("com.openai.chat"))
    XCTAssertTrue(FileTypeFilter.markdown.recognizedAppBundleIDs.contains("com.apple.TextEdit"))
    XCTAssertFalse(FileTypeFilter.markdown.recognizedAppBundleIDs.contains("com.apple.dt.Xcode"))
    XCTAssertTrue(FileTypeFilter.video.recognizedAppBundleIDs.contains("org.videolan.vlc"))
    XCTAssertTrue(FileTypeFilter.word.recognizedAppBundleIDs.contains("com.microsoft.Word"))
    XCTAssertTrue(FileTypeFilter.excel.recognizedAppBundleIDs.contains("com.microsoft.Excel"))
}

func testFileTypeFilterBundledFallbackIcons() {
    XCTAssertNil(FileTypeFilter.all.bundledFallbackIconName)
    for f in FileTypeFilter.allCases where f != .all {
        XCTAssertNotNil(f.bundledFallbackIconName)
    }
    let names = FileTypeFilter.allCases.compactMap { $0.bundledFallbackIconName }
    XCTAssertEqual(Set(names).count, names.count, "each family's bundled fallback icon name must be unique")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd FileeCore && swift test --filter testFileTypeFilterRecognizedApps`
Expected: FAIL to compile — `recognizedAppBundleIDs` not defined.

- [ ] **Step 3: Implement `recognizedAppBundleIDs` and `bundledFallbackIconName` in `FileTypeFilter.swift`**

Add as a `public extension FileTypeFilter` (or directly on the `enum`, matching the file's existing style) with these exact values:

```swift
var recognizedAppBundleIDs: Set<String> {
    switch self {
    case .all: return []
    case .pdf: return ["com.apple.Preview", "com.adobe.Reader", "com.adobe.Acrobat.Pro",
                        "com.adobe.Acrobat.Pro.continuous", "com.readdle.PDFExpert-Mac", "com.foxitsoftware.FoxitReader"]
    case .powerpoint: return ["com.microsoft.Powerpoint", "com.apple.iWork.Keynote", "org.libreoffice.script"]
    case .word: return ["com.microsoft.Word", "com.apple.iWork.Pages", "org.libreoffice.script", "com.apple.TextEdit"]
    case .excel: return ["com.microsoft.Excel", "com.apple.iWork.Numbers", "org.libreoffice.script"]
    case .markdown: return ["com.apple.TextEdit", "com.panic.Nova", "com.macromates.TextMate",
                             "com.sublimetext.4", "com.sublimetext.3", "com.barebones.bbedit",
                             "com.coteditor.CotEditor", "md.obsidian", "abnerworks.Typora", "com.brettterpstra.marked2"]
    case .video: return ["com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX"]
    case .images: return ["com.apple.Photos", "com.seriflabs.affinityphoto2", "com.seriflabs.affinityphoto",
                           "com.adobe.Photoshop", "com.pixelmatorteam.pixelmator.x"]
    }
}

var bundledFallbackIconName: String? {
    switch self {
    case .all: return nil
    case .pdf: return "Preview"
    case .powerpoint: return "Keynote"
    case .word: return "Pages"
    case .excel: return "Numbers"
    case .markdown: return "TextEdit"
    case .video: return "QuickTimePlayer"
    case .images: return "Photos"
    }
}
```

Deliberately excludes Xcode from markdown's allow-list (see Review Focus).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd FileeCore && swift test`
Expected: PASS, all tests including the 2 new ones.

- [ ] **Step 5: Commit**

```bash
git add FileeCore/Sources/FileeCore/FileTypeFilter.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift
git commit -m "feat: add recognized-app allow-list and fallback icon names to FileTypeFilter"
```

---

### Task 2: Bundle the 7 Apple icons and wire them into the app

**Files:**
- Create: `FileeMac/Resources/TypeIcons/Preview.png`
- Create: `FileeMac/Resources/TypeIcons/Photos.png`
- Create: `FileeMac/Resources/TypeIcons/QuickTimePlayer.png`
- Create: `FileeMac/Resources/TypeIcons/TextEdit.png`
- Create: `FileeMac/Resources/TypeIcons/Pages.png`
- Create: `FileeMac/Resources/TypeIcons/Numbers.png`
- Create: `FileeMac/Resources/TypeIcons/Keynote.png`
- Modify: `project.yml`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `FileTypeFilter.bundledFallbackIconName` (Task 1) — these 7 filenames must exactly match those 7 return values.
- Produces: the 7 PNGs discoverable via `Bundle.main.url(forResource: <name>, withExtension: "png", subdirectory: "TypeIcons")`, consumed by Task 3.

- [ ] **Step 1: Extract the 4 on-disk Apple icons, 128px PNG**

```bash
mkdir -p FileeMac/Resources/TypeIcons
sips -s format png -Z 128 "/System/Applications/Preview.app/Contents/Resources/AppIcon.icns" --out FileeMac/Resources/TypeIcons/Preview.png
sips -s format png -Z 128 "/System/Applications/Photos.app/Contents/Resources/AppIcon.icns" --out FileeMac/Resources/TypeIcons/Photos.png
sips -s format png -Z 128 "/System/Applications/QuickTime Player.app/Contents/Resources/AppIcon.icns" --out FileeMac/Resources/TypeIcons/QuickTimePlayer.png
sips -s format png -Z 128 "/System/Applications/TextEdit.app/Contents/Resources/AppIcon.icns" --out FileeMac/Resources/TypeIcons/TextEdit.png
```

- [ ] **Step 2: Fetch the 3 iWork icons from Apple's own App Store listing, 128px PNG**

```bash
for pair in "Keynote:com.apple.Keynote" "Numbers:com.apple.Numbers" "Pages:com.apple.Pages"; do
  name="${pair%%:*}"
  url=$(curl -s "https://itunes.apple.com/search?term=${name}&entity=macSoftware&limit=5" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
want = '${pair##*:}'
for r in d.get('results', []):
    if r.get('bundleId') == want:
        print(r.get('artworkUrl512')); break
")
  curl -sL "$url" -o "/tmp/${name}.jpg"
  sips -s format png -Z 128 "/tmp/${name}.jpg" --out "FileeMac/Resources/TypeIcons/${name}.png"
done
```

Expected: `FileeMac/Resources/TypeIcons/` now has exactly 7 PNGs.

- [ ] **Step 3: Wire the folder into `project.yml`**

Add alongside the existing `Templates` entry (same pattern):

```yaml
      - path: FileeMac/Resources/TypeIcons
        type: folder
        buildPhase: resources
```

- [ ] **Step 4: Amend `CLAUDE.md`'s brand-logo rule**

Change the line *"No brand logos ship with the app."* to add one sentence noting the exception:
*"No brand logos ship with the app, except Apple's own app icons (Preview, Photos, QuickTime Player, TextEdit, Pages, Numbers, Keynote) used as safe, recognizable fallbacks for the type-filter bar when no real app is installed for a family — see `FileTypeFilter.bundledFallbackIconName`."*

- [ ] **Step 5: Build and verify the assets land in the app bundle**

Run: `./build.sh`
Then: `find build/Filee.app/Contents/Resources/TypeIcons -maxdepth 1`
Expected: the 7 PNG files listed.

- [ ] **Step 6: Run full test suite**

Run: `cd FileeCore && swift test && cd .. && python3 qa.py`
Expected: all pass (no FileeCore/qa.py behavior touched yet, this confirms nothing broke).

- [ ] **Step 7: Commit**

```bash
git add FileeMac/Resources/TypeIcons project.yml CLAUDE.md
git commit -m "feat: bundle 7 Apple app icons as type-filter fallback assets"
```

---

### Task 3: Wire the allow-list and fallback icons into `TypeFilterBar`

**Files:**
- Modify: `FileeMac/Sources/TypeFilterBar.swift:97-123` (`findAppIcons()`)

**Interfaces:**
- Consumes: `FileTypeFilter.recognizedAppBundleIDs`, `FileTypeFilter.bundledFallbackIconName` (Task 1); the 7 bundled PNGs (Task 2).
- Produces: no change to `findAppIcons()`'s own signature (`nonisolated private static func findAppIcons() -> [FileTypeFilter: (CGImage, String)]`) or to `appIcons`'s type — callers (`image(for:size:)`, `showAppIcons()`) are untouched.

- [ ] **Step 1: Replace the resolution loop in `findAppIcons()`**

Current loop (approx. lines 103-119) unconditionally trusts `ws.urlForApplication(toOpen: type)`. Replace its body so each family first checks the allow-list; only an allow-listed app keeps today's dedup/substitution behavior, everything else (including no app at all) loads the bundled PNG:

```swift
for f in FileTypeFilter.allCases {
    guard let ext = f.sampleExtension, let type = UTType(filenameExtension: ext) else { continue }
    if var app = ws.urlForApplication(toOpen: type),
       let bundleID = Bundle(url: app)?.bundleIdentifier,
       f.recognizedAppBundleIDs.contains(bundleID) {
        if used.contains(app),
           let other = (fallbacks[f] ?? []).lazy.compactMap({ ws.urlForApplication(withBundleIdentifier: $0) })
               .first(where: { !used.contains($0) }) {
            app = other
        }
        used.append(app)
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ws.icon(forFile: app.path).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        if let image = rep.cgImage { out[f] = (image, app.deletingPathExtension().lastPathComponent) }
    } else if let name = f.bundledFallbackIconName,
              let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "TypeIcons"),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        out[f] = (cgImage, name)
    }
}
```

Leave the existing `badge(for:size:)` function and its call site in `image(for:size:)` untouched — it stays the true last resort if a bundled PNG somehow fails to load.

- [ ] **Step 2: Build**

Run: `./build.sh --test`
Expected: builds clean, FileeCore tests pass.

- [ ] **Step 3: Manual visual verification — unrecognized apps now fall back**

```bash
touch ~/FileeTest/deck.pptx ~/FileeTest/note.md ~/FileeTest/doc.docx ~/FileeTest/sheet.xlsx
```

Open Filee on `~/FileeTest`. Expected: the PowerPoint button shows Keynote's icon (not ChatGPT), the Markdown button shows TextEdit's icon (not Xcode-beta), Word/Excel show Pages/Numbers only if those aren't already resolving to the real Microsoft apps on this Mac (they do here, so Word/Excel should still show the real Microsoft Word/Excel icons, unchanged).

- [ ] **Step 4: Manual visual verification — recognized apps and dedup still work unchanged**

No setup needed: on this Mac, PDF and Images both currently resolve to Preview as their real default app. Confirm the PDF and Images buttons still show 2 *different* icons (today's existing `fallbacks` substitution still applies, unaffected by this change).

- [ ] **Step 5: Clean up fixtures**

```bash
rm ~/FileeTest/deck.pptx ~/FileeTest/note.md ~/FileeTest/doc.docx ~/FileeTest/sheet.xlsx
```

- [ ] **Step 6: Run full test suite**

Run: `cd FileeCore && swift test && cd .. && python3 qa.py`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add FileeMac/Sources/TypeFilterBar.swift
git commit -m "feat: use recognized-app allow-list, fall back to bundled Apple icons for type-filter buttons"
```
