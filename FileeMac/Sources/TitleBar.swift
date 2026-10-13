import AppKit

/// The red strip at the top of the window, beside the traffic lights: the app icon, "Filee", and the active pane's
/// folder in the centre, on the icon's red gradient. The window's own title is hidden; an empty unified toolbar
/// makes the title bar tall. The strip has the title bar's height, so the title bar above it still moves the
/// window and zooms it on a double-click. The copy button right of the folder copies its full path; the button
/// at the right edge switches light and dark.
final class TitleBar: FlippedView {
    let logo = NSImageView()
    let name = label("Filee", size: 22, weight: .bold, color: .white)
    let path = label("", size: 13, weight: .bold, color: NSColor.white.withAlphaComponent(0.9))
    private let gradient = CAGradientLayer()
    private let line = ColorView(NSColor(hex: "#00000033"))
    let copyButton = TitleBarButton(symbol: "doc.on.doc", tip: "Copy the full path")
    let themeButton = TitleBarButton(symbol: "moon.fill", tip: "Switch light or dark theme (⌃⌘L)")
    /// Where the icon starts: right of the traffic lights.
    var leading: CGFloat = 84 { didSet { needsLayout = true } }

    /// The app icon's red: light top-left to dark bottom-right (assets/AppIcon.svg).
    static let lightColours = ["#ea5544", "#d63c2c", "#b8302a"]
    static let darkColours = ["#c8412f", "#ad3024", "#8a241e"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
        // A 128 px render: NSApp.applicationIconImage decodes 1024 px images and costs 35-65 MB.
        logo.image = NSImage(named: "Logo")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.shadow = NSShadow()
        logo.layer?.shadowOpacity = 0.35
        logo.layer?.shadowRadius = 3
        logo.layer?.shadowOffset = CGSize(width: 0, height: -1)
        name.font = NSFont(name: "Lato-Black", size: 22) ?? Theme.ui(22, weight: .bold)
        name.lineBreakMode = .byClipping
        path.font = Theme.ui(13, weight: .bold)
        path.alignment = .center
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        themeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        for v in [logo, name, path, copyButton, themeButton, line] as [NSView] { addSubview(v) }
        appearanceChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only the buttons take clicks: the rest of the strip lets the title bar move the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return [copyButton, themeButton].first { $0.frame.contains(p) }
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The window's own call can come before this view's appearance changes: the gradient and the theme icon lagged 1 switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged()
    }

    func appearanceChanged() {
        gradient.colors = (isDark ? Self.darkColours : Self.lightColours).map { NSColor(hex: $0).cgColor }
        // The button shows the theme a click switches to.
        themeButton.image = NSImage(systemSymbolName: isDark ? "sun.max.fill" : "moon.fill",
                                    accessibilityDescription: isDark ? "Switch to light theme" : "Switch to dark theme")
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        let s = min(36, h - 10)
        logo.frame = NSRect(x: leading, y: ((h - s) / 2).rounded(), width: s, height: s)
        let nw = textWidth(name.stringValue, font: name.font!) + 4
        name.frame = NSRect(x: logo.frame.maxX + 8, y: ((h - 28) / 2).rounded(), width: nw, height: 28)
        let pw = min(w * 0.5, textWidth(path.stringValue, font: path.font!) + 8)
        let px = max(name.frame.maxX + 24, ((w - pw) / 2).rounded())
        themeButton.frame = NSRect(x: w - 16 - 24, y: ((h - 24) / 2).rounded(), width: 24, height: 24)
        path.frame = NSRect(x: px, y: ((h - 18) / 2).rounded(), width: min(pw, themeButton.frame.minX - px - 40), height: 18)
        copyButton.frame = NSRect(x: path.frame.maxX + 4, y: ((h - 22) / 2).rounded(), width: 22, height: 22)
        line.frame = NSRect(x: 0, y: h - 1, width: w, height: 1)
    }
}

/// A button in the title bar: works on the first click, also when Filee isn't the active app.
final class TitleBarButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(symbol: String, tip: String) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
        target = self
        action = #selector(run)
        isBordered = false
        bezelStyle = .regularSquare
        imageScaling = .scaleProportionallyDown
        toolTip = tip
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func run() { onClick?() }
}
