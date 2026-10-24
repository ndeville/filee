import AppKit
import FileeCore

/// Every command: id, palette title, default key (SPEC 4.2). Keys without ⌘ or ⌃ act only while no text is edited.
enum CommandCatalog {
    struct Entry {
        let id: String
        let title: String
        let key: String?
        let args: String?
    }

    static let all: [Entry] = [
        // Navigation
        .init(id: "open", title: "Open", key: "enter", args: nil),
        .init(id: "open", title: "Open", key: "cmd+o", args: nil),
        .init(id: "openWith", title: "Open With…", key: nil, args: nil),
        .init(id: "up", title: "Enclosing Folder", key: "cmd+up", args: nil),
        .init(id: "selectLast", title: "Select Last Item", key: "cmd+down", args: nil),
        .init(id: "back", title: "Back", key: "cmd+[", args: nil),
        .init(id: "forward", title: "Forward", key: "cmd+]", args: nil),
        .init(id: "switchPane", title: "Switch Active Pane", key: "tab", args: nil),
        .init(id: "editPath", title: "Go to Folder (Edit Path)", key: "cmd+l", args: nil),
        .init(id: "editPath", title: "Go to Folder (Edit Path)", key: "ctrl+g", args: nil),
        .init(id: "editPath", title: "Go to Folder (Edit Path)", key: "cmd+g", args: nil),
        .init(id: "palette", title: "Command Palette", key: "cmd+k", args: nil),
        .init(id: "go", title: "Go to Home", key: "cmd+h", args: "~"),
        .init(id: "go", title: "Go to Downloads", key: "alt+cmd+d", args: "~/Downloads"),
        .init(id: "go", title: "Go to Applications", key: nil, args: "/Applications"),
        .init(id: "go", title: "Go to Desktop", key: nil, args: "~/Desktop"),
        .init(id: "go", title: "Go to Computer", key: nil, args: "/Volumes"),
        .init(id: "toggleFavourite", title: "Add or Remove Folder in Favourites", key: "shift+cmd+f", args: nil),
        .init(id: "focusFavourites", title: "Go to Favourites in the Sidebar", key: "alt+cmd+f", args: nil),
        .init(id: "focusVolumes", title: "Go to Volumes in the Sidebar", key: "shift+alt+cmd+f", args: nil),
        .init(id: "syncPanes", title: "Show This Folder in the Other Pane", key: nil, args: nil),
        .init(id: "parentInOtherPane", title: "Show Enclosing Folder in the Other Pane", key: "alt+cmd+up", args: nil),
        .init(id: "openInNewTab", title: "Open Folder in New Tab", key: nil, args: nil),
        .init(id: "openInOtherPane", title: "Open Folder in Other Pane", key: nil, args: nil),
        .init(id: "swapPanes", title: "Swap Panes", key: nil, args: nil),
        // Foldee (~/ai/lab/foldee, SPEC 9): sends the open Open or Save dialog here.
        .init(id: "sendToDialog", title: "Send to Dialog", key: "alt+cmd+o", args: nil),
        // Views
        .init(id: "singlePane", title: "Single Pane", key: "cmd+1", args: nil),
        .init(id: "dualPane", title: "Dual Pane", key: "cmd+2", args: nil),
        // Fn+= on Nic's Kinesis sends F1: his Path Finder key for the dual browser.
        .init(id: "toggleDualPane", title: "Toggle Single or Dual Pane", key: "f1", args: nil),
        .init(id: "viewThumbnails", title: "View as Thumbnails", key: "cmd+3", args: nil),
        .init(id: "viewColumns", title: "View as Columns", key: "cmd+4", args: nil),
        .init(id: "viewList", title: "View as List", key: "cmd+5", args: nil),
        .init(id: "toggleSidebar", title: "Show or Hide Sidebar", key: "cmd+b", args: nil),
        // File-type filter of the active tab
        .init(id: "typeFilter", title: "Show All Files", key: nil, args: "all"),
        .init(id: "typeFilter", title: "Show Only PDF Files", key: nil, args: "pdf"),
        .init(id: "typeFilter", title: "Show Only PowerPoint Files", key: nil, args: "powerpoint"),
        .init(id: "typeFilter", title: "Show Only Word Files", key: nil, args: "word"),
        .init(id: "typeFilter", title: "Show Only Excel Files", key: nil, args: "excel"),
        .init(id: "typeFilter", title: "Show Only Markdown Files", key: nil, args: "markdown"),
        .init(id: "typeFilter", title: "Show Only Video Files", key: nil, args: "video"),
        .init(id: "typeFilter", title: "Show Only Images", key: nil, args: "images"),
        .init(id: "toggleTheme", title: "Switch Light or Dark Theme", key: "ctrl+cmd+l", args: nil),
        .init(id: "systemTheme", title: "Use System Theme", key: nil, args: nil),
        .init(id: "newTab", title: "New Tab", key: "cmd+t", args: nil),
        .init(id: "closeTab", title: "Close Tab", key: "cmd+w", args: nil),
        .init(id: "nextTab", title: "Next Tab", key: "shift+cmd+]", args: nil),
        .init(id: "previousTab", title: "Previous Tab", key: "shift+cmd+[", args: nil),
        .init(id: "nextTab", title: "Next Tab", key: "ctrl+tab", args: nil),
        .init(id: "previousTab", title: "Previous Tab", key: "ctrl+shift+tab", args: nil),
        .init(id: "toggleHidden", title: "Show or Hide Invisible Files", key: "shift+cmd+i", args: nil),
        .init(id: "reload", title: "Reload", key: "shift+cmd+r", args: nil),
        .init(id: "focusFilter", title: "Filter This Folder", key: nil, args: nil),
        .init(id: "zoomIn", title: "Zoom In", key: "cmd+=", args: nil),
        .init(id: "zoomIn", title: "Zoom In", key: "shift+cmd+=", args: nil),
        .init(id: "zoomOut", title: "Zoom Out", key: "cmd+-", args: nil),
        .init(id: "zoomReset", title: "Reset Zoom", key: "cmd+0", args: nil),
        .init(id: "quickLook", title: "Quick Look", key: "space", args: nil),
        .init(id: "info", title: "Get Info", key: "cmd+i", args: nil),
        .init(id: "folderSizes", title: "Calculate Folder Sizes", key: "ctrl+cmd+s", args: nil),
        .init(id: "expandAll", title: "Expand All", key: "alt+cmd+right", args: nil),
        .init(id: "collapseAll", title: "Collapse All", key: "alt+cmd+left", args: nil),
        // Files
        .init(id: "copyToOther", title: "Copy to Other Pane", key: "f5", args: nil),
        .init(id: "moveToOther", title: "Move to Other Pane", key: "f6", args: nil),
        .init(id: "rename", title: "Rename…", key: "cmd+r", args: nil),
        .init(id: "batchRename", title: "Batch Rename…", key: nil, args: nil),
        .init(id: "newFolder", title: "New Folder", key: "shift+cmd+n", args: nil),
        .init(id: "newFolderWithSelection", title: "New Folder with Selection", key: nil, args: nil),
        .init(id: "newFile", title: "New Text File", key: "alt+cmd+n", args: nil),
        .init(id: "duplicate", title: "Duplicate", key: nil, args: nil),
        .init(id: "trash", title: "Move to Trash", key: "cmd+backspace", args: nil),
        .init(id: "emptyTrash", title: "Empty Trash…", key: "shift+cmd+backspace", args: nil),
        .init(id: "undo", title: "Undo", key: "cmd+z", args: nil),
        .init(id: "redo", title: "Redo", key: "shift+cmd+z", args: nil),
        .init(id: "eject", title: "Eject", key: "cmd+e", args: nil),
        .init(id: "compress", title: "Compress to Zip", key: "ctrl+cmd+c", args: nil),
        .init(id: "extract", title: "Extract Zip Here", key: nil, args: nil),
        .init(id: "copyPath", title: "Copy Path", key: "shift+cmd+d", args: nil),
        .init(id: "copyTildePath", title: "Copy Path with ~", key: nil, args: nil),
        .init(id: "copyName", title: "Copy Name", key: nil, args: nil),
        .init(id: "copyMarkdownLink", title: "Copy as Markdown Link", key: nil, args: nil),
        .init(id: "revealInFinder", title: "Reveal in Finder", key: "alt+cmd+r", args: nil),
        .init(id: "terminalHere", title: "Open Ghostty Here", key: "ctrl+cmd+t", args: nil),
        .init(id: "makeSymlink", title: "Make Symbolic Link", key: nil, args: nil),
        .init(id: "selectAll", title: "Select All", key: "cmd+a", args: nil),
        // Drop stack
        .init(id: "stackAdd", title: "Add to Drop Stack", key: "ctrl+cmd+d", args: nil),
        .init(id: "stackCopyHere", title: "Copy Drop Stack Here", key: nil, args: nil),
        .init(id: "stackMoveHere", title: "Move Drop Stack Here", key: nil, args: nil),
        .init(id: "stackClear", title: "Clear Drop Stack", key: nil, args: nil),
        // App
        .init(id: "cancelOperation", title: "Cancel Running Operation", key: nil, args: nil),
        .init(id: "openSettings", title: "Open Settings (settings.json)", key: "cmd+,", args: nil),
        .init(id: "openKeybindings", title: "Open Keyboard Shortcuts (keybindings.json)", key: nil, args: nil),
        .init(id: "openActions", title: "Open Custom Actions (actions.json)", key: nil, args: nil),
        .init(id: "showMemory", title: "Show Memory Use", key: nil, args: nil),
        .init(id: "newWindow", title: "New Window", key: "cmd+n", args: nil),
    ]

