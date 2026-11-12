# Phase 1 Right-Click Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Filee's right-click menu to the mouse-first, Windows-Explorer-style shape agreed in the approved mockups (`https://claude.ai/artifact/A3ResGFwoR11ZjEEzMJqqy`): Cut/Copy/Paste on the menu itself, a New submenu with Word/Excel templates, file-type-conditional Convert to JPEG / Create PDF, and a default-app row in Open With — without touching navigation, the toolbar, or settings UI (Phase 2+).

**Architecture:** Every new action is wired the same way the app already wires its ~60 existing commands: a pure, testable function in `FileeCore` (no AppKit) where the work is non-trivial (image/PDF writing, template copying), a thin `OperationCenter` method in `FileeMac` that adds progress/undo/error-display around it, a `case` in `BrowserWindowController.perform(_:args:)` that calls it, and a row in `contextMenu(for:in:)` that calls `perform` through the existing `add(title, id)` helper. Menu-content correctness (which rows show for which selection) is verified by extending the QA harness's `expect` step rather than by screenshotting, since `contextMenu(for:in:)` is a plain synchronous function that returns an `NSMenu`.

**Tech Stack:** Swift 6, AppKit, Foundation, CoreGraphics + ImageIO (no AppKit, no third-party code — matches `FileeCore`'s existing constraint), XCTest, qa.py's JSON-driven QA harness.

**Spec:** The user's own planning doc (Mac File Explorer feature list, read into this conversation) plus the approved mockup artifact `https://claude.ai/artifact/A3ResGFwoR11ZjEEzMJqqy` (10 boards: Main + 4 right-click states × light/dark).

## Global Constraints

- Keep new code in new files, or in clearly separate additions to existing files, so `git pull upstream main` (ndeville/filee changes almost daily) stays low-conflict. Never reformat or reorder code you are not touching.
- `swift test` and `python3 qa.py` must both pass before every commit (CLAUDE.md's existing rule).
- Test only against `~/FileeTest` (already created) or qa.py's own fixtures. Never a real folder.
- Ask the user before deleting anything (their explicit rule) — nothing in this plan deletes existing rows or files, so this should not come up; flag it if a task turns out to need it.
- `FileeCore` targets have no AppKit import (CLAUDE.md layout rule) — new FileeCore code uses only Foundation/CoreGraphics/ImageIO/zip-level APIs.
- No third-party code, no network access (README's stated invariants) — Convert to JPEG and Create PDF are native ImageIO/CoreGraphics, not a shelled-out tool.
- 7Z/RAR, disk map, full-text search, a settings *screen*, and the toolbar/navigation are explicitly out of scope (Phase 2+ per the user's doc).

## Review Focus

- A selection that mixes an image and a non-image file must not show Convert to JPEG / Create PDF (today's `if items.contains(where: { $0.ext == "zip" })` pattern for Extract Here is the precedent: conditional rows check the *whole* selection, not just the first item).
- A single folder selected must still show Cut/Copy/Paste and New›, but never Open With, Convert to JPEG, or Create PDF (Open With already excludes folders today; the new rows must follow the same filter).
- Converting or PDF-ing an unreadable/corrupt image (zero-byte file, truncated HEIC) must fail that one item with a clear error and leave the rest of a multi-select batch to still succeed, matching `extract()`'s per-item error collection — never abort the whole batch on one bad file.
- A template name collision (e.g. "New Document.docx" already exists) must get a unique name the same way `newFolder`/`newFile` already do (`FileOps.uniqueName`), not overwrite or silently fail.
- Setting a new default app for an extension (Open With's new row) must not affect any *other* extension, and must survive app relaunch (it's a LaunchServices-level change, not in-memory).

---

## File Structure

**New:**
- `FileeCore/Sources/FileeCore/ImageConvert.swift` — `ImageConvert.toJPEG`, pure ImageIO/CoreGraphics.
- `FileeCore/Sources/FileeCore/PDFBuilder.swift` — `PDFBuilder.fromImages`, pure CoreGraphics PDF context.
- `FileeMac/Resources/Templates/Blank.docx`, `FileeMac/Resources/Templates/Blank.xlsx` — committed binary assets (generated once by a throwaway script, not itself committed).

**Modify:**
- `FileeCore/Sources/FileeCore/FileOperations.swift` — add `FileOps.copyTemplate`.
- `FileeMac/Sources/Operations.swift` — add `OperationCenter.convertToJPEG`, `createPDF`, `newFromTemplate`.
- `FileeMac/Sources/BrowserWindow.swift` — `contextMenu(for:in:)` (new rows), `perform(_:args:)` (new cases), `openTerminal` label, new `newSubmenu()` helper, `OpenWithMenu` (Always Open row).
- `FileeMac/Sources/QAHarness.swift` — `check(_:)` gains `menuContains`/`menuExcludes`.
- `FileeCore/Tests/FileeCoreTests/CoreTests.swift` — new test methods (same file, existing convention: all 31 current tests live in this one file).
- `project.yml` — register the two template resources.
- `qa.py` — new steps in the `ops` suite exercising the new menu rows.

---

### Task 1: QA harness learns to check menu content

**Files:**
- Modify: `FileeMac/Sources/QAHarness.swift` (`check(_ step:)`, line 561)
- Test: `qa.py`'s `ops` suite (`suites(fx:)`, around line 343)

**Interfaces:**
- Produces: `expect` step keys `"menuContains": [String]` and `"menuExcludes": [String]`, checked against `wc.contextMenu(for: p.selectedItems, in: p).items.map(\.title)` for the step's pane. Every later task's QA steps use these two keys.

- [ ] **Step 1: Add the two keys to `check(_ step:)`**

```swift
if let want = step["menuContains"] as? [String] {
    let titles = wc.contextMenu(for: pane(step).selectedItems, in: pane(step)).items.map(\.title)
    guard want.allSatisfy({ titles.contains($0) }) else { return false }
}
if let avoid = step["menuExcludes"] as? [String] {
    let titles = wc.contextMenu(for: pane(step).selectedItems, in: pane(step)).items.map(\.title)
    guard !avoid.contains(where: { titles.contains($0) }) else { return false }
}
```

Add this alongside the file's other `if let ... = step["..."]` checks inside `check(_:)`, following that function's existing style exactly (it already has ~15 such blocks — match their indentation and the `guard ... else { return false }` idiom).

- [ ] **Step 2: Add one `ops` suite step proving both keys work against today's menu**

```python
{"op": "select", "pane": 0, "names": ["alpha.txt"]},
{"op": "expect", "label": "today's file menu has Open but no Convert to JPEG yet",
 "menuContains": ["Open", "Copy Path"], "menuExcludes": ["Convert to JPEG"]},
```

Add right after the existing `"select"` step that picks `alpha.txt` near the top of the `ops` suite (reuse that selection rather than adding a new one).

- [ ] **Step 3: Build and run**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: all green, including the new step.

- [ ] **Step 4: Commit**

```bash
git add FileeMac/Sources/QAHarness.swift qa.py
git commit -m "qa: check context-menu contents via expect's menuContains/menuExcludes"
```

---

### Task 2: Cut/Copy/Paste on the menu, and the terminal label

**Files:**
- Modify: `FileeMac/Sources/BrowserWindow.swift` (`contextMenu(for:in:)` lines 793–834, `perform(_:args:)` switch, `openTerminal` line 579–588)
- Test: `qa.py`'s `ops` suite

**Interfaces:**
- Produces: `perform` ids `"cut"`, `"copy"` (new; `"pasteHere"` already exists and is reused for Paste in both contexts).

- [ ] **Step 1: Add the QA step first (TDD: it must fail)**

```python
{"op": "expect", "label": "file menu offers Cut/Copy/Paste", "menuContains": ["Cut", "Copy", "Paste"]},
{"op": "select", "pane": 0, "names": []},
{"op": "expect", "label": "empty-space menu offers New, Open Terminal Here (not Ghostty by name) and Paste",
 "menuContains": ["Paste"], "menuExcludes": ["Open Ghostty Here"]},
```

Place the first step right after Task 1's new step (same selection still holds). Place the second step wherever the suite already clears the selection, or add a `{"op": "select", "pane": 0, "names": []}` if it doesn't.

- [ ] **Step 2: Run, confirm it fails**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: FAIL at the new steps — "Cut"/"Copy" don't exist yet; the label still reads "Open Ghostty Here".

- [ ] **Step 3: Add `perform` cases**

In the `switch id` of `perform(_:args:)`, add:

```swift
case "cut": cut(nil)
case "copy": copy(nil)
```

(Right next to the existing `case "pasteHere": paste(nil)` line, same style.)

- [ ] **Step 4: Add the rows to `contextMenu(for:in:)`**

In the `items.isEmpty` (empty-space) branch, change:

```swift
add("Paste", "pasteHere")
```

to:

```swift
add("Cut", "cut")
add("Copy", "copy")
add("Paste", "pasteHere")
```

(Cut/Copy on empty space act on nothing and should just beep via the existing `cut(nil)`/`copy(nil)` guard clauses — no new guard needed, they already `guard !items.isEmpty else { return }`.)

In the non-empty branch, right after the `Open`/`Open With` block and before `add("Quick Look", "quickLook")`, add:

```swift
add("Cut", "cut")
add("Copy", "copy")
add("Paste", "pasteHere")
menu.addItem(.separator())
```

- [ ] **Step 5: Fix the terminal label**

Change both `"Open Ghostty Here"` literals (empty-space branch and the folder-selected branch) to:

```swift
add("Open \(Theme.settings.terminalApp) Here", "terminalHere")
```

- [ ] **Step 6: Build and run**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add FileeMac/Sources/BrowserWindow.swift qa.py
git commit -m "feat: Cut/Copy/Paste in the right-click menu, terminal label follows settings"
```

---

### Task 3: New› submenu (Folder, Text File — Word/Excel land in Task 4)

**Files:**
- Modify: `FileeMac/Sources/BrowserWindow.swift` (`contextMenu(for:in:)`, new private `newSubmenu(for pane: PaneController) -> NSMenu`)
- Test: `qa.py`'s `ops` suite

**Interfaces:**
- Produces: `newSubmenu(for:) -> NSMenu`, used by Task 4 to add 2 more rows to the same menu.

- [ ] **Step 1: QA step (must fail first)**

```python
{"op": "expect", "label": "New is a submenu, not 2 flat rows, in the file menu too",
 "menuContains": ["New"], "menuExcludes": ["New Folder", "New Text File"]},
```

Add after Task 2's steps (selection still on `alpha.txt`, a file — today's file menu has no New row at all, flat or otherwise, so this starts failing for the right reason).

- [ ] **Step 2: Run, confirm it fails**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: FAIL (no "New" item exists in the file-selected menu yet).

- [ ] **Step 3: Add `newSubmenu(for:)`**

```swift
private func newSubmenu(for pane: PaneController) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ id: String) {
        let it = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = [id]
        menu.addItem(it)
    }
    add("Folder", "newFolder")
    add("Text File", "newFile")
    return menu
}
```

- [ ] **Step 4: Replace the flat rows with the submenu, in both branches**

In the empty-space branch, change:

```swift
add("New Folder", "newFolder")
add("New Text File", "newFile")
```

to:

```swift
let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
newItem.submenu = newSubmenu(for: pane)
menu.addItem(newItem)
```

In the non-empty branch, add the same 3 lines right after the Cut/Copy/Paste block Task 2 just added (before `add("Quick Look", "quickLook")` — or immediately after it, matching the mockups' ordering of New right after Cut/Copy/Paste/Copy Path; since Copy Path is added later in the function, simplest correct placement here is right after the new separator Task 2 added).

- [ ] **Step 5: Build and run**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add FileeMac/Sources/BrowserWindow.swift qa.py
git commit -m "feat: New is a real submenu (Folder, Text File), in the file menu too"
```

---

### Task 4: Word and Excel from blank templates

**Files:**
- Create (generated once, not committed as a script): a throwaway Python script that writes `FileeMac/Resources/Templates/Blank.docx` and `Blank.xlsx`.
- Commit: `FileeMac/Resources/Templates/Blank.docx`, `FileeMac/Resources/Templates/Blank.xlsx` (binary).
- Modify: `FileeCore/Sources/FileeCore/FileOperations.swift` (add `FileOps.copyTemplate`), `FileeMac/Sources/Operations.swift` (add `OperationCenter.newFromTemplate`), `FileeMac/Sources/BrowserWindow.swift` (`perform`, `newSubmenu(for:)`), `project.yml`.
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`, `qa.py`'s `ops` suite.

**Interfaces:**
- Consumes: Task 3's `newSubmenu(for:)`.
- Produces: `FileOps.copyTemplate(_ templateURL: URL, baseName: String, ext: String, in folder: String) throws -> String`; `OperationCenter.newFromTemplate(_ templateURL: URL, baseName: String, ext: String, in folder: String) -> String?`.

- [ ] **Step 1: Generate the two template files**

Run this once, locally, then discard the script (only the 2 output files get committed):

```python
import zipfile

def write(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in files.items():
            z.writestr(name, content)

XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'

write("FileeMac/Resources/Templates/Blank.docx", {
    "[Content_Types].xml": XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>',
    "_rels/.rels": XML + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    "word/document.xml": XML + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p/><w:sectPr/></w:body></w:document>',
})

write("FileeMac/Resources/Templates/Blank.xlsx", {
    "[Content_Types].xml": XML + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '</Types>',
    "_rels/.rels": XML + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    "xl/workbook.xml": XML + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": XML + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>',
    "xl/worksheets/sheet1.xml": XML + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>',
})
```

Verify both open cleanly in Word/Excel (or Pages/Numbers) before continuing — this is the one step in this plan that genuinely needs a human eyeball, since no XCTest can confirm Word accepts a file as non-corrupt.

- [ ] **Step 2: Register the resources in `project.yml`**

Under `targets.Filee.sources`, add, next to the existing `AppIcon.icns`/`Logo.png` entries:

```yaml
- path: FileeMac/Resources/Templates/Blank.docx
  buildPhase: resources
- path: FileeMac/Resources/Templates/Blank.xlsx
  buildPhase: resources
```

- [ ] **Step 3: Write the failing FileeCore test**

```swift
func testCopyTemplateGetsAUniqueName() throws {
    touch("Blank.docx", "pretend-zip-bytes")
    let template = URL(fileURLWithPath: path("Blank.docx"))
    let first = try FileOps.copyTemplate(template, baseName: "New Document", ext: "docx", in: root)
    let second = try FileOps.copyTemplate(template, baseName: "New Document", ext: "docx", in: root)
    XCTAssertEqual((first as NSString).lastPathComponent, "New Document.docx")
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second)), Data("pretend-zip-bytes".utf8))
}
```

- [ ] **Step 4: Run, confirm it fails**

Run: `cd FileeCore && swift test --filter testCopyTemplateGetsAUniqueName`
Expected: FAIL — `copyTemplate` doesn't exist.

- [ ] **Step 5: Implement `FileOps.copyTemplate` in `FileeCore/Sources/FileeCore/FileOperations.swift`**

```swift
public static func copyTemplate(_ templateURL: URL, baseName: String, ext: String, in folder: String) throws -> String {
    let name = uniqueName("\(baseName).\(ext)", in: folder)
    let dest = (folder as NSString).appendingPathComponent(name)
    try FileManager.default.copyItem(at: templateURL, to: URL(fileURLWithPath: dest))
    return dest
}
```

- [ ] **Step 6: Run, confirm it passes**

Run: `cd FileeCore && swift test --filter testCopyTemplateGetsAUniqueName`
Expected: PASS.

- [ ] **Step 7: Add `OperationCenter.newFromTemplate` in `FileeMac/Sources/Operations.swift`**

```swift
func newFromTemplate(_ templateURL: URL, baseName: String, ext: String, in folder: String) -> String? {
    guard !refuseIfReadOnly() else { return nil }
    do {
        let path = try FileOps.copyTemplate(templateURL, baseName: baseName, ext: ext, in: folder)
        undoStack.push(.created([path]))
        touched([folder])
        return path
    } catch {
        window?.showMessage("❌ \(error.localizedDescription)", error: true)
        return nil
    }
}
```

(Same shape as `newFolder`/`newFile` just above it in the same file — match their position and style.)

- [ ] **Step 8: Wire it into `perform` and the New submenu**

In `BrowserWindow.swift`, add a private helper next to `openWith()`:

```swift
private func newFromTemplate(ext: String, baseName: String) {
    guard let template = Bundle.main.url(forResource: "Blank", withExtension: ext, subdirectory: "Templates") else {
        showMessage("❌ Template for .\(ext) not found", error: true)
        return
    }
    let pane = activePane
    let folder = pane.selectedItems.first?.parent ?? pane.targetFolder
    if let p = OperationCenter.shared.newFromTemplate(template, baseName: baseName, ext: ext, in: folder) {
        selectAndRename(p, in: pane)
    }
}
```

Add to `perform`'s switch:

```swift
case "newWordDoc": newFromTemplate(ext: "docx", baseName: "New Document")
case "newExcelDoc": newFromTemplate(ext: "xlsx", baseName: "New Spreadsheet")
```

Add to `newSubmenu(for:)` (Task 3), after Text File:

```swift
add("Word Document", "newWordDoc")
add("Excel Spreadsheet", "newExcelDoc")
```

- [ ] **Step 9: QA step**

```python
{"op": "command", "id": "newWordDoc"},
{"op": "expect", "label": "New Word Document from the template", "exists": A + "/New Document.docx"},
{"op": "command", "id": "newExcelDoc"},
{"op": "expect", "label": "New Excel Spreadsheet from the template", "exists": A + "/New Spreadsheet.xlsx"},
```

- [ ] **Step 10: Build and run everything**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add FileeCore/Sources/FileeCore/FileOperations.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift \
        FileeMac/Sources/Operations.swift FileeMac/Sources/BrowserWindow.swift project.yml \
        FileeMac/Resources/Templates/Blank.docx FileeMac/Resources/Templates/Blank.xlsx qa.py
git commit -m "feat: New > Word Document / Excel Spreadsheet, copied from blank templates"
```

---

### Task 5: Convert to JPEG

**Files:**
- Create: `FileeCore/Sources/FileeCore/ImageConvert.swift`
- Modify: `FileeMac/Sources/Operations.swift`, `FileeMac/Sources/BrowserWindow.swift`
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`, `qa.py`'s `ops` suite

**Interfaces:**
- Produces: `ImageConvert.toJPEG(_ path: String, quality: Double = 0.9) throws -> String`; `OperationCenter.convertToJPEG(_ paths: [String], completion: @escaping ([String]) -> Void)`.
- Consumes (for the menu condition): `FileItem.ext`, already public.

- [ ] **Step 1: Write the failing FileeCore test**

```swift
func testConvertToJPEGKeepsOriginalAndMakesAReadableJPEG() throws {
    // A real 2x2 PNG, not just arbitrary bytes, so ImageIO can decode it.
    let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4AQEEAAH/AP8AAAAyAAFmrUGdAAAAAElFTkSuQmCC")!
    try png.write(to: URL(fileURLWithPath: path("pixel.png")))
    let out = try ImageConvert.toJPEG(path("pixel.png"))
    XCTAssertEqual((out as NSString).pathExtension, "jpg")
    XCTAssertTrue(fm.fileExists(atPath: path("pixel.png")), "the original stays")
    XCTAssertTrue(fm.fileExists(atPath: out))
}

func testConvertToJPEGRefusesAnUnreadableFile() {
    touch("not-an-image.png", "not actually a png")
    XCTAssertThrowsError(try ImageConvert.toJPEG(path("not-an-image.png")))
}
```

- [ ] **Step 2: Run, confirm it fails**

Run: `cd FileeCore && swift test --filter testConvertToJPEG`
Expected: FAIL — `ImageConvert` doesn't exist.

- [ ] **Step 3: Implement `ImageConvert.toJPEG` in `FileeCore/Sources/FileeCore/ImageConvert.swift`**

```swift
import CoreGraphics
import ImageIO

public enum ImageConvert {
    /// Converts 1 image to JPEG next to the original, keeping it. Returns the new file's path.
    public static func toJPEG(_ path: String, quality: Double = 0.9) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): not a readable image")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = FileOps.uniqueName("\(stem).jpg", in: folder)
        let dest = (folder as NSString).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dest) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw OperationError.failed("Convert to JPEG", "can't create \(name)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationError.failed("Convert to JPEG", "can't write \(name)")
        }
        return dest
    }
}
```

- [ ] **Step 4: Run, confirm it passes**

Run: `cd FileeCore && swift test --filter testConvertToJPEG`
Expected: PASS.

- [ ] **Step 5: Add `OperationCenter.convertToJPEG`, same shape as `extract` (per-item, continues past 1 failure)**

```swift
func convertToJPEG(_ paths: [String], completion: @escaping ([String]) -> Void) {
    guard !paths.isEmpty, !refuseIfReadOnly() else { return }
    window?.showMessage("Converting \(Format.items(paths.count))…")
    queue.async { [weak self] in
        var out: [String] = []
        var errors: [String] = []
        for p in paths {
            do { out.append(try ImageConvert.toJPEG(p)) } catch { errors.append(error.localizedDescription) }
        }
        DispatchQueue.main.async {
            if !out.isEmpty { self?.undoStack.push(.created(out)) }
            if errors.isEmpty {
                self?.window?.showMessage("✅ Converted \(Format.items(out.count))")
            } else {
                self?.window?.showMessage("❌ " + errors.prefix(2).joined(separator: " · "), error: true)
            }
            self?.touched(paths.map { ($0 as NSString).deletingLastPathComponent })
            completion(out)
        }
    }
}
```

- [ ] **Step 6: Wire into `perform` and the menu**

```swift
case "convertToJPEG":
    let imgs = pane.selectedItems.filter { Self.imageExts.contains($0.ext) }.map(\.path)
    guard !imgs.isEmpty else { return beep() }
    ops.convertToJPEG(imgs) { [weak self] out in self?.selectInPanes(out) }
