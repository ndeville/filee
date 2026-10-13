import AppKit

/// Messages ("Copied path", "Moved 3 items to the Trash", errors) as a pill at the bottom centre of the window:
/// high contrast, large type, gone after 2.5 s (errors 6 s). Clicks pass through.
final class Toast: FlippedView {
    let title = label("", size: 14, weight: .bold, color: .white)
    let detail = label("", size: 12, color: .white)
    private(set) var isError = false
    private var hideWork: DispatchWorkItem?
    /// Where the pill sits: centred on x, bottom edge at y (flipped coordinates of the root view).
    var anchor: (x: CGFloat, bottom: CGFloat, maxWidth: CGFloat) = (0, 0, 600)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = Theme.mono(12)
        addSubview(title)
        addSubview(detail)
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The visible text, for QA.
    var text: String { isHidden ? "" : [title.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: " ") }

    func show(_ text: String, detail more: String? = nil, error: Bool = false) {
        isError = error
        title.stringValue = text
        detail.stringValue = more ?? ""
        detail.isHidden = (more ?? "").isEmpty
        applyColours()
        place()
        hideWork?.cancel()
        if isHidden || alphaValue < 1 {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 2.5), execute: work)
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        })
    }

    /// Inverted colours: black pill in light mode, white pill in dark mode, red for errors.
    func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isError ? Theme.accentFill : Theme.fg).cgColor
        }
        let ink = isError ? NSColor.white : Theme.bg
        title.textColor = ink
        detail.textColor = ink.withAlphaComponent(0.75)
    }

    func place() {
        let pad: CGFloat = 20
        let hasDetail = !detail.isHidden
        let tw = textWidth(title.stringValue, font: title.font!)
        let dw = hasDetail ? textWidth(detail.stringValue, font: detail.font!) : 0
        let w = min(anchor.maxWidth, max(tw, dw) + pad * 2 + 4)
        let h: CGFloat = hasDetail ? 56 : 38
        frame = NSRect(x: (anchor.x - w / 2).rounded(), y: anchor.bottom - h, width: w, height: h)
        title.frame = NSRect(x: pad, y: hasDetail ? 9 : 10, width: w - pad * 2, height: 19)
        detail.frame = NSRect(x: pad, y: 31, width: w - pad * 2, height: 16)
    }
}