    /// Commands that act on text being edited stay with the text: Filee doesn't catch them then.
    static let textCommands: Set<String> = ["selectAll", "undo", "redo", "selectLast"]

    static func title(_ id: String, args: String?) -> String {
        all.first { $0.id == id && $0.args == args }?.title ?? all.first { $0.id == id }?.title ?? id
    }

    static var defaultBindings: [KeyBinding] {
        var out: [KeyBinding] = all.compactMap { c in
            guard let key = c.key else { return nil }
            let chords = key.split(separator: " ").compactMap { KeyChord(String($0)) }
            return KeyBinding(chords: chords, command: c.id, args: c.args)
        }
        // ⌃⌘I, the old Get Info key, still works.
        if let old = KeyChord("ctrl+cmd+i") { out.append(KeyBinding(chords: [old], command: "info", args: nil)) }
        // Jumps from settings.json: ⌘J then the letter.
        for (letter, path) in Theme.settings.jumps.sorted(by: { $0.key < $1.key }) {
            if let a = KeyChord("cmd+j"), let b = KeyChord(letter.lowercased()) {
                out.append(KeyBinding(chords: [a, b], command: "go", args: path))
            }
        }
        return out
    }

    static var defaultFileText: String {
        var lines: [String] = [
            "// Filee key bindings, in VS Code's format. Filee reloads this file when you save it.",
            "// Entries here apply on top of Filee's defaults. Add an entry to change a key.",
            "// To remove a default key: { \"key\": \"cmd+r\", \"command\": \"-rename\" }",
            "// Copy (cmd+d), Cut (cmd+x) and Paste (cmd+f) come from the Edit menu and your macOS App Shortcuts.",
            "// Jumps (cmd+j then a letter) come from \"jumps\" in settings.json.",
            "// The defaults, for reference:",
        ]
        for c in all where c.key != nil {
            var entry = "//   { \"key\": \"\(c.key!)\", \"command\": \"\(c.id)\""
            if let a = c.args { entry += ", \"args\": \"\(a)\"" }
            lines.append(entry + " }")
        }
        lines.append("[")
        lines.append("]")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Turns key presses into commands before views and menus see them.
final class Keymap {
    static let shared = Keymap()

    private(set) var bindings: [KeyBinding] = []
    private(set) var errors: [String] = []
    private var pending: [KeyChord] = []
    private var pendingTime: TimeInterval = 0
    /// Custom action keys, from actions.json.
    var actionBindings: [KeyBinding] = []

    static let debug = ProcessInfo.processInfo.environment["FILEE_DEBUG_KEYS"] == "1"
    static weak var qaWindow: NSWindow?

    func load(_ url: URL) {
        let defaults = CommandCatalog.defaultBindings
        guard let data = try? Data(contentsOf: url) else {
            bindings = defaults
            return
        }
        let parsed = KeybindingParser.parse(data, defaults: defaults)
        bindings = parsed.bindings
        errors = parsed.errors
    }

    func binding(for command: String, args: String? = nil) -> KeyBinding? {
        bindings.first { $0.command == command && $0.args == args } ?? bindings.first { $0.command == command && args == nil }
    }

    static func chord(from event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        switch Int(event.keyCode) {
        case 36, 76: key = "enter"
        case 48: key = "tab"
        case 53: key = "escape"
        case 51: key = "backspace"
        case 117: key = "delete"
        case 49: key = "space"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageup"
        case 121: key = "pagedown"
        case 122: key = "f1"
        case 120: key = "f2"
        case 99: key = "f3"
        case 118: key = "f4"
        case 96: key = "f5"
        case 97: key = "f6"
        case 98: key = "f7"
        case 100: key = "f8"
        case 101: key = "f9"
        case 109: key = "f10"
        case 103: key = "f11"
        case 111: key = "f12"
        case 105: key = "f13"
        case 107: key = "f14"
        case 113: key = "f15"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return nil }
            // Layout-independent letters: ⌘J K on any keyboard layout uses the typed character.
            key = String(c)
        }
        return KeyChord(key: key, cmd: flags.contains(.command), shift: flags.contains(.shift),
                        alt: flags.contains(.option), ctrl: flags.contains(.control))
    }

    /// True when the key press ran a command or started a chord.
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let window = NSApp.keyWindow ?? Self.qaWindow,
              let wc = window.windowController as? BrowserWindowController,
              window.attachedSheet == nil,
              var chord = Self.chord(from: event) else { return false }
        // Shifted symbols: "shift+cmd+]" arrives as "}" on some layouts.
        if chord.shift, chord.key == "}" { chord.key = "]" }
        if chord.shift, chord.key == "{" { chord.key = "[" }
        if chord.shift, chord.key == "+" { chord.key = "=" }

        let editingText = window.firstResponder is NSTextView
        // In the sidebar, plain keys move, fold and open there (SidebarOutline): ↩ must not open the pane's selection.
        if window.firstResponder is SidebarOutline, !chord.cmd, !chord.ctrl, pending.isEmpty { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if !pending.isEmpty, now - pendingTime > 1.5 { pending = [] }
        let sequence = pending + [chord]
        let all = bindings + actionBindings

        let exact = all.filter { $0.chords == sequence }
        let longer = all.contains { $0.chords.count > sequence.count && Array($0.chords.prefix(sequence.count)) == sequence }
        if Self.debug { NSLog("KEY %@ exact=%d longer=%d editing=%d", sequence.map(\.description).joined(separator: " "), exact.count, longer ? 1 : 0, editingText ? 1 : 0) }

        for b in exact.reversed() {
            if editingText {
                let first = b.chords[0]
                if !(first.cmd || first.ctrl) || CommandCatalog.textCommands.contains(b.command) { continue }
                // ⌘L, ⌘K and the like still work while the path field is open; edits (⌘⌫) stay with the text.
                if b.command == "trash" || b.command == "copyPath" || b.command == "selectAll" { continue }
            }
            pending = []
            if wc.perform(b.command, args: b.args) { return true }
        }
        if longer, !editingText || chord.cmd || chord.ctrl || !pending.isEmpty {
            pending = sequence
            pendingTime = now
            return true
        }
        if !pending.isEmpty {
            pending = []
            NSSound.beep()
            return true
        }
        return false
    }
}

/// Lets the key map see every key press first.
final class FileeApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        // QA drives the app with its own events: real key presses (Nic typing elsewhere) are dropped.
        if QAHarness.isRunning, event.type == .keyDown || event.type == .keyUp { return }
        if event.type == .keyDown, Keymap.shared.handle(event) { return }
        super.sendEvent(event)
    }
}