```

Add, as a `static let` near the top of `BrowserWindowController` (Task 6 reuses it):

```swift
static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic"]
```

In `contextMenu(for:in:)`, right after the `add(items.count == 1 ? "Rename…" : "Batch Rename…", ...)` line and before `add("Add Today's Date...)`, add:

```swift
let allImages = !files.isEmpty && files.allSatisfy { Self.imageExts.contains($0.ext) }
if allImages {
    add("Convert to JPEG" + (files.count > 1 ? " (\(files.count) files)" : ""), "convertToJPEG")
}
```

- [ ] **Step 7: QA steps**

```python
{"op": "select", "pane": 0, "names": ["IMG01.png"]},
{"op": "expect", "label": "Convert to JPEG shows for an image", "menuContains": ["Convert to JPEG"]},
{"op": "command", "id": "convertToJPEG"},
{"op": "waitIdle"},
{"op": "expect", "label": "Convert to JPEG writes a .jpg next to the original", "exists": [A + "/IMG01.png", A + "/IMG01.jpg"]},
{"op": "select", "pane": 0, "names": ["alpha.txt"]},
{"op": "expect", "label": "Convert to JPEG does not show for a text file", "menuExcludes": ["Convert to JPEG"]},
```

(`IMG01.png` already exists as a fixture — it's used by the `browse` suite's Get Info test.)

- [ ] **Step 8: Build and run everything**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add FileeCore/Sources/FileeCore/ImageConvert.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift \
        FileeMac/Sources/Operations.swift FileeMac/Sources/BrowserWindow.swift qa.py
git commit -m "feat: Convert to JPEG, images only, originals kept"
```

---

### Task 6: Create PDF from selection

**Files:**
- Create: `FileeCore/Sources/FileeCore/PDFBuilder.swift`
- Modify: `FileeMac/Sources/Operations.swift`, `FileeMac/Sources/BrowserWindow.swift`
- Test: `FileeCore/Tests/FileeCoreTests/CoreTests.swift`, `qa.py`'s `ops` suite

**Interfaces:**
- Consumes: `BrowserWindowController.imageExts` (Task 5).
- Produces: `PDFBuilder.fromImages(_ paths: [String]) throws -> String`; `OperationCenter.createPDF(from: [String], completion: @escaping (String?) -> Void)`.

- [ ] **Step 1: Write the failing FileeCore test**

```swift
func testPDFFromImagesHas1PagePerImage() throws {
    let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4AQEEAAH/AP8AAAAyAAFmrUGdAAAAAElFTkSuQmCC")!
    try png.write(to: URL(fileURLWithPath: path("a.png")))
    try png.write(to: URL(fileURLWithPath: path("b.png")))
    let pdf = try PDFBuilder.fromImages([path("a.png"), path("b.png")])
    XCTAssertEqual((pdf as NSString).pathExtension, "pdf")
    let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL)
    XCTAssertEqual(doc?.numberOfPages, 2)
}
```

- [ ] **Step 2: Run, confirm it fails**

Run: `cd FileeCore && swift test --filter testPDFFromImages`
Expected: FAIL — `PDFBuilder` doesn't exist.

- [ ] **Step 3: Implement `PDFBuilder.fromImages` in `FileeCore/Sources/FileeCore/PDFBuilder.swift`**

```swift
import CoreGraphics
import ImageIO

