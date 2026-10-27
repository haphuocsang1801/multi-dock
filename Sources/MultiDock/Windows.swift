import AppKit

extension NSWindow.Level {
    static let dock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
}

/// Borderless, non-activating panel: clicking a dock never steals focus from
/// the app you are working in. Fully transparent pixels are click-through.
class OverlayPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // isFloatingPanel resets the level, so it must come first.
        isFloatingPanel = true
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DockPanel: OverlayPanel {
    init() { super.init(level: .dock) }
}

/// Floating name tag shown above the hovered icon, styled like the Dock's.
final class LabelWindow: OverlayPanel {
    private let background: NSView
    private let field = NSTextField(labelWithString: "")

    init() {
        if #available(macOS 26.0, *) {
            background = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .toolTip
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            background = effect
        }
        super.init(level: .popUpMenu)
        ignoresMouseEvents = true
        hasShadow = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.alignment = .center
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            let holder = NSView()
            holder.addSubview(field)
            glass.contentView = holder
        } else {
            background.addSubview(field)
        }
        contentView = background
    }

    func show(_ text: String, near rect: NSRect, edge: DockEdge) {
        if field.stringValue != text {
            field.stringValue = text
            field.sizeToFit()
        }
        let size = NSSize(width: ceil(field.frame.width) + 24, height: ceil(field.frame.height) + 10)
        let radius = (size.height / 2).rounded()
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            background.layer?.cornerRadius = radius
        }
        let gap: CGFloat = 10
        let origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
        case .top: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - gap - size.height)
        case .left: origin = NSPoint(x: rect.maxX + gap, y: rect.midY - size.height / 2)
        case .right: origin = NSPoint(x: rect.minX - gap - size.width, y: rect.midY - size.height / 2)
        }
        let frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        if self.frame != frame { setFrame(frame, display: false) }
        field.frame = NSRect(x: 12, y: 5, width: ceil(field.frame.width), height: ceil(field.frame.height))
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}

/// Thin, practically invisible strip along a screen edge that reveals an
/// auto-hidden dock when the pointer (or a file drag) touches it.
final class EdgeTriggerWindow: OverlayPanel {
    var onEnter: (() -> Void)? {
        get { trigger.onEnter }
        set { trigger.onEnter = newValue }
    }
    private let trigger = TriggerView()

    init() {
        super.init(level: .dock)
        // Not fully transparent, so the window server routes the pointer here.
        backgroundColor = NSColor(white: 0, alpha: 0.012)
        contentView = trigger
    }

    private final class TriggerView: NSView {
        var onEnter: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onEnter?() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onEnter?()
            return []
        }
    }
}

/// Icon that follows the pointer while an item is dragged out of a dock.
final class DragIconWindow: OverlayPanel {
    private let size: CGFloat

    init(image: CGImage?, size: CGFloat) {
        self.size = size
        super.init(level: .popUpMenu)
        ignoresMouseEvents = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resizeAspect
        contentView = view
        setContentSize(NSSize(width: size, height: size))
    }

    func move(to center: NSPoint) {
        setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
        if !isVisible { orderFrontRegardless() }
    }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
