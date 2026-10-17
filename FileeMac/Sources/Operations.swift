import AppKit
import FileeCore

/// Runs file operations off the main thread, shows progress in the status bar, keeps the undo stack.
final class OperationCenter {
    static let shared = OperationCenter()

    let undoStack = UndoStack()
    private let queue = DispatchQueue(label: "filee.ops", qos: .userInitiated, attributes: .concurrent)
    private(set) var running: [Transfer] = []
    /// Set by QA: answer every name conflict without a dialog.
    var autoConflict: ConflictChoice? = {
        switch ProcessInfo.processInfo.environment["FILEE_QA_CONFLICT"] {
        case "replace": return .replace
        case "skip": return .skip
        case "keepBoth": return .keepBoth
        default: return nil
        }
    }()

    /// Set by QA: items in these folders act as if their volume had no Trash.
    var qaNoTrashFolders: Set<String> = []
    /// Set by QA: answers the "Delete immediately?" question without a dialog.
    var qaConfirmDelete: Bool?

    private var window: BrowserWindowController? { AppDelegate.shared.activeWindow }

    private var readOnly: Bool { ProcessInfo.processInfo.environment["FILEE_READONLY"] == "1" }

    private func refuseIfReadOnly() -> Bool {
        if readOnly { window?.showMessage("Read-only mode (FILEE_READONLY=1): nothing was changed", error: true) }
        return readOnly
    }

    /// Reloads every pane that shows 1 of these folders, now rather than at the next disk event.
    func touched(_ folders: [String]) {
        let set = Set(folders.map { canonicalFolder($0) })
        for w in AppDelegate.shared.windows {
            for p in w.panes where set.contains(p.path) { p.reload() }
        }
    }

    // MARK: Copy and move

