import AppKit
import ObjectiveC

/// Square window corners (settings.json "windowCorners": "square").
/// AppKit has no public setting for the window shape. It asks the window for a corner mask through a private method
/// (`_cornerMask`, macOS 26); a window that answers with a square image gets square corners and a square shadow.
/// If a later macOS stops asking, the windows stay rounded and nothing else changes.
enum WindowCorners {
    static let maskSelector = NSSelectorFromString("_cornerMask")
    private static let changedSelector = NSSelectorFromString("_cornerMaskChanged")

    static var square: Bool { Theme.settings.windowCorners == "square" }

    /// 3 px of black, stretched by its cap insets to the whole window.
    private static let squareMask: NSImage = {
        let image = NSImage(size: NSSize(width: 3, height: 3), flipped: false) { r in
            NSColor.black.setFill()
            r.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        return image
    }()

    /// The mask for `window`: square, or what AppKit's own class gives.
    static func mask(for window: NSWindow, appKitClass: AnyClass) -> NSImage? {
        if square { return squareMask }
        guard class_getInstanceMethod(appKitClass, maskSelector) != nil,
              let imp = class_getMethodImplementation(appKitClass, maskSelector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSImage?
        return unsafeBitCast(imp, to: Getter.self)(window, maskSelector)
    }

    /// settings.json changed: every window asks for its mask again.
    static func refresh() {
        for w in NSApp.windows where w.responds(to: changedSelector) {
            w.perform(changedSelector)
            w.invalidateShadow()
            w.contentView?.superview?.needsDisplay = true
        }
    }
}

/// A window whose corners follow settings.json.
class FileeWindow: NSWindow {
    @objc func _cornerMask() -> NSImage? { WindowCorners.mask(for: self, appKitClass: NSWindow.self) }
}

/// A panel whose corners follow settings.json.
class FileePanel: NSPanel {
    @objc func _cornerMask() -> NSImage? { WindowCorners.mask(for: self, appKitClass: NSPanel.self) }
}
