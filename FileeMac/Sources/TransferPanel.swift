import AppKit
import FileeCore

/// Copy and move progress above the status bar: 1 row per running transfer, with a bar, speed,
/// time left and a cancel button. A finished row stays 2 s at 100%, then goes.
final class TransferPanel: FlippedView {
    static let rowHeight: CGFloat = 56

    final class Row: FlippedView {
        let title = label("", size: 12.5, weight: .bold, color: Theme.fg)
        let detail = label("", size: 11.5, color: Theme.muted)
        let track = ColorView(Theme.line)
        let fill = ColorView(Theme.accent)
        let cancel: NSButton
        var fraction: Double = 0 { didSet { needsLayout = true } }
        let started = ProcessInfo.processInfo.systemUptime
        var finished = false

        init(onCancel: @escaping () -> Void) {
            cancel = ClosureButton(symbol: "xmark.circle.fill", tip: "Cancel", handler: onCancel)
            super.init(frame: .zero)
            title.lineBreakMode = .byTruncatingMiddle
            detail.alignment = .right
            for bar in [track, fill] {
                bar.wantsLayer = true
                bar.layer?.cornerRadius = Theme.radius()
                bar.layer?.masksToBounds = true
            }
            for v in [title, detail, track, fill, cancel] as [NSView] { addSubview(v) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let w = bounds.width
            let detailW = min(w * 0.45, textWidth(detail.stringValue, font: detail.font!) + 8)
            title.frame = NSRect(x: 14, y: 9, width: w - detailW - 60, height: 17)
            detail.frame = NSRect(x: w - detailW - 40, y: 10, width: detailW, height: 15)
            track.frame = NSRect(x: 14, y: 32, width: w - 54, height: 8)
            fill.frame = NSRect(x: 14, y: 32, width: max(8, (w - 54) * CGFloat(fraction)), height: 8)
            cancel.frame = NSRect(x: w - 32, y: 27, width: 18, height: 18)
        }
    }

    private(set) var rows: [ObjectIdentifier: Row] = [:]
    private var order: [ObjectIdentifier] = []
    var onHeightChange: (() -> Void)?

    var height: CGFloat { order.isEmpty ? 0 : CGFloat(order.count) * Self.rowHeight + 1 }

    private let topLine = ColorView(Theme.line)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(topLine)
        appearanceChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func appearanceChanged() {
        layer?.backgroundColor = Theme.surface2.cgColor
    }

    override func layout() {
        super.layout()
        topLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        for (i, id) in order.enumerated() {
            rows[id]?.frame = NSRect(x: 0, y: 1 + CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
    }

    /// Shows or updates the row of 1 transfer. `onCancel` is used when the row is created.
    func update(_ key: AnyObject, _ p: OperationProgress, onCancel: @escaping () -> Void) {
        let id = ObjectIdentifier(key)
        let row: Row
        if let r = rows[id] {
            row = r
        } else {
            row = Row(onCancel: onCancel)
            rows[id] = row
            order.append(id)
            addSubview(row)
            onHeightChange?()
        }
        guard !row.finished else { return }
        row.fraction = p.fraction
        var title = "\(p.title) \(min(p.itemsDone + 1, p.itemsTotal)) of \(p.itemsTotal)"
        if !p.currentName.isEmpty { title += " · \(p.currentName)" }
        row.title.stringValue = title
        row.detail.stringValue = Self.detail(p, elapsed: ProcessInfo.processInfo.systemUptime - row.started)
        row.needsLayout = true
    }

    /// Fills the bar, shows the result, removes the row after 2 s.
    func finish(_ key: AnyObject, text: String, error: Bool) {
        let id = ObjectIdentifier(key)
        guard let row = rows[id] else { return }
        row.finished = true
        row.fraction = error ? row.fraction : 1
        row.fill.color = error ? Theme.accentText : Theme.success
        row.title.stringValue = text
        row.title.textColor = error ? Theme.accentText : Theme.fg
        row.detail.stringValue = ""
        row.cancel.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 5 : 2)) { [weak self] in
            guard let self else { return }
            row.removeFromSuperview()
            self.rows[id] = nil
            self.order.removeAll { $0 == id }
            self.onHeightChange?()
        }
    }

    /// "1.2 GB of 4.0 GB · 85 MB/s · 31 s left"
    static func detail(_ p: OperationProgress, elapsed: TimeInterval) -> String {
        guard p.bytesTotal > 0 else { return "\(Int((p.fraction * 100).rounded()))%" }
        var parts = ["\(Format.size(p.bytesDone)) of \(Format.size(p.bytesTotal))"]
        if elapsed > 0.5, p.bytesDone > 0 {
            let speed = Double(p.bytesDone) / elapsed
            parts.append("\(Format.size(Int64(speed)))/s")
            let left = Double(p.bytesTotal - p.bytesDone) / speed
            parts.append(left < 60 ? "\(max(1, Int(left.rounded()))) s left" : "\(Int((left / 60).rounded())) min left")
        }
        return parts.joined(separator: " · ")
    }
}

/// An SF Symbol button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(run)
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = Theme.muted
        toolTip = tip
        imageScaling = .scaleProportionallyDown
    }

    @objc private func run() { handler() }
}