public enum PDFBuilder {
    /// Combines images into 1 PDF, 1 page per image in the given order, next to the first image. Returns the PDF's path.
    public static func fromImages(_ paths: [String]) throws -> String {
        guard let first = paths.first else { throw OperationError.failed("Create PDF", "nothing selected") }
        let folder = (first as NSString).deletingLastPathComponent
        let base = paths.count == 1 ? ((first as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf" : "Document.pdf"
        let dest = (folder as NSString).appendingPathComponent(FileOps.uniqueName(base, in: folder))
        guard let context = CGContext(URL(fileURLWithPath: dest) as CFURL, mediaBox: nil, nil) else {
            throw OperationError.failed("Create PDF", "can't create \(dest)")
        }
        for p in paths {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OperationError.failed("Create PDF", "\((p as NSString).lastPathComponent): not a readable image")
            }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return dest
    }
}
```

- [ ] **Step 4: Run, confirm it passes**

Run: `cd FileeCore && swift test --filter testPDFFromImages`
Expected: PASS.

- [ ] **Step 5: Add `OperationCenter.createPDF`, same shape as `compress`**

```swift
func createPDF(from paths: [String], completion: @escaping (String?) -> Void) {
    guard !paths.isEmpty, !refuseIfReadOnly() else { return }
    window?.showMessage("Creating PDF from \(Format.items(paths.count))…")
    queue.async { [weak self] in
        let result = Result { try PDFBuilder.fromImages(paths) }
        DispatchQueue.main.async {
            switch result {
            case .success(let pdf):
                self?.undoStack.push(.created([pdf]))
                self?.window?.showMessage("✅ \((pdf as NSString).lastPathComponent)")
                self?.touched([(pdf as NSString).deletingLastPathComponent])
                completion(pdf)
            case .failure(let e):
                self?.window?.showMessage("❌ \(e.localizedDescription)", error: true)
                completion(nil)
            }
        }
    }
}
```

- [ ] **Step 6: Wire into `perform` and the menu**

```swift
case "createPDF":
    let imgs = pane.selectedItems.filter { Self.imageExts.contains($0.ext) }.map(\.path)
    guard !imgs.isEmpty else { return beep() }
    ops.createPDF(from: imgs) { [weak self] pdf in if let pdf { self?.selectInPanes([pdf]) } }
```

In `contextMenu(for:in:)`, right after the `Convert to JPEG` line Task 5 added, inside the same `if allImages { ... }` block:

```swift
add("Create PDF from Selection", "createPDF")
```

- [ ] **Step 7: QA steps**

```python
{"op": "select", "pane": 0, "names": ["IMG01.png"]},
{"op": "expect", "label": "Create PDF from Selection shows for an image", "menuContains": ["Create PDF from Selection"]},
{"op": "command", "id": "createPDF"},
{"op": "waitIdle"},
{"op": "expect", "label": "Create PDF writes a .pdf next to the image", "exists": A + "/IMG01.pdf"},
```

- [ ] **Step 8: Build and run everything**

Run: `./build.sh --test && python3 qa.py --only ops`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add FileeCore/Sources/FileeCore/PDFBuilder.swift FileeCore/Tests/FileeCoreTests/CoreTests.swift \
        FileeMac/Sources/Operations.swift FileeMac/Sources/BrowserWindow.swift qa.py
git commit -m "feat: Create PDF from Selection, images only, originals kept"
```

---

### Task 7: Open With gets an "Always Open" row

**Files:**
- Modify: `FileeMac/Sources/BrowserWindow.swift` (`OpenWithMenu`, around line 887)
- Test: manual (QA harness doesn't simulate real mouse clicks with modifier flags; see Step 5)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new (leaf feature).

- [ ] **Step 1: Add the hint row and the ⌥-click behavior in `OpenWithMenu.menuNeedsUpdate`**

Change the per-app `ClosureMenuItem` action from:

```swift
let item = ClosureMenuItem(title: title) {
    NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}
```

to:

```swift
let item = ClosureMenuItem(title: title) {
    if NSEvent.modifierFlags.contains(.option), let ext = files.first?.pathExtension, let type = UTType(filenameExtension: ext) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }
    NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}
```

Then, right after the `for app in apps { ... }` loop and before `if apps.isEmpty`, add an always-visible hint row when there's a resolvable extension:

```swift
if let ext = files.first?.pathExtension, !ext.isEmpty {
    addItem(.separator())
    addItem(NSMenuItem(title: "⌥-click an app to always open .\(ext) with it", action: nil, keyEquivalent: ""))
}
```

- [ ] **Step 2: Build**

Run: `./build.sh --test`
Expected: builds clean.

- [ ] **Step 3: Manual check against `~/FileeTest`**

Right-click a PDF in `~/FileeTest`, open Open With, ⌥-click an app that isn't already Preview, confirm the hint row reads correctly and the app opens. Right-click the same PDF again: the app you ⌥-clicked now shows "(default)".

- [ ] **Step 4: Confirm the rest of the suite still passes**

Run: `python3 qa.py`
Expected: PASS (this task touches no row `qa.py` already asserts on).

- [ ] **Step 5: Commit**

```bash
git add FileeMac/Sources/BrowserWindow.swift
git commit -m "feat: Open With — option-click an app to make it the default for that extension"
```

---

## Self-Review

**1. Spec coverage:** Cut/Copy/Paste (Task 2) · empty-space New/Terminal/Paste (Tasks 2–3) · New submenu incl. Word/Excel templates (Tasks 3–4) · Convert to JPEG (Task 5) · Create PDF from selection (Task 6) · file-type-conditional rows (Tasks 5–6's `allImages` guard, same pattern as today's `zip` check) · Open With "always open" (Task 7). Copy Path, Open With's app list, ZIP, New Folder/Text File, Open Terminal Here, and file-type custom actions were already in Filee and needed no task — confirmed by reading the code, not assumed.

**2. Step scan:** every code step gives the exact signature plus the exact body where the body is pinned by the spec (template XML, PDF/JPEG writing) or copies an established in-file pattern 1:1 (`extract`/`compress`); every test step names its exact assertions; every verification step names its exact command and expected result.

**3. Type consistency:** `Self.imageExts` is defined once in Task 5 and reused as-is in Task 6; `FileOps.copyTemplate`/`ImageConvert.toJPEG`/`PDFBuilder.fromImages` signatures match their call sites in `OperationCenter` exactly; `OperationCenter`'s 3 new methods all follow the existing `compress`/`extract`/`newFolder` naming and parameter order.

**4. Review Focus:** mixed-type selection → `allImages`/non-image guards in Tasks 5–6. Folder selection → unchanged existing Open With guard, confirmed by reading the code (Task list, "already in Filee"), exercised indirectly by the `ops` suite's existing folder selections. Partial-batch failure → `convertToJPEG`'s per-item `do`/`catch` (Task 5 Step 5), mirroring `extract`. Name collision → `FileOps.uniqueName` reused everywhere new files are created (Tasks 4–6), with Task 4's unit test pinning it directly. Default-app persistence → Task 7 Step 3's manual relaunch-free re-check (closing the full loop — confirming survival across an actual relaunch — is left as a manual follow-up the user can do once living with the build, since QA harness has no modifier-key click simulation to automate it).

**5. Proportion:** 7 tasks for 7 pieces of spec, each a few steps; no task's code block is longer than the function it describes once signatures are factored out.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-11-12-phase1-right-click-menu.md`. Please review the plan. Which execution approach would you prefer?

- **Subagent-driven** — a fresh subagent implements each task and a fresh reviewer checks it before the next one starts, then a whole-branch review at the end. Most thorough; costs a fresh context per task and per review.
- **Native** — I implement every task myself in this session, the way this harness runs work, then one fresh reviewer on the most capable model checks the whole branch. Cheapest and fastest; no independent review until the end.

For this plan I recommend **Native**: the 7 tasks are almost entirely independent (each adds its own menu row(s) and, at most, reads a `Set` defined 1 task earlier), none is large, and a shipped mistake here costs you re-running `qa.py` and a `git revert` — not a redesign. Does the plan capture what you want, and which approach should we use?