    func transfer(_ mode: Transfer.Mode, _ sources: [String], into folder: String, completion: (([String]) -> Void)? = nil) {
        guard !sources.isEmpty, !refuseIfReadOnly() else { return }
        let t = Transfer(mode: mode, sources: sources, into: folder)
        t.resolveConflict = { [weak self] name in
            if let c = self?.autoConflict { return (c, true) }
            var answer: (ConflictChoice, Bool) = (.stop, false)
            DispatchQueue.main.sync { answer = Self.askConflict(name: name, folder: folder) }
            return answer
        }
        // The progress row lives in the window the transfer started from.
        let panel = window?.transfers
        panel?.update(t, OperationProgress(title: mode == .copy ? "Copying" : "Moving", currentName: "", itemsDone: 0,
                                           itemsTotal: sources.count, bytesDone: 0, bytesTotal: 0)) { t.cancel.cancel() }
        var lastUpdate: TimeInterval = 0
        t.onProgress = { p in
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastUpdate > 0.1 || p.itemsDone == p.itemsTotal else { return }
            lastUpdate = now
            DispatchQueue.main.async { panel?.update(t, p) { t.cancel.cancel() } }
        }
        running.append(t)
        let sourceFolders = Array(Set(sources.map { ($0 as NSString).deletingLastPathComponent }))
        queue.async { [weak self] in
            let record = t.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running.removeAll { $0 === t }
                if let record { self.undoStack.push(record) }
                let verb = mode == .copy ? "Copied" : "Moved"
                if !t.errors.isEmpty {
                    let text = "❌ " + t.errors.prefix(3).joined(separator: " · ")
                    self.window?.showMessage(text, error: true)
                    panel?.finish(t, text: text, error: true)
                } else if t.cancel.isCancelled {
                    let text = "Cancelled after \(t.results.count) of \(sources.count)"
                    self.window?.showMessage(text)
                    panel?.finish(t, text: text, error: true)
                } else {
                    let text = "✅ \(verb) \(Format.items(t.results.count)) to \(folder.abbreviatingHome)"
                    self.window?.showMessage(text)
                    panel?.finish(t, text: text, error: false)
                }
                self.touched([folder] + (mode == .move ? sourceFolders : []))
                completion?(t.results)
            }
        }
    }

    func cancelAll() {
        running.forEach { $0.cancel.cancel() }
    }

    static func askConflict(name: String, folder: String) -> (ConflictChoice, Bool) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists in \((folder as NSString).lastPathComponent)"
        alert.informativeText = "Replace moves the existing item to the Trash."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        let r = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch r {
        case .alertFirstButtonReturn: return (.keepBoth, all)
        case .alertSecondButtonReturn: return (.replace, all)
        case .alertThirdButtonReturn: return (.skip, all)
        default: return (.stop, false)
        }
    }

    // MARK: Simple operations (fast: run on main, errors shown)

    @discardableResult
    func trash(_ paths: [String]) -> Bool {
        guard !paths.isEmpty, !refuseIfReadOnly() else { return false }
        var pairs: [UndoRecord.Pair] = []
        var errors: [String] = []
        var noTrash: [String] = []
        for p in paths {
            do {
                if qaNoTrashFolders.contains((p as NSString).deletingLastPathComponent) {
                    throw OperationError.noTrash((p as NSString).lastPathComponent)
                }
                pairs.append(.init(p, try FileOps.trash(p)))
            } catch OperationError.noTrash {
                noTrash.append(p)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !pairs.isEmpty { undoStack.push(.trashed(pairs)) }
        // Like Finder: a volume without a Trash (a network share) deletes for good, after a question.
        var deleted = 0
        if !noTrash.isEmpty, confirmDelete(noTrash) {
            for p in noTrash {
                do {
                    try FileOps.delete(p)
                    deleted += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
        }
        if !errors.isEmpty {
            window?.showMessage("❌ " + errors.prefix(2).joined(separator: " · "), error: true)
        } else if deleted > 0 {
            window?.showMessage("🗑 Deleted \(Format.items(deleted)) for good" + (pairs.isEmpty ? "" : " · moved \(Format.items(pairs.count)) to the Trash"))
        } else if !pairs.isEmpty {
            window?.showMessage("🗑 Moved \(Format.items(pairs.count)) to the Trash · ⌘Z puts back")
        }
        touched(paths.map { ($0 as NSString).deletingLastPathComponent })
        return !pairs.isEmpty || deleted > 0
    }

    /// Asks before items on a volume without a Trash are deleted: that can't be undone.
    private func confirmDelete(_ paths: [String]) -> Bool {
        if let answer = qaConfirmDelete { return answer }
        let url = URL(fileURLWithPath: paths[0])
        let volume = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "this volume"
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = paths.count == 1
            ? "Delete “\(url.lastPathComponent)” immediately?"
            : "Delete \(Format.items(paths.count)) immediately?"
        alert.informativeText = "“\(volume)” has no Trash, so Filee deletes \(paths.count == 1 ? "it" : "them") for good. You can't undo this."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    func rename(_ path: String, to name: String) -> String? {
        guard !refuseIfReadOnly() else { return nil }
        do {
            let target = try FileOps.rename(path, to: name)
            undoStack.push(.moved([.init(path, target)]))
            touched([(path as NSString).deletingLastPathComponent])
            return target
        } catch {
            window?.showMessage("❌ \(error.localizedDescription)", error: true)
            return nil
        }
    }

    func apply(_ plan: RenamePlan) -> [String] {
        guard !refuseIfReadOnly() else { return [] }
        do {
            let pairs = try Renamer.apply(plan)
            if !pairs.isEmpty { undoStack.push(.moved(pairs)) }
            window?.showMessage("✅ Renamed \(Format.items(pairs.count))")
            touched(pairs.map { ($0.from as NSString).deletingLastPathComponent })
            return pairs.map(\.to)
        } catch {
            window?.showMessage("❌ Rename failed, nothing changed: \(error.localizedDescription)", error: true)
            return []
        }
    }

    func newFolder(in folder: String, moving items: [String] = []) -> String? {
        guard !refuseIfReadOnly() else { return nil }
        do {
            let path = try FileOps.newFolder(in: folder, name: items.isEmpty ? "untitled folder" : "New Folder With Items")
            var pairs: [UndoRecord.Pair] = []
            for p in items {
                let target = (path as NSString).appendingPathComponent((p as NSString).lastPathComponent)
                try FileOps.moveItem(p, to: target)
                pairs.append(.init(p, target))
            }
            // 1 undo step: the items move back, then the folder goes to the Trash.
            undoStack.push(pairs.isEmpty ? .created([path]) : .group([.created([path]), .moved(pairs)]))
            touched([folder])
            return path
        } catch {
            window?.showMessage("❌ \(error.localizedDescription)", error: true)
            return nil
        }
    }

    func newFile(in folder: String) -> String? {
        guard !refuseIfReadOnly() else { return nil }
        do {
            let path = try FileOps.newFile(in: folder)
            undoStack.push(.created([path]))
            touched([folder])
            return path
        } catch {
            window?.showMessage("❌ \(error.localizedDescription)", error: true)
            return nil
        }
    }

    func makeSymlinks(_ paths: [String], in folder: String) {
        guard !refuseIfReadOnly() else { return }
        var made: [String] = []
        for p in paths {
            let name = FileOps.uniqueName((p as NSString).lastPathComponent + " link", in: folder)
            let link = (folder as NSString).appendingPathComponent(name)
            if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: p)) != nil { made.append(link) }
        }
        if !made.isEmpty { undoStack.push(.created(made)) }
        touched([folder])
    }

    // MARK: Zip

    func compress(_ paths: [String], completion: @escaping (String?) -> Void) {
        guard !paths.isEmpty, !refuseIfReadOnly() else { return }
        window?.showMessage("Compressing \(Format.items(paths.count))…")
        queue.async { [weak self] in
            let result = Result { try Archive.compress(paths) }
            DispatchQueue.main.async {
                switch result {
                case .success(let zip):
                    self?.undoStack.push(.created([zip]))
                    self?.window?.showMessage("✅ \((zip as NSString).lastPathComponent)")
                    self?.touched([(zip as NSString).deletingLastPathComponent])
                    completion(zip)
                case .failure(let e):
                    self?.window?.showMessage("❌ \(e.localizedDescription)", error: true)
                    completion(nil)
                }
            }
        }
    }

    func extract(_ zips: [String], completion: @escaping ([String]) -> Void) {
        guard !zips.isEmpty, !refuseIfReadOnly() else { return }
        window?.showMessage("Extracting \(Format.items(zips.count))…")
        queue.async { [weak self] in
            var out: [String] = []
            var errors: [String] = []
            for z in zips {
                do { out.append(try Archive.extract(z)) } catch { errors.append(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                if !out.isEmpty { self?.undoStack.push(.created(out)) }
                if errors.isEmpty {
                    self?.window?.showMessage("✅ Extracted \(Format.items(out.count))")
                } else {
                    self?.window?.showMessage("❌ " + errors.joined(separator: " · "), error: true)
                }
                self?.touched(zips.map { ($0 as NSString).deletingLastPathComponent })
                completion(out)
            }
        }
    }

    // MARK: Undo

    func undo() -> [String]? {
        guard let r = undoStack.popUndo() else {
            window?.showMessage("Nothing to undo")
            return nil
        }
        do {
            let redo = try r.revert()
            undoStack.pushRedo(redo)
            window?.showMessage("↩︎ Undid: \(r.title)")
            touched(foldersOf(r) + foldersOf(redo))
            return redo.resultPaths
        } catch {
            window?.showMessage("❌ Undo failed: \(error.localizedDescription)", error: true)
            return nil
        }
    }

    func redo() -> [String]? {
        guard let r = undoStack.popRedo() else {
            window?.showMessage("Nothing to redo")
            return nil
        }
        do {
            let back = try r.revert()
            undoStack.pushUndoKeepingRedo(back)
            window?.showMessage("↪︎ Redid: \(back.title)")
            touched(foldersOf(r) + foldersOf(back))
            return back.resultPaths
        } catch {
            window?.showMessage("❌ Redo failed: \(error.localizedDescription)", error: true)
            return nil
        }
    }

    private func foldersOf(_ r: UndoRecord) -> [String] {
        switch r {
        case .moved(let p): return p.flatMap { [($0.from as NSString).deletingLastPathComponent, ($0.to as NSString).deletingLastPathComponent] }
        case .created(let p): return p.map { ($0 as NSString).deletingLastPathComponent }
        case .trashed(let p): return p.map { ($0.from as NSString).deletingLastPathComponent }
        case .group(let r): return r.flatMap { foldersOf($0) }
        }
    }
}
