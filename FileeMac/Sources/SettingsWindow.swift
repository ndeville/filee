import AppKit
import FileeCore

/// The Settings window (⌘,): a toolbar of panes, matching Path Finder's own Settings
/// window (General / Browser / Features / Appearance / Finder). Only General (the
/// default-file-browser toggle) and Finder (hide desktop, quit Finder on launch) have
/// real content today; the rest are placeholders so the toolbar's shape is right.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var panes: [String: NSView] = [:]
    private var defaultBrowserSwitch: NSSwitch?
    private var hideDesktopSwitch: NSSwitch?
    private var quitFinderSwitch: NSSwitch?
    // Browser pane
    private var showHiddenSwitch: NSSwitch?
    private var defaultViewPopup: NSPopUpButton?
    private var newTabPathField: NSTextField?
    private var revealInNewTabPopup: NSPopUpButton?
    private var springLoadedSwitch: NSSwitch?
    // Features pane
    private var vimKeysSwitch: NSSwitch?
    private var terminalAppField: NSTextField?
    private var defaultConflictPopup: NSPopUpButton?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 300))
        // Width stays fixed; height is sized per pane in selectPane(_:), from that pane's own content —
        // Appearance (the tallest) needs far more than General's single switch.
        window.contentMinSize = NSSize(width: 480, height: 150)
        window.contentMaxSize = NSSize(width: 480, height: 800)
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        if #available(macOS 11.0, *) { window.toolbarStyle = .preference }
        window.toolbar = toolbar
        buildPanes()
        toolbar.selectedItemIdentifier = .init("general")
        window.contentView = panes["general"]
        resizeToFit(panes["general"])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the window, bringing it forward if already open, and refreshes every
    /// toggle from live OS/settings state (another app, or Terminal, may have changed
    /// it while the window was closed).
    func show() {
        defaultBrowserSwitch?.state = FinderIntegration.isDefaultFileViewer() ? .on : .off
        hideDesktopSwitch?.state = FinderIntegration.isDesktopHidden() ? .on : .off
        quitFinderSwitch?.state = Theme.settings.quitFinderOnLaunch ? .on : .off
        showHiddenSwitch?.state = Theme.settings.showHidden ? .on : .off
        if let idx = defaultViewOptions.firstIndex(of: Theme.settings.defaultView) { defaultViewPopup?.selectItem(at: idx) }
        newTabPathField?.stringValue = Theme.settings.newTabPath
        revealInNewTabPopup?.selectItem(at: Theme.settings.revealInNewTab ? 1 : 0)
        springLoadedSwitch?.state = Theme.settings.springLoadedFolders ? .on : .off
        vimKeysSwitch?.state = Theme.settings.vimKeys ? .on : .off
        terminalAppField?.stringValue = Theme.settings.terminalApp
        if let idx = defaultConflictOptions.firstIndex(of: Theme.settings.defaultConflictChoice) { defaultConflictPopup?.selectItem(at: idx) }
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Panes

    private func buildPanes() {
        panes["general"] = paneView(title: "Default File Browser", rows: [
            labeledSwitch(
                title: "Set Filee as the default file browser",
                caption: "Other apps' \"Reveal in Finder\" will open Filee instead. macOS still opens Finder "
                    + "for the Dock and for apps that open folders directly — Filee can't fully replace Finder.",
                initial: FinderIntegration.isDefaultFileViewer(),
                store: { self.defaultBrowserSwitch = $0 },
                action: #selector(toggleDefaultBrowser(_:))),
        ])
        panes["finder"] = paneView(title: "Finder", rows: [
            labeledSwitch(
                title: "Hide Finder's Desktop",
                caption: "Removes desktop icons until you turn this back on. Finder quits and reopens to apply the change.",
                initial: FinderIntegration.isDesktopHidden(),
                store: { self.hideDesktopSwitch = $0 },
                action: #selector(toggleHideDesktop(_:))),
            labeledSwitch(
                title: "Quit Finder When Filee Launches",
                caption: "Some macOS features, like Time Machine, may not work correctly while Finder isn't running.",
                initial: Theme.settings.quitFinderOnLaunch,
                store: { self.quitFinderSwitch = $0 },
                action: #selector(toggleQuitFinderOnLaunch(_:))),
        ])
        panes["browser"] = paneView(title: "Browser", rows: [
            labeledSwitch(
                title: "Show hidden files by default",
                caption: "New windows and tabs start with dotfiles visible. ⇧⌘. still toggles it per window.",
                initial: Theme.settings.showHidden,
                store: { self.showHiddenSwitch = $0 },
                action: #selector(toggleShowHidden(_:))),
            labeledPicker(
                title: "Default view for new tabs:",
                options: [(ViewMode.list, "List"), (.columns, "Columns"), (.thumbnails, "Thumbnails")],
                initial: Theme.settings.defaultView,
                store: { self.defaultViewPopup = $0 },
                action: #selector(changeDefaultView(_:))),
            labeledTextField(
                title: "New tabs open in:",
                initial: Theme.settings.newTabPath,
                store: { self.newTabPathField = $0 },
                action: #selector(changeNewTabPath(_:))),
            labeledPicker(
                title: "Reveal in Filee:",
                options: [(false, "Use active pane"), (true, "Open in a new tab")],
                initial: Theme.settings.revealInNewTab,
                store: { self.revealInNewTabPopup = $0 },
                action: #selector(changeRevealInNewTab(_:))),
            labeledSwitch(
                title: "Spring-loaded folders",
                caption: "Drag a file over a folder and hold: it opens. Follows System Settings > Accessibility > "
                    + "Pointer Control's own spring-loading delay — Filee has no delay of its own to set.",
                initial: Theme.settings.springLoadedFolders,
                store: { self.springLoadedSwitch = $0 },
                action: #selector(toggleSpringLoadedFolders(_:))),
        ])
        panes["features"] = paneView(title: "Features", rows: [
            labeledSwitch(
                title: "Vim keys",
                caption: "hjkl move and select in the file list, alongside the arrow keys.",
                initial: Theme.settings.vimKeys,
                store: { self.vimKeysSwitch = $0 },
                action: #selector(toggleVimKeys(_:))),
            labeledTextField(
                title: "Terminal app:",
                initial: Theme.settings.terminalApp,
                store: { self.terminalAppField = $0 },
                action: #selector(changeTerminalApp(_:))),
            buttonRow(titles: ["Edit keybindings.json…", "Edit actions.json…"],
                      actions: [#selector(editKeybindings(_:)), #selector(editActions(_:))]),
            labeledPicker(
                title: "Default conflict policy:",
                options: [(nil, "Always Ask"), (.keepBoth, "Keep Both"), (.replace, "Replace"), (.skip, "Skip")] as [(ConflictChoice?, String)],
                initial: Theme.settings.defaultConflictChoice,
                store: { self.defaultConflictPopup = $0 },
                action: #selector(changeDefaultConflictChoice(_:))),
        ])
        panes["appearance"] = placeholderPane()
    }

    private func paneView(title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        let stack = NSStackView(views: [heading] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    private func placeholderPane() -> NSView {
        let label = NSTextField(labelWithString: "Nothing here yet.")
        label.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// 1 switch + title + wrapping caption, stacked. `store` captures the switch so the
    /// controller can read/set its state later (refresh on show, revert on cancel).
    private func labeledSwitch(title: String, caption: String, initial: Bool,
                                store: (NSSwitch) -> Void, action: Selector) -> NSView {
        let toggle = NSSwitch()
        toggle.state = initial ? .on : .off
        toggle.target = self
        toggle.action = action
        store(toggle)
        let titleLabel = NSTextField(labelWithString: title)
        let row = NSStackView(views: [toggle, titleLabel])
        row.orientation = .horizontal
        row.spacing = 8
        let captionLabel = NSTextField(wrappingLabelWithString: caption)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.preferredMaxLayoutWidth = 408
        let column = NSStackView(views: [row, captionLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        return column
    }

    /// 1 labeled popup, title + choices, stacked like labeledSwitch.
    private func labeledPicker<T: Hashable>(title: String, options: [(T, String)], initial: T,
                                             store: (NSPopUpButton) -> Void, action: Selector) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (_, label) in options { popup.addItem(withTitle: label) }
        if let idx = options.firstIndex(where: { $0.0 == initial }) { popup.selectItem(at: idx) }
        popup.target = self
        popup.action = action
        store(popup)
        let titleLabel = NSTextField(labelWithString: title)
        let row = NSStackView(views: [titleLabel, popup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// 1 labeled slider with a numeric value label, title above.
    private func labeledSlider(title: String, range: ClosedRange<Double>, initial: Double,
                                store: (NSSlider) -> Void, action: Selector) -> NSView {
        let slider = NSSlider(value: initial, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        store(slider)
        let titleLabel = NSTextField(labelWithString: title)
        let row = NSStackView(views: [titleLabel, slider])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// 1 labeled text field, title + field, stacked like labeledPicker.
    private func labeledTextField(title: String, initial: String,
                                   store: (NSTextField) -> Void, action: Selector) -> NSView {
        let field = NSTextField(string: initial)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        field.target = self
        field.action = action
        store(field)
        let titleLabel = NSTextField(labelWithString: title)
        let row = NSStackView(views: [titleLabel, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// A row of plain push buttons, equally spaced — for actions with no value to show (open a file).
    private func buttonRow(titles: [String], actions: [Selector]) -> NSView {
        let buttons = zip(titles, actions).map { title, action -> NSButton in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: Actions

    @objc private func toggleDefaultBrowser(_ sender: NSSwitch) {
        FinderIntegration.setDefaultFileViewer(sender.state == .on)
    }

    @objc private func toggleHideDesktop(_ sender: NSSwitch) {
        guard sender.state == .on else {
            FinderIntegration.setDesktopHidden(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Hide Finder's desktop icons?"
        alert.informativeText = "This quits and reopens Finder. Any open Finder windows will close."
        alert.addButton(withTitle: "Hide Desktop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            FinderIntegration.setDesktopHidden(true)
        } else {
            sender.state = .off
        }
    }

    @objc private func toggleQuitFinderOnLaunch(_ sender: NSSwitch) {
        AppDelegate.shared.setQuitFinderOnLaunch(sender.state == .on)
    }

    @objc private func toggleShowHidden(_ sender: NSSwitch) {
        AppDelegate.shared.updateSettings { $0.showHidden = sender.state == .on }
    }

    private let defaultViewOptions: [ViewMode] = [.list, .columns, .thumbnails]

    @objc private func changeDefaultView(_ sender: NSPopUpButton) {
        guard defaultViewOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        AppDelegate.shared.updateSettings { $0.defaultView = self.defaultViewOptions[sender.indexOfSelectedItem] }
    }

    @objc private func changeNewTabPath(_ sender: NSTextField) {
        AppDelegate.shared.updateSettings { $0.newTabPath = sender.stringValue }
    }

    @objc private func changeRevealInNewTab(_ sender: NSPopUpButton) {
        AppDelegate.shared.updateSettings { $0.revealInNewTab = sender.indexOfSelectedItem == 1 }
    }

    @objc private func toggleSpringLoadedFolders(_ sender: NSSwitch) {
        AppDelegate.shared.updateSettings { $0.springLoadedFolders = sender.state == .on }
    }

    @objc private func toggleVimKeys(_ sender: NSSwitch) {
        AppDelegate.shared.updateSettings { $0.vimKeys = sender.state == .on }
    }

    @objc private func changeTerminalApp(_ sender: NSTextField) {
        AppDelegate.shared.updateSettings { $0.terminalApp = sender.stringValue }
    }

    @objc private func editKeybindings(_ sender: NSButton) {
        AppDelegate.shared.openConfig(AppDelegate.shared.config.keybindingsURL)
    }

    @objc private func editActions(_ sender: NSButton) {
        AppDelegate.shared.openConfig(AppDelegate.shared.config.actionsURL)
    }

    private let defaultConflictOptions: [ConflictChoice?] = [nil, .keepBoth, .replace, .skip]

    @objc private func changeDefaultConflictChoice(_ sender: NSPopUpButton) {
        guard defaultConflictOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        AppDelegate.shared.updateSettings { $0.defaultConflictChoice = self.defaultConflictOptions[sender.indexOfSelectedItem] }
    }

    // MARK: NSToolbarDelegate

    private let toolbarInfo: [(String, String, String)] = [
        ("general", "General", "gearshape"),
        ("browser", "Browser", "safari"),
        ("features", "Features", "wrench.and.screwdriver"),
        ("appearance", "Appearance", "paintbrush"),
        ("finder", "Finder", "folder"),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarInfo.map { .init($0.0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let info = toolbarInfo.first(where: { $0.0 == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = info.1
        item.image = NSImage(systemSymbolName: info.2, accessibilityDescription: info.1)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        let pane = panes[sender.itemIdentifier.rawValue]
        window?.contentView = pane
        window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        resizeToFit(pane)
    }

    /// Sizes the window to the pane's own content height, clamped to the screen — General's 1 switch
    /// and Appearance's ~10 controls don't fit the same fixed size.
    private func resizeToFit(_ pane: NSView?) {
        guard let window, let stack = pane?.subviews.first as? NSStackView else { return }
        let maxH = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? window.contentMaxSize.height
        let height = min(max(stack.fittingSize.height, window.contentMinSize.height), min(maxH, window.contentMaxSize.height))
        window.setContentSize(NSSize(width: 480, height: height))
    }
}
