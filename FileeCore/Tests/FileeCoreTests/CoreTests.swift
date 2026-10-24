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
}
