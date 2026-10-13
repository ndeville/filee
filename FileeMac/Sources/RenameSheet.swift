import AppKit
import FileeCore

/// Batch rename (SPEC 5.2): mode, inputs, live preview of old and new names, conflicts in red.
final class RenameSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var current: RenameSheet?

    private let paths: [String]
    private unowned let browser: BrowserWindowController
    private let sheet: NSWindow
    private let modePopup = NSPopUpButton()
    private let field1 = NSTextField()
    private let field2 = NSTextField()
    private let regexBox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseBox = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let help = label("", size: 11.5, color: Theme.muted)
    private let table = NSTableView()
    private let summary = label("", size: 12, color: Theme.fg2)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private var plan = RenamePlan(entries: [])
    private var dates: [String: Date?] = [:]

    static let modes = ["Sequence", "Find and replace", "Prefix date (YYMMDD-)", "Slugify", "lower case", "UPPER CASE", "Title Case"]

    static func show(for paths: [String], in browser: BrowserWindowController) {
        let s = RenameSheet(paths: paths, browser: browser)
        current = s
        browser.window?.beginSheet(s.sheet) { _ in current = nil }
        s.sheet.makeFirstResponder(s.field1)
    }

    private init(paths: [String], browser: BrowserWindowController) {
        self.paths = paths
        self.browser = browser
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
        update()
    }

    private func build() {
        let v = FlippedView(frame: sheet.contentRect(forFrameRect: sheet.frame))
        sheet.contentView = v
        let title = label("Rename \(Format.items(paths.count))", size: 15, weight: .bold, color: Theme.fg)
        title.frame = NSRect(x: 20, y: 16, width: 500, height: 20)
        modePopup.addItems(withTitles: Self.modes)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.frame = NSRect(x: 20, y: 48, width: 220, height: 26)
        field1.frame = NSRect(x: 250, y: 49, width: 240, height: 24)
        field2.frame = NSRect(x: 500, y: 49, width: 240, height: 24)
        for f in [field1, field2] {
            f.delegate = self
            f.font = Theme.ui(13)
        }
        regexBox.target = self
        regexBox.action = #selector(optionChanged)
        caseBox.target = self
        caseBox.action = #selector(optionChanged)
        regexBox.frame = NSRect(x: 250, y: 80, width: 80, height: 20)
        caseBox.frame = NSRect(x: 330, y: 80, width: 140, height: 20)
        help.frame = NSRect(x: 20, y: 104, width: 720, height: 32)
        help.maximumNumberOfLines = 2
        help.lineBreakMode = .byWordWrapping

        for (id, t, w) in [("old", "Current name", 350.0), ("new", "New name", 370.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = t
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 142, width: 720, height: 310))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        summary.frame = NSRect(x: 20, y: 470, width: 440, height: 18)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 540, y: 464, width: 96, height: 30)
        renameButton.target = self
        renameButton.action = #selector(apply)
        renameButton.keyEquivalent = "\r"
        renameButton.frame = NSRect(x: 644, y: 464, width: 96, height: 30)
        for sub in [title, modePopup, field1, field2, regexBox, caseBox, help, scroll, summary, cancel, renameButton] as [NSView] { v.addSubview(sub) }
        modeChanged()
    }

    @objc private func modeChanged() {
        let i = modePopup.indexOfSelectedItem
        field1.isHidden = !(i == 0 || i == 1)
        field2.isHidden = i != 1
        regexBox.isHidden = i != 1
        caseBox.isHidden = i != 1
        switch i {
        case 0:
            field1.placeholderString = "Base name, e.g. YYMMDD-world-summit-ai"
            help.stringValue = "Every item gets the base name plus _01, _02… in the current sort order. YYMMDD becomes each file's capture date (EXIF, else creation date). Extensions stay."
        case 1:
            field1.placeholderString = "Find"
            field2.placeholderString = "Replace with"
            help.stringValue = "Acts on the name without the extension. With Regex, $1 inserts a group."
        case 2: help.stringValue = "Adds YYMMDD- from the capture date. Names that already start with 6 digits are left as they are."
        case 3: help.stringValue = "Lower case, accents removed, spaces and _ become -."
        default: help.stringValue = "Changes the case of the name, not the extension."
        }
        update()
        if !field1.isHidden { sheet.makeFirstResponder(field1) }
    }

    @objc private func optionChanged() { update() }
    func controlTextDidChange(_ obj: Notification) { update() }

    private var mode: RenameMode {
        switch modePopup.indexOfSelectedItem {
        case 0: return .sequence(base: field1.stringValue)
        case 1: return .replace(find: field1.stringValue, with: field2.stringValue, regex: regexBox.state == .on, caseSensitive: caseBox.state == .on)
        case 2: return .prefixDate
        case 3: return .slugify
        case 4: return .lower
        case 5: return .upper
        default: return .title
        }
    }

    private func update() {
        let m = mode
        if case .sequence(let base) = m, base.trimmingCharacters(in: .whitespaces).isEmpty {
            plan = RenamePlan(entries: paths.map { .init(path: $0, oldName: ($0 as NSString).lastPathComponent, newName: ($0 as NSString).lastPathComponent, problem: nil) })
        } else {
            // Capture dates are read once per file, then cached for every keystroke.
            plan = Renamer.plan(paths, mode: m) { [unowned self] p in
                if let d = self.dates[p] { return d }
                let d = CaptureDate.of(p)
                self.dates[p] = d
                return d
            }
        }
        table.reloadData()
        let problems = plan.entries.filter { $0.problem != nil }.count
        summary.stringValue = problems > 0 ? "\(problems) problem\(problems == 1 ? "" : "s"): fix them to rename" : "\(plan.changedCount) of \(paths.count) will change"
        summary.textColor = problems > 0 ? Theme.accentText : Theme.fg2
        renameButton.isEnabled = plan.isValid
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = plan.entries[row]
        let isNew = tableColumn?.identifier.rawValue == "new"
        var text = isNew ? e.newName : e.oldName
        if isNew, let p = e.problem { text += "   ⚠ \(p)" }
        let l = label(text, size: 12.5, color: isNew ? (e.problem != nil ? Theme.accentText : (e.newName != e.oldName ? Theme.fg : Theme.muted)) : Theme.fg2)
        l.lineBreakMode = .byTruncatingMiddle
        let v = NSTableCellView()
        v.addSubview(l)
        l.frame = NSRect(x: 4, y: 2, width: (tableColumn?.width ?? 300) - 8, height: 17)
        return v
    }

    @objc private func cancel() {
        browser.window?.endSheet(sheet)
    }

    @objc private func apply() {
        guard plan.isValid else { return }
        let results = OperationCenter.shared.apply(plan)
        browser.window?.endSheet(sheet)
        browser.selectInPanes(results)
    }

    /// For QA: fill the sheet and apply without clicks.
    static func qaApply(base: String) -> Bool {
        guard let s = current else { return false }
        s.modePopup.selectItem(at: 0)
        s.modeChanged()
        s.field1.stringValue = base
        s.update()
        s.apply()
        return true
    }
}
