import CoreGraphics
import ImageIO
import XCTest
@testable import FileeCore

final class CoreTests: XCTestCase {
    var root: String!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("filee-tests-\(UUID().uuidString)")
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { (root as NSString).appendingPathComponent(rel) }

    func touch(_ rel: String, _ text: String = "x") {
        let p = path(rel)
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: Data(text.utf8))
    }

    // MARK: Listing

    func testListerMatchesFileManager() throws {
        touch("a.txt", "hello")
        touch("B.md", String(repeating: "z", count: 5000))
        touch(".hidden", "h")
        touch("sub/inner.txt")
        try fm.createDirectory(atPath: path("Thing.app/Contents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path("link-to-sub"), withDestinationPath: path("sub"))
        try fm.createSymbolicLink(atPath: path("link-to-file"), withDestinationPath: path("a.txt"))

        let items = try DirectoryLister.list(root)
        let names = Set(items.map(\.name))
        let expected = Set(try fm.contentsOfDirectory(atPath: root))
        XCTAssertEqual(names, expected)

        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["a.txt"]?.size, 5)
        XCTAssertEqual(byName["B.md"]?.size, 5000)
        XCTAssertEqual(byName["a.txt"]?.kind, .file)
        XCTAssertTrue(byName[".hidden"]!.isHidden)
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        XCTAssertEqual(byName["sub"]?.entryCount, 1)
        XCTAssertTrue(byName["sub"]!.isFolder)
        XCTAssertTrue(byName["Thing.app"]!.isPackage)
        XCTAssertFalse(byName["Thing.app"]!.isFolder)
        XCTAssertEqual(byName["link-to-sub"]?.kind, .symlink)
        XCTAssertTrue(byName["link-to-sub"]!.targetIsDirectory)
        XCTAssertTrue(byName["link-to-sub"]!.isFolder)
        XCTAssertFalse(byName["link-to-file"]!.isFolder)

        let attrs = try fm.attributesOfItem(atPath: path("a.txt"))
        let mod = (attrs[.modificationDate] as! Date).timeIntervalSince1970
        XCTAssertEqual(byName["a.txt"]!.modified, mod, accuracy: 0.01)
        XCTAssertGreaterThan(byName["a.txt"]!.added, 0)
        XCTAssertTrue(byName["a.txt"]!.isNew(since: startOfDay()))
        XCTAssertEqual(byName["a.txt"]!.path, path("a.txt"))
    }

    func testListerLargeFolder() throws {
        for i in 0..<3000 { touch("many/file-\(i).txt") }
        let start = Date()
        let items = try DirectoryLister.list(path("many"))
        let ms = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(items.count, 3000)
        XCTAssertLessThan(ms, 150)
    }

    func testListerMissingFolder() {
        XCTAssertThrowsError(try DirectoryLister.list(path("nope")))
    }

    func testTotalSize() {
        touch("t/a", String(repeating: "a", count: 100))
        touch("t/b/c", String(repeating: "a", count: 50))
        let r = DirectoryLister.totalSize(path("t"))
        XCTAssertEqual(r.bytes, 150)
        XCTAssertEqual(r.files, 2)
    }

    func testUsage() throws {
        touch("u/a", String(repeating: "a", count: 100))
        touch("u/b/c", String(repeating: "a", count: 5000))
        touch("u/b/d/e", "e")
        try fm.createSymbolicLink(atPath: path("u/link"), withDestinationPath: path("u/b"))
        let u = DirectoryLister.usage(path("u"))
        XCTAssertEqual(u.files, 4)
        XCTAssertEqual(u.folders, 2)
        XCTAssertGreaterThanOrEqual(u.bytes, 5101)
        XCTAssertGreaterThanOrEqual(u.allocated, 3 * 4096)
    }

    // MARK: Formatting

    func testFormatSize() {
        XCTAssertEqual(Format.size(512), "512 B")
        XCTAssertEqual(Format.size(1536), "1.5 KB")
        XCTAssertEqual(Format.size(10 * 1024 * 1024), "10.0 MB")
        XCTAssertEqual(Format.size(-1), "--")
    }

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

    func testFormatDate() {
        let now = Date()
        XCTAssertTrue(Format.date(now.timeIntervalSince1970, now: now).hasPrefix("today "))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertTrue(Format.date(yesterday.timeIntervalSince1970, now: now).hasPrefix("yesterday "))
        let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(Format.date(old.timeIntervalSince1970, now: now).count, 16)
    }

    // MARK: Fuzzy

    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("rdmp", "roadmap.pptx"))
        XCTAssertNil(Fuzzy.score("xyz", "roadmap.pptx"))
        XCTAssertGreaterThan(Fuzzy.score("road", "roadmap.pptx")!, Fuzzy.score("road", "the-old-rad-doc.pptx") ?? -999)
        // Smart case.
        XCTAssertNil(Fuzzy.score("Road", "roadmap.pptx"))
        // Scattered letters across a long name don't match.
        XCTAssertNil(Fuzzy.score("road", "notes for the world summit ai in amsterdam with a long name.md"))
        XCTAssertNotNil(Fuzzy.score("wsa", "world summit ai.md"))
        let names = ["alpha.txt", "260320-roadmap.pptx", "notes.md", "Roadmap old.key"]
        let m = Fuzzy.matches(names, query: "roadmap") { $0 }
        XCTAssertEqual(m.indices, [1, 3])
        XCTAssertNotNil(m.best)
    }

    // MARK: Names and operations

    func testUniqueName() {
        touch("u/report.pdf")
        touch("u/report 2.pdf")
        XCTAssertEqual(FileOps.uniqueName("report.pdf", in: path("u")), "report 3.pdf")
        XCTAssertEqual(FileOps.uniqueName("other.pdf", in: path("u")), "other.pdf")
        try? fm.createDirectory(atPath: path("u/folder"), withIntermediateDirectories: true)
        XCTAssertEqual(FileOps.uniqueName("folder", in: path("u")), "folder 2")
        touch("u/.env")
        XCTAssertEqual(FileOps.uniqueName(".env", in: path("u")), ".env 2")
    }

    func testCopyTemplateGetsAUniqueName() throws {
        touch("Blank.docx", "pretend-zip-bytes")
        let template = URL(fileURLWithPath: path("Blank.docx"))
        let first = try FileOps.copyTemplate(template, baseName: "New Document", ext: "docx", in: root)
        let second = try FileOps.copyTemplate(template, baseName: "New Document", ext: "docx", in: root)
        XCTAssertEqual((first as NSString).lastPathComponent, "New Document.docx")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second)), Data("pretend-zip-bytes".utf8))
    }

    func testCopyWithProgressAndUndo() throws {
        touch("src/big.bin", String(repeating: "q", count: 3_000_000))
        touch("src/folder/x.txt", "x")
        try fm.createDirectory(atPath: path("dst"), withIntermediateDirectories: true)
        let t = Transfer(mode: .copy, sources: [path("src/big.bin"), path("src/folder")], into: path("dst"))
        var last: OperationProgress?
        t.onProgress = { last = $0 }
        let record = t.run()
        XCTAssertTrue(t.errors.isEmpty, "\(t.errors)")
        XCTAssertTrue(fm.fileExists(atPath: path("dst/big.bin")))
        XCTAssertTrue(fm.fileExists(atPath: path("dst/folder/x.txt")))
        XCTAssertEqual(last?.itemsDone, 2)
        XCTAssertEqual(last?.bytesTotal, 3_000_001)
        // Undo of a copy moves the copies to the Trash.
        let redo = try record!.revert()
        XCTAssertFalse(fm.fileExists(atPath: path("dst/big.bin")))
        if case .trashed(let pairs) = redo {
            for p in pairs { try? fm.removeItem(atPath: p.to) }
        } else {
            XCTFail("expected trashed")
        }
    }

    func testCopyConflictKeepBothAndReplace() throws {
        touch("c/a.txt", "new")
        touch("d/a.txt", "old")
        let t = Transfer(mode: .copy, sources: [path("c/a.txt")], into: path("d"))
        t.resolveConflict = { _ in (.keepBoth, false) }
        _ = t.run()
        XCTAssertTrue(fm.fileExists(atPath: path("d/a 2.txt")))
        let t2 = Transfer(mode: .copy, sources: [path("c/a.txt")], into: path("d"))
        t2.resolveConflict = { _ in (.replace, false) }
        _ = t2.run()
        XCTAssertEqual(try String(contentsOfFile: path("d/a.txt"), encoding: .utf8), "new")
        let t3 = Transfer(mode: .copy, sources: [path("c/a.txt")], into: path("d"))
        t3.resolveConflict = { _ in (.skip, true) }
        XCTAssertNil(t3.run())
    }

    func testCopyIntoItselfFails() {
        touch("loop/a.txt")
        let t = Transfer(mode: .copy, sources: [path("loop")], into: path("loop"))
        _ = t.run()
        // Copying a folder into its own folder makes a duplicate next to it, not inside.
        let t2 = Transfer(mode: .copy, sources: [path("loop")], into: path("loop/a.txt").replacingOccurrences(of: "/a.txt", with: ""))
        _ = t2.run()
        XCTAssertThrowsError(try FileOps.copyItem(path("loop"), to: path("loop/inside")))
    }

    func testDuplicateInSameFolder() throws {
        touch("dup/a.txt")
        let t = Transfer(mode: .copy, sources: [path("dup/a.txt")], into: path("dup"))
        _ = t.run()
        XCTAssertTrue(fm.fileExists(atPath: path("dup/a 2.txt")))
    }

    func testMoveAndUndo() throws {
        touch("m1/file.txt", "m")
        try fm.createDirectory(atPath: path("m2"), withIntermediateDirectories: true)
        let t = Transfer(mode: .move, sources: [path("m1/file.txt")], into: path("m2"))
        let rec = t.run()
        XCTAssertTrue(fm.fileExists(atPath: path("m2/file.txt")))
        XCTAssertFalse(fm.fileExists(atPath: path("m1/file.txt")))
        let redo = try rec!.revert()
        XCTAssertTrue(fm.fileExists(atPath: path("m1/file.txt")))
        _ = try redo.revert()
        XCTAssertTrue(fm.fileExists(atPath: path("m2/file.txt")))
    }

    func testTrashAndPutBack() throws {
        touch("tr/gone.txt", "bye")
        let inTrash = try FileOps.trash(path("tr/gone.txt"))
        XCTAssertFalse(fm.fileExists(atPath: path("tr/gone.txt")))
        let rec = UndoRecord.trashed([.init(path("tr/gone.txt"), inTrash)])
        _ = try rec.revert()
        XCTAssertTrue(fm.fileExists(atPath: path("tr/gone.txt")))
    }

    func testCancelCopy() {
        touch("cc/a.bin", String(repeating: "a", count: 1000))
        try? fm.createDirectory(atPath: path("cc2"), withIntermediateDirectories: true)
        let t = Transfer(mode: .copy, sources: [path("cc/a.bin")], into: path("cc2"))
        t.cancel.cancel()
        XCTAssertNil(t.run())
        XCTAssertFalse(fm.fileExists(atPath: path("cc2/a.bin")))
    }

    // MARK: Rename

    func testSequenceRename() throws {
        for i in 1...3 { touch("r/IMG0\(i).jpg") }
        let paths = (1...3).map { path("r/IMG0\($0).jpg") }
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 8).date!
        let plan = Renamer.plan(paths, mode: .sequence(base: "YYMMDD-world-summit-ai"), dateOf: { _ in date })
        XCTAssertEqual(plan.entries.map(\.newName), ["261008-world-summit-ai_01.jpg", "261008-world-summit-ai_02.jpg", "261008-world-summit-ai_03.jpg"])
        XCTAssertTrue(plan.isValid)
        let pairs = try Renamer.apply(plan)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(fm.fileExists(atPath: path("r/261008-world-summit-ai_02.jpg")))
        // Undo puts the old names back.
        _ = try UndoRecord.moved(pairs).revert()
        XCTAssertTrue(fm.fileExists(atPath: path("r/IMG02.jpg")))
    }

    func testSequenceWidthAndSingle() {
        let many = (1...120).map { path("w/f\($0).png") }
        let plan = Renamer.plan(many, mode: .sequence(base: "x"), dateOf: { _ in nil })
        XCTAssertEqual(plan.entries[0].newName, "x_001.png")
        XCTAssertEqual(plan.entries[119].newName, "x_120.png")
        touch("one/IMG.jpg")
        let single = Renamer.plan([path("one/IMG.jpg")], mode: .sequence(base: "solo"), dateOf: { _ in nil })
        XCTAssertEqual(single.entries[0].newName, "solo.jpg")
    }

    func testRenameSwapAndConflicts() throws {
        touch("s/a.txt", "A")
        touch("s/b.txt", "B")
        touch("s/c.txt", "C")
        // Swap a and b via a regex that maps a->b and b->a is hard; build the plan by hand.
        var plan = RenamePlan(entries: [
            .init(path: path("s/a.txt"), oldName: "a.txt", newName: "b.txt"),
            .init(path: path("s/b.txt"), oldName: "b.txt", newName: "a.txt"),
        ])
        plan = Renamer.check(plan.entries)
        XCTAssertTrue(plan.isValid, "\(plan.entries)")
        _ = try Renamer.apply(plan)
        XCTAssertEqual(try String(contentsOfFile: path("s/a.txt"), encoding: .utf8), "B")
        // Renaming a to c (not in the batch) is a conflict.
        let bad = Renamer.check([.init(path: path("s/a.txt"), oldName: "a.txt", newName: "c.txt")])
        XCTAssertFalse(bad.isValid)
        // 2 files to the same name.
        let dup = Renamer.plan([path("s/a.txt"), path("s/b.txt")], mode: .replace(find: "[ab]", with: "z", regex: true, caseSensitive: true))
        XCTAssertFalse(dup.isValid)
        XCTAssertNotNil(dup.entries[1].problem)
    }

    func testOtherRenameModes() {
        touch("o/Café Menu_Final.PDF")
        let p = [path("o/Café Menu_Final.PDF")]
        XCTAssertEqual(Renamer.plan(p, mode: .slugify).entries[0].newName, "cafe-menu-final.PDF")
        XCTAssertEqual(Renamer.plan(p, mode: .lower).entries[0].newName, "café menu_final.PDF")
        XCTAssertEqual(Renamer.plan(p, mode: .replace(find: "final", with: "v2", regex: false, caseSensitive: false)).entries[0].newName, "Café Menu_v2.PDF")
        let d = DateComponents(calendar: .current, year: 2026, month: 1, day: 2).date!
        XCTAssertEqual(Renamer.plan(p, mode: .prefixDate, dateOf: { _ in d }).entries[0].newName, "260102-Café Menu_Final.PDF")
        touch("o/261010-already.md")
        XCTAssertEqual(Renamer.plan([path("o/261010-already.md")], mode: .prefixDate, dateOf: { _ in d }).entries[0].newName, "261010-already.md")
        let today = Renamer.yymmdd(Date())
        XCTAssertEqual(Renamer.plan(p, mode: .prefixToday, dateOf: { _ in d }).entries[0].newName, "\(today)-Café Menu_Final.PDF")
        XCTAssertEqual(Renamer.plan([path("o/261010-already.md")], mode: .prefixToday).entries[0].newName, "261010-already.md")
    }

    // MARK: Archive

    func testZipRoundTrip() throws {
        touch("z/doc/a.txt", "alpha")
        touch("z/doc/b/c.txt", "gamma")
        let zip = try Archive.compress([path("z/doc")])
        XCTAssertEqual((zip as NSString).lastPathComponent, "doc.zip")
        try fm.moveItem(atPath: path("z/doc"), toPath: path("z/doc-orig"))
        let out = try Archive.extract(zip)
        XCTAssertEqual((out as NSString).lastPathComponent, "doc")
        XCTAssertEqual(try String(contentsOfFile: path("z/doc/b/c.txt"), encoding: .utf8), "gamma")

        touch("z2/one.txt", "1")
        touch("z2/two.txt", "2")
        let multi = try Archive.compress([path("z2/one.txt"), path("z2/two.txt")])
        XCTAssertEqual((multi as NSString).lastPathComponent, "Archive.zip")
        let outMulti = try Archive.extract(multi)
        XCTAssertTrue(fm.fileExists(atPath: (outMulti as NSString).appendingPathComponent("one.txt")))
    }

    // MARK: Image conversion

    func testConvertToJPEGKeepsOriginalAndMakesAReadableJPEG() throws {
        // A real 8x8 PNG, not just arbitrary bytes, so ImageIO can decode it. (Not 2x2: a probe showed
        // JPEG-encoding something that tiny doesn't round-trip on this platform — CGImageDestinationFinalize
        // returns true, but the written bytes have no decodable pixel data — which is a genuine encoder
        // limit unrelated to corruption, so the fixture needs to be large enough to round-trip for real.)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGM4YWSEFTEMLQkAc/tLAZi7j8gAAAAASUVORK5CYII=")!
        try png.write(to: URL(fileURLWithPath: path("pixel.png")))
        let out = try ImageConvert.toJPEG(path("pixel.png"))
        XCTAssertEqual((out as NSString).pathExtension, "jpg")
        XCTAssertTrue(fm.fileExists(atPath: path("pixel.png")), "the original stays")
        // Actually readable, not just present: this is the exact gap that let a broken JPEG pass before.
        let outSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil)!
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(outSource, 0, nil), "the output must actually decode")
        let props = CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any]
        XCTAssertEqual((props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 8)
    }

    func testConvertToJPEGRefusesAnUnreadableFile() {
        touch("not-an-image.png", "not actually a png")
        XCTAssertThrowsError(try ImageConvert.toJPEG(path("not-an-image.png")))
    }

    func testConvertToJPEGRefusesATruncatedImage() throws {
        // The same real PNG fixture as testConvertToJPEGKeepsOriginalAndMakesAReadableJPEG, but with only
        // part of its bytes written to disk — this is what a truncated/corrupt HEIC or PNG looks like on
        // disk. A probe against this exact fixture (CGImageSourceGetCount, then
        // CGImageDestinationAddImageFromSource + CGImageDestinationFinalize, exactly as toJPEG does)
        // confirmed CGImageSourceGetCount(source) > 0 (ImageIO is willing to say "yes, 1 image" from the
        // truncated header alone) AND CGImageDestinationFinalize returns true anyway — while the bytes it
        // wrote are a broken, unreadable "JPEG" with no pixel dimensions when re-opened. Neither of those
        // 2 checks alone (both present in the old code) catches this; only re-opening the written output
        // and requiring real pixel dimensions does.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4AQEEAAH/AP8AAAAyAAFmrUGdAAAAAElFTkSuQmCC")!
        let truncated = png.prefix(png.count * 2 / 3)
        try truncated.write(to: URL(fileURLWithPath: path("truncated.png")))
        XCTAssertThrowsError(try ImageConvert.toJPEG(path("truncated.png")))
        XCTAssertFalse(fm.fileExists(atPath: path("truncated.jpg")), "no partial/broken .jpg must be left behind")
    }

    func testConvertToJPEGPreservesEXIFOrientation() throws {
        // Build a tiny JPEG fixture tagged with a non-default EXIF orientation (6 = rotated 90° CW),
        // the way a real phone photo is stored: upright pixels, orientation metadata says how to
        // display them. If conversion decodes to a plain CGImage and re-adds it (losing metadata),
        // the output silently loses the tag; it must come back out the same as it went in.
        let src = path("rotated.jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let cgImage = context.makeImage()!
        let fixtureDest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: src) as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(fixtureDest, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(fixtureDest), "failed to write the orientation-6 fixture")

        // Sanity-check the fixture actually carries orientation 6 before converting it.
        let srcSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil)!
        let srcProps = CGImageSourceCopyPropertiesAtIndex(srcSource, 0, nil) as? [CFString: Any]
        XCTAssertEqual((srcProps?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)

        let out = try ImageConvert.toJPEG(src)
        let outSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil)!
        let outProps = CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any]
        XCTAssertEqual((outProps?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6,
                        "orientation must be preserved, not silently dropped/normalized to 1")
    }

    // MARK: PDF from images

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

    func testPDFFromImagesHonorsEXIFOrientation() throws {
        // Build a 4x2 (landscape) JPEG fixture tagged with orientation 6 (rotate 90° CW to display),
        // the way a real phone photo is stored: raw pixels are landscape, but the tag says the photo
        // is actually portrait. If PDFBuilder decoded the raw CGImage (losing the orientation tag,
        // like CGImageSourceCreateImageAtIndex does) and drew that directly, the PDF page would come
        // out landstape-shaped — wrong way round. Honoring the tag must flip the page to portrait.
        let src = path("rotated.jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let cgImage = context.makeImage()!
        let fixtureDest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: src) as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(fixtureDest, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(fixtureDest), "failed to write the orientation-6 fixture")

        // Sanity-check the fixture: raw stored pixels are 4x2 (landscape), tagged orientation 6.
        let srcSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil)!
        let srcProps = CGImageSourceCopyPropertiesAtIndex(srcSource, 0, nil) as? [CFString: Any]
        XCTAssertEqual((srcProps?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((srcProps?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((srcProps?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)

        let pdf = try PDFBuilder.fromImages([src])
        let doc = CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL)!
        let page = doc.page(at: 1)!
        let box = page.getBoxRect(.mediaBox)
        // Orientation 6 swaps width/height on display: the raw 4x2 source must become a 2x4 page.
        XCTAssertEqual(box.width, 2, "orientation must be baked in, not ignored")
        XCTAssertEqual(box.height, 4, "orientation must be baked in, not ignored")
    }

    func testPDFFromImagesLeavesNoPartialFileOnFailure() throws {
        // 1 good image followed by 1 unreadable "image" (garbage bytes with an image extension, same
        // trick as testConvertToJPEGRefusesAnUnreadableFile). fromImages must throw partway through the
        // page loop. Since the destination PDF is opened for writing before the loop runs, a naive
        // implementation leaves a broken, misleadingly-named partial file (e.g. "Document.pdf") behind
        // in the real folder — with no undo entry, since no path is ever returned to the caller.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEElEQVR4AQEEAAH/AP8AAAAyAAFmrUGdAAAAAElFTkSuQmCC")!
        try png.write(to: URL(fileURLWithPath: path("good.png")))
        touch("bad.png", "not actually a png")
        XCTAssertThrowsError(try PDFBuilder.fromImages([path("good.png"), path("bad.png")]))
        let leftoverPDFs = try fm.contentsOfDirectory(atPath: root).filter { ($0 as NSString).pathExtension == "pdf" }
        XCTAssertTrue(leftoverPDFs.isEmpty, "no partial PDF should be left behind on failure: found \(leftoverPDFs)")
    }

    // MARK: Actions and config

    func testActionExpansion() {
        let a = CustomAction(name: "t", command: ["~/bin/tool", "--in", "{path}", "--dir", "{dir}", "{stem}"])
        let inv = a.invocations(paths: ["/x/a.jpg", "/x/b.jpg"], dir: "/x")
        XCTAssertEqual(inv.count, 2)
        XCTAssertEqual(inv[0], ["~/bin/tool".expandingHome, "--in", "/x/a.jpg", "--dir", "/x", "a"])
        let all = CustomAction(name: "t", command: ["/usr/bin/open", "{paths}"], each: false)
        XCTAssertEqual(all.invocations(paths: ["/a", "/b"], dir: "/"), [["/usr/bin/open", "/a", "/b"]])
        let imgs = CustomAction(name: "i", command: ["x"], extensions: ["jpg"])
        XCTAssertTrue(imgs.applies(to: [FileItem(name: "a.JPG", parent: "/", kind: .file)]))
        XCTAssertFalse(imgs.applies(to: [FileItem(name: "a.png", parent: "/", kind: .file)]))
        let folders = CustomAction(name: "f", command: ["x"], extensions: ["/"])
        XCTAssertTrue(folders.applies(to: [FileItem(name: "d", parent: "/", kind: .directory)]))
    }

    func testDefaultFilesParse() throws {
        let store = ConfigStore(home: URL(fileURLWithPath: path("home")))
        store.ensureDefaults(keybindingsText: "[]")
        let (settings, err) = store.loadSettings()
        XCTAssertNil(err)
        XCTAssertEqual(settings, Settings())
        let (actions, aerr) = store.loadActions()
        XCTAssertNil(aerr)
        XCTAssertEqual(actions, DefaultActions.all)
        let perms = try fm.attributesOfItem(atPath: store.settingsURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dirPerms = try fm.attributesOfItem(atPath: store.home.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        var state = AppState()
        state.recent = ["/tmp"]
        store.saveState(state)
        XCTAssertEqual(store.loadState().recent, ["/tmp"])
    }

    func testCornerSettings() throws {
        let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        let d = try decode("{}")
        XCTAssertEqual(d.windowCorners, "rounded")
        XCTAssertEqual(d.cornerRadius, 4)
        let s = try decode(#"{"windowCorners": "square", "cornerRadius": 0}"#)
        XCTAssertEqual(s.windowCorners, "square")
        XCTAssertEqual(s.cornerRadius, 0)
        let odd = try decode(#"{"windowCorners": "oval", "cornerRadius": 40}"#)
        XCTAssertEqual(odd.windowCorners, "rounded")
        XCTAssertEqual(odd.cornerRadius, 10)
    }

    func testQuitFinderOnLaunchDefaultsFalse() throws {
        let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode("{}").quitFinderOnLaunch, false)
        XCTAssertEqual(try decode(#"{"quitFinderOnLaunch": true}"#).quitFinderOnLaunch, true)
    }

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

    /// A hand-edited settings.json with a misspelled defaultConflictChoice (e.g. "keep-both"
    /// instead of "keepBoth") must not fail the whole file — every other field, and every other
    /// use of settings.json, still needs to decode.
    func testMalformedDefaultConflictChoiceDoesNotFailWholeDecode() throws {
        let decode = { (json: String) in try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        let s = try decode(#"{"defaultConflictChoice": "keep-both", "fontSize": 16}"#)
        XCTAssertNil(s.defaultConflictChoice)
        XCTAssertEqual(s.fontSize, 16)
    }

    func testKeybindingParser() {
        let defaults = [KeyBinding(chords: [KeyChord("cmd+r")!], command: "rename")]
        let json = #"[{"key": "cmd+j k", "command": "jump", "args": "~/x"}, {"key": "cmd+r", "command": "-rename"}]"#
        let r = KeybindingParser.parse(Data(json.utf8), defaults: defaults)
        XCTAssertEqual(r.bindings.count, 1)
        XCTAssertEqual(r.bindings[0].chords.count, 2)
        XCTAssertEqual(r.bindings[0].args, "~/x")
    }

    // MARK: Favourites tree

    func testFavouriteTreeNestsByPath() {
        let favs = [("me", "~"), ("Work", "~/Dropbox/Work"), ("Clients", "~/Dropbox/Work/clients"), ("code", "~/code"),
                    ("output", "~/code/output"), ("Downloads", "~/Downloads"), ("_tmp", "~/_tmp"), ("Family", "~/Dropbox/Family"),
                    ("Scans", "/Volumes/Scans")].map { (name: $0.0, path: $0.1.replacingOccurrences(of: "~", with: "/Users/me")) }
        let tree = FavouriteTree.build(favs, home: "/Users/me")
        XCTAssertEqual(tree.map(\.outline), ["me(_tmp code(output) Downloads +Dropbox(Family Work(Clients)))", "Scans"])
        XCTAssertEqual(tree[0].children.last?.path, "/Users/me/Dropbox")
    }

    func testFavouriteTreeBranchesWithoutHome() {
        let favs = [("B", "/Users/me/Dropbox/Work/B"), ("C", "/Users/me/Dropbox/Work/C/"), ("C again", "/Users/me/Dropbox/Work/C"),
                    ("X", "/Volumes/X"), ("Y", "/Volumes/Y"), ("Solo", "/Users/me/deep/down/Solo")].map { (name: $0.0, path: $0.1) }
        let tree = FavouriteTree.build(favs, home: "/Users/me")
        XCTAssertEqual(tree.map(\.outline), ["Solo", "+Dropbox/Work(B C)", "+Volumes(X Y)"])
        XCTAssertEqual(tree[1].path, "/Users/me/Dropbox/Work")
    }

    func testFavouriteTreeShortensLongBranches() {
        let favs = [("A", "/private/var/folders/xy/T/filee-qa/A"), ("B", "/private/var/folders/xy/T/filee-qa/B")].map { (name: $0.0, path: $0.1) }
        let tree = FavouriteTree.build(favs, home: "/Users/me")
        XCTAssertEqual(tree.map(\.outline), ["+…/T/filee-qa(A B)"])
        XCTAssertEqual(tree[0].path, "/private/var/folders/xy/T/filee-qa")
    }

    // MARK: File-type filter

    func testFileTypeFilter() {
        let file = { (name: String) in FileItem(name: name, parent: "/", kind: .file) }
        XCTAssertTrue(FileTypeFilter.pdf.matches(file("Offer.PDF")))
        XCTAssertFalse(FileTypeFilter.pdf.matches(file("offer.docx")))
        XCTAssertTrue(FileTypeFilter.pdf.matches(FileItem(name: "folder", parent: "/", kind: .directory)))
        XCTAssertTrue(FileTypeFilter.powerpoint.matches(file("deck.pptx")))
        XCTAssertTrue(FileTypeFilter.excel.matches(file("export.csv")))
        XCTAssertTrue(FileTypeFilter.video.matches(file("call.mov")))
        XCTAssertTrue(FileTypeFilter.images.matches(file("IMG_1.HEIC")))
        XCTAssertFalse(FileTypeFilter.markdown.matches(file("README")))
        XCTAssertTrue(FileTypeFilter.all.matches(file("README")))
        // Every family but "all" has a sample extension of its own.
        for f in FileTypeFilter.allCases where f != .all { XCTAssertTrue(f.extensions.contains(f.sampleExtension ?? "")) }
    }

    func testFileTypeFilterRecognizedApps() {
        XCTAssertTrue(FileTypeFilter.powerpoint.recognizedAppBundleIDs.contains("com.apple.iWork.Keynote"))
        XCTAssertFalse(FileTypeFilter.powerpoint.recognizedAppBundleIDs.contains("com.openai.chat"))
        XCTAssertTrue(FileTypeFilter.markdown.recognizedAppBundleIDs.contains("com.apple.TextEdit"))
        XCTAssertFalse(FileTypeFilter.markdown.recognizedAppBundleIDs.contains("com.apple.dt.Xcode"))
        XCTAssertTrue(FileTypeFilter.video.recognizedAppBundleIDs.contains("org.videolan.vlc"))
        XCTAssertTrue(FileTypeFilter.word.recognizedAppBundleIDs.contains("com.microsoft.Word"))
        XCTAssertTrue(FileTypeFilter.excel.recognizedAppBundleIDs.contains("com.microsoft.Excel"))
        XCTAssertTrue(FileTypeFilter.images.recognizedAppBundleIDs.contains("com.apple.Preview"))
        // TextEdit is Markdown's own bundled fallback icon: if Word also recognized it as a real
        // app, a Mac with TextEdit as the default for both .docx and .md would show 2 identical
        // buttons (Word's real TextEdit icon and Markdown's bundled TextEdit icon).
        XCTAssertFalse(FileTypeFilter.word.recognizedAppBundleIDs.contains("com.apple.TextEdit"))
    }

    func testFileTypeFilterBundledFallbackIcons() {
        XCTAssertNil(FileTypeFilter.all.bundledFallbackIconName)
        for f in FileTypeFilter.allCases where f != .all {
            XCTAssertNotNil(f.bundledFallbackIconName)
        }
        let names = FileTypeFilter.allCases.compactMap { $0.bundledFallbackIconName }
        XCTAssertEqual(Set(names).count, names.count, "each family's bundled fallback icon name must be unique")
    }

    /// Worst-case values (qa.py --only worst): a name with a line break, a package's kind, 2 TB.
    func testWorstCaseFormatting() {
        XCTAssertEqual("first line\nsecond line.txt".singleLine, "first line⏎second line.txt")
        XCTAssertEqual("a\r\nb".singleLine, "a⏎b")
        XCTAssertEqual("🦊 Fox".singleLine, "🦊 Fox")
        let library = FileItem(name: "Family Photos.photoslibrary", parent: "/tmp", kind: .directory, isPackage: true)
        XCTAssertFalse(Format.kind(library).contains("PHOTOSLIBRARY"))
        XCTAssertEqual(Format.size(2 * 1024 * 1024 * 1024 * 1024), "2.00 TB")
        XCTAssertEqual(Format.date(1).prefix(4), "1970")
    }

    func testCountPlurals() {
        XCTAssertEqual(Count.of(0, "file", "files"), "0 files")
        XCTAssertEqual(Count.of(1, "file", "files"), "1 file")
        XCTAssertEqual(Count.of(2, "folder", "folders"), "2 folders")
        XCTAssertEqual(Count.of(1284, "file", "files"), "\(1284.formatted()) files")
        XCTAssertEqual(Format.items(1), "1 item")
        XCTAssertEqual(Format.items(50_000), "\(50_000.formatted()) items")
        XCTAssertEqual(UndoRecord.created(Array(repeating: "/tmp/x", count: 1200)).title, "Create \(1200.formatted()) Items")
    }
}
