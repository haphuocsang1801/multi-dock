import AppKit
import QuartzCore

/// One tile shown in a dock. Display order follows the macOS Dock:
/// pinned apps | running and recent apps | pinned folders/files, Trash.
struct DisplayItem: Equatable {
    enum Kind: Equatable { case pinned, running, recent, separator, trash }

    var kind: Kind
    var key: String
    var dockItem: DockItem?
    var app: NSRunningApplication?
    var appURL: URL?
    var title: String
    var isRunning: Bool
    var isHidden = false
    var iconPath: String?

    var isApp: Bool { kind == .running || kind == .recent || dockItem?.kind == .app }
    var isFolder: Bool { dockItem?.kind == .folder }
    var fileURL: URL? { dockItem?.url ?? app?.bundleURL ?? appURL }
    /// What a custom icon is stored under: the pinned path or the app bundle, so a
    /// pinned app and the same app running unpinned share it.
    var iconKey: String? {
        dockItem?.path ?? (app?.bundleURL ?? appURL)?.resolvingSymlinksInPath().path
    }
    /// Section a drop of this item belongs to.
    var section: DockSection { kind == .pinned && dockItem?.kind != .app ? .others : .apps }
}

enum DockSection { case apps, others }

/// Proportions measured from the macOS Dock: tiles touch, the plate adds a
/// thin padding, and the separator takes about half a tile.
struct DockGeometry: Equatable {
    static let edgeGap: CGFloat = 5
    static let largestIconSize: CGFloat = 128

    var edge: DockEdge = .bottom
    var iconSize: CGFloat = 64
    var magnifiedSize: CGFloat = 64
    /// Space between neighbouring slots.
    var gap: CGFloat = 0
    var cornerRoundness: CGFloat = 0.27

    var magnify: Bool { magnifiedSize > iconSize + 0.5 }
    var padding: CGFloat { max(4, (iconSize * 0.085).rounded()) }
    var separatorLength: CGFloat { max(10, (iconSize * 0.5).rounded()) }
    var plateThickness: CGFloat { iconSize + padding * 2 }
    var cornerRadius: CGFloat { (plateThickness * min(max(cornerRoundness, 0), 0.5)).rounded() }
    var dotSize: CGFloat { max(3, (iconSize * 0.045).rounded()) }

    /// Window depth perpendicular to the edge: room for magnified icons and the launch bounce.
    static func crossLength(iconSize: CGFloat, magnifiedSize: CGFloat) -> CGFloat {
        let padding = DockGeometry(iconSize: iconSize).padding
        return (edgeGap + padding + max(magnifiedSize, iconSize * 1.6) + 6).rounded(.up)
    }
}

/// Draws a dock with Core Animation layers (one texture per icon, no drawRect)
/// and handles hover magnification, clicks, drag-to-reorder and file drops.
///
/// Geometry is computed in edge-relative coordinates: `u` runs along the edge
/// and `v` grows away from the screen edge; `viewRect` maps them to the view.
final class DockView: NSView {
    weak var controller: DockController?

    private(set) var items: [DisplayItem] = []
    private(set) var geometry = DockGeometry()
    private var configuredIconSize: CGFloat = 64
    private var configuredMagnifiedSize: CGFloat = 64
    private var showIndicators = true
    private var dimHidden = false
    private var locked = false
    private var style = DockStyle()
    private var scale: CGFloat = 2

    private let plate: NSView
    /// Sits on the plate and draws the theme: a solid fill, the border and its glow.
    private let decor = NSView()
    private let iconHost = NSView()
    private var layers: [String: SlotLayers] = [:]
    private var freshKeys: Set<String> = []

    // Results of the last layout, used for hit testing.
    private var spans: [Int: (start: CGFloat, size: CGFloat)] = [:]
    private var plateSpan: (start: CGFloat, end: CGFloat) = (0, 0)
    private var maxIconSize: CGFloat = 0

    private(set) var isHovering = false
    private var hoverU: CGFloat?
    private var hoveredKey: String?
    private var monitors: [Any] = []
    /// The label shares the menu's window level, so it stays hidden while a menu is open.
    private var isMenuOpen = false

    private var pressKey: String?
    private var pressPoint = NSPoint.zero
    private var drag: DragState?
    private var resizeStart: (point: NSPoint, size: CGFloat)?
    private var showsResizeCursor = false
    private(set) var externalGap: (section: DockSection, index: Int)?
    private var dropTargetKey: String?
    private var bouncing: [String: Date] = [:]

    private final class SlotLayers {
        let icon = CALayer()
        let dot = CALayer()
        var pixelSize = 0
        var iconPath: String?
    }

    private struct DragState {
        var key: String
        var item: DisplayItem
        var window: DragIconWindow
        var insertion: Int?
        var removing = false
        weak var target: DockController?
    }

    // MARK: - Setup

    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            plate = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            plate = effect
        }
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        plate.wantsLayer = true
        if plate is NSVisualEffectView {
            plate.layer?.masksToBounds = true
        }
        decor.wantsLayer = true
        decor.layer?.shadowOffset = .zero
        iconHost.wantsLayer = true
        iconHost.layerUsesCoreImageFilters = true
        iconHost.layerContentsRedrawPolicy = .never
        addSubview(plate)
        addSubview(decor)
        addSubview(iconHost)
        registerForDraggedTypes([.fileURL])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        iconHost.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func configure(edge: DockEdge, iconSize: CGFloat, magnifiedSize: CGFloat,
                   showIndicators: Bool, dimHidden: Bool, locked: Bool, style: DockStyle, scale: CGFloat) {
        let scaleChanged = scale != self.scale
        let changed = scaleChanged || edge != geometry.edge || iconSize != configuredIconSize
            || magnifiedSize != configuredMagnifiedSize || showIndicators != self.showIndicators
            || dimHidden != self.dimHidden || style != self.style
        if style != self.style {
            self.style = style
            geometry.gap = CGFloat(max(0, style.iconGap))
            geometry.cornerRoundness = CGFloat(style.cornerRoundness)
            updateColors()
        }
        geometry.edge = edge
        configuredIconSize = iconSize
        configuredMagnifiedSize = magnifiedSize
        self.showIndicators = showIndicators
        self.dimHidden = dimHidden
        self.locked = locked
        self.scale = scale
        guard changed || frame.size != iconHost.frame.size else { return }
        iconHost.frame = bounds
        updateEffectiveGeometry()
        if scaleChanged { layers.values.forEach { $0.pixelSize = 0 } }
        loadIcons()
        relayout(animated: false)
    }

    func setItems(_ newItems: [DisplayItem]) {
        guard newItems != items else { return }
        let newKeys = Set(newItems.map(\.key))
        for (key, slot) in layers where !newKeys.contains(key) {
            layers[key] = nil
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setCompletionBlock {
                slot.icon.removeFromSuperlayer()
                slot.dot.removeFromSuperlayer()
            }
            slot.icon.opacity = 0
            slot.dot.opacity = 0
            CATransaction.commit()
        }
        items = newItems
        for item in items where layers[item.key] == nil {
            let slot = SlotLayers()
            slot.icon.contentsGravity = .resizeAspect
            slot.icon.minificationFilter = .trilinear
            slot.icon.magnificationFilter = .linear
            slot.icon.contentsScale = scale
            slot.dot.cornerRadius = geometry.dotSize / 2
            iconHost.layer?.addSublayer(slot.icon)
            iconHost.layer?.addSublayer(slot.dot)
            layers[item.key] = slot
            freshKeys.insert(item.key)
        }
        if let d = drag, !newKeys.contains(d.key) { cancelDrag() }
        for item in items where item.isRunning && bouncing[item.key] != nil { stopBounce(key: item.key) }
        updateColors()
        updateEffectiveGeometry()
        loadIcons()
        relayout(animated: true)
    }

    private var mainLength: CGFloat { geometry.edge.isHorizontal ? bounds.width : bounds.height }

    /// Shrinks icons when there are more than the edge can hold, like the system Dock.
    private func updateEffectiveGeometry() {
        let tiles = items.filter { $0.kind != .separator }.count
        let separators = items.count - tiles
        var size = configuredIconSize
        if !items.isEmpty, mainLength > 0 {
            let units = CGFloat(tiles) + 0.5 * CGFloat(separators) + 0.17
            let gaps = geometry.gap * CGFloat(items.count - 1)
            size = min(size, max(16, ((mainLength - 24 - gaps) / units).rounded(.down)))
        }
        geometry.iconSize = size
        geometry.magnifiedSize = max(size, configuredMagnifiedSize)
    }

    /// Re-renders every icon, e.g. after the system icon style changed.
    func reloadIcons() {
        layers.values.forEach { $0.iconPath = nil }
        loadIcons()
    }

    /// While the separator is dragged the icons stay at the largest size, so each
    /// step only rescales them instead of rendering every icon again.
    private var iconPixelSize: Int {
        let points = resizeStart != nil ? DockGeometry.largestIconSize : max(configuredIconSize, configuredMagnifiedSize)
        return Int((points * scale).rounded(.up))
    }

    private func loadIcons() {
        let pixelSize = iconPixelSize
        for item in items where item.kind != .separator {
            guard let slot = layers[item.key] else { continue }
            let path = item.iconPath ?? item.dockItem?.path ?? item.appURL?.path
            guard slot.pixelSize != pixelSize || slot.iconPath != path else { continue }
            slot.pixelSize = pixelSize
            slot.iconPath = path
            slot.icon.contentsScale = scale
            slot.icon.contents = IconCache.shared.image(path: path, app: item.app, pixelSize: pixelSize)
        }
    }

    /// Applies the theme: plate kind, fill, border, glow, indicator and separator colors.
    private func updateColors() {
        let s = style
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink = s.usesSystemColors ? NSColor.labelColor : s.indicatorColor.nsColor
            let dot = ink.withAlphaComponent(s.usesSystemColors ? 0.55 : ink.alphaComponent).cgColor
            let separator = ink.withAlphaComponent(0.28 * (s.usesSystemColors ? 1 : 1.6)).cgColor
            for item in items {
                guard let slot = layers[item.key] else { continue }
                slot.dot.backgroundColor = dot
                if item.kind == .separator { slot.icon.backgroundColor = separator }
            }

            let fill = s.backgroundColor.nsColor
            let fillAlpha = fill.alphaComponent * CGFloat(min(max(s.backgroundOpacity, 0), 1))
            plate.isHidden = s.background != .glass
            if #available(macOS 26.0, *), let glass = plate as? NSGlassEffectView {
                glass.tintColor = s.usesSystemColors ? nil : fill.withAlphaComponent(fillAlpha)
            }

            guard let layer = decor.layer else { return }
            decor.isHidden = s.background == .none
            switch s.background {
            case .solid:
                let color = s.usesSystemColors ? NSColor.windowBackgroundColor.withAlphaComponent(0.85)
                    : fill.withAlphaComponent(fillAlpha)
                layer.backgroundColor = color.cgColor
            case .glass where !s.usesSystemColors:
                // The glass tint alone barely shows (and the HUD material has none),
                // so a translucent wash over the glass carries the color.
                layer.backgroundColor = fill.withAlphaComponent(fillAlpha * 0.6).cgColor
            default:
                layer.backgroundColor = nil
            }
            // The system glass draws its own rim; the older material and themes need one.
            let systemRim = s.usesSystemColors && (s.background == .solid || plate is NSVisualEffectView)
            let border = s.usesSystemColors ? NSColor.white.withAlphaComponent(0.2) : s.borderColor.nsColor
            layer.borderWidth = systemRim || !s.usesSystemColors ? CGFloat(max(0, s.borderWidth)) : 0
            layer.borderColor = border.cgColor
            let glow = s.glow && !s.usesSystemColors && s.borderWidth > 0
            layer.shadowColor = border.withAlphaComponent(1).cgColor
            layer.shadowRadius = glow ? 8 : 0
            layer.shadowOpacity = glow ? 0.9 : 0
        }
    }

    // MARK: - Coordinates

    private func viewRect(u: CGFloat, v: CGFloat, du: CGFloat, dv: CGFloat) -> CGRect {
        let w = bounds.width, h = bounds.height
        switch geometry.edge {
        case .bottom: return CGRect(x: u, y: v, width: du, height: dv)
        case .top: return CGRect(x: u, y: h - v - dv, width: du, height: dv)
        case .left: return CGRect(x: v, y: h - u - du, width: dv, height: du)
        case .right: return CGRect(x: w - v - dv, y: h - u - du, width: dv, height: du)
        }
    }

    private func uv(_ p: NSPoint) -> CGPoint {
        let w = bounds.width, h = bounds.height
        switch geometry.edge {
        case .bottom: return CGPoint(x: p.x, y: p.y)
        case .top: return CGPoint(x: p.x, y: h - p.y)
        case .left: return CGPoint(x: h - p.y, y: p.x)
        case .right: return CGPoint(x: h - p.y, y: w - p.x)
        }
    }

    private func viewPoint(fromScreen point: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }

    // MARK: - Layout

    private struct Strip {
        var starts: [CGFloat]
        var sizes: [CGFloat]
        var plateStart: CGFloat
        var plateEnd: CGFloat
    }

    private var currentGap: (section: DockSection, index: Int)? {
        if let d = drag, let insertion = d.insertion { return (d.item.section, insertion) }
        return externalGap
    }

    /// Visible slots in order: item indices, with `nil` for an open drop gap.
    private func entries(includeGap: Bool) -> [Int?] {
        var list: [Int?] = items.indices.filter { items[$0].key != drag?.key }
        guard includeGap, let gap = currentGap else { return list }
        let sectionSlots = list.enumerated().filter { _, entry in
            guard let i = entry else { return false }
            return items[i].kind == .pinned && items[i].section == gap.section
        }.map(\.offset)
        let position: Int
        if gap.index < sectionSlots.count {
            position = sectionSlots[gap.index]
        } else if let last = sectionSlots.last {
            position = last + 1
        } else if gap.section == .apps {
            position = 0
        } else {
            position = list.firstIndex { $0.map { items[$0].kind == .trash } ?? false } ?? list.count
        }
        list.insert(nil, at: position)
        return list
    }

    private func baseSize(_ entry: Int?) -> CGFloat {
        guard let i = entry, items[i].kind == .separator else { return geometry.iconSize }
        return geometry.separatorLength
    }

    private func layoutStrip(_ entries: [Int?], hoverU: CGFloat?) -> Strip {
        let g = geometry
        let base = entries.map(baseSize)
        let n = base.count
        let content = (n == 0 ? g.iconSize : base.reduce(0, +) + g.gap * CGFloat(n - 1)) + g.padding * 2
        let stripStart = ((mainLength - content) / 2).rounded()
        guard n > 0 else {
            return Strip(starts: [], sizes: [], plateStart: stripStart, plateEnd: stripStart + content)
        }

        var baseStarts: [CGFloat] = []
        var u = stripStart + g.padding
        for size in base {
            baseStarts.append(u)
            u += size + g.gap
        }

        var sizes = base
        var starts = baseStarts
        if let p = hoverU, g.magnify {
            // Cosine falloff around the pointer, then shift so the point under the
            // pointer stays put while neighbours grow away from it.
            let radius = g.iconSize * 2.5
            for i in 0..<n where entries[i].map({ items[$0].kind != .separator }) ?? true {
                let d = abs(baseStarts[i] + base[i] / 2 - p)
                if d < radius {
                    sizes[i] = g.iconSize + (g.magnifiedSize - g.iconSize) * (1 + cos(.pi * d / radius)) / 2
                }
            }
            var grown: CGFloat = 0
            var provisional = [CGFloat](repeating: 0, count: n)
            for i in 0..<n {
                provisional[i] = baseStarts[i] + grown
                grown += sizes[i] - base[i]
            }
            // Each slot owns the gap after it, so the strip stays continuous across gaps.
            var k = 0
            for i in 0..<n where p >= baseStarts[i] { k = i }
            let fraction = min(max((p - baseStarts[k]) / (base[k] + g.gap), 0), 1)
            let shift = provisional[k] + fraction * (sizes[k] + g.gap) - p
            starts = provisional.map { $0 - shift }
        }
        return Strip(starts: starts, sizes: sizes,
                     plateStart: starts[0] - g.padding,
                     plateEnd: starts[n - 1] + sizes[n - 1] + g.padding)
    }

    func relayout(animated: Bool, duration: CFTimeInterval = 0.2) {
        let g = geometry
        let list = entries(includeGap: true)
        let magnifyNow = drag == nil && externalGap == nil && dropTargetKey == nil && resizeStart == nil
        let strip = layoutStrip(list, hoverU: magnifyNow ? hoverU : nil)

        // Newly added slots appear in place and fade in instead of flying in.
        if !freshKeys.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (j, entry) in list.enumerated() {
                guard let i = entry, freshKeys.contains(items[i].key), let slot = layers[items[i].key] else { continue }
                slot.icon.frame = iconFrame(items[i], start: strip.starts[j], size: strip.sizes[j])
                slot.icon.opacity = 0
                slot.dot.opacity = 0
            }
            CATransaction.commit()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        spans.removeAll(keepingCapacity: true)
        var maxSize: CGFloat = g.iconSize
        for (j, entry) in list.enumerated() {
            guard let i = entry, let slot = layers[items[i].key] else { continue }
            let item = items[i]
            let start = strip.starts[j], size = strip.sizes[j]
            spans[i] = (start, size)
            maxSize = max(maxSize, size)
            if !animated {
                // Follow the pointer immediately instead of finishing an older animation.
                for key in ["position", "bounds"] {
                    slot.icon.removeAnimation(forKey: key)
                    slot.dot.removeAnimation(forKey: key)
                }
            }
            slot.icon.frame = iconFrame(item, start: start, size: size)
            slot.icon.opacity = dimHidden && item.isHidden ? 0.5 : 1
            slot.icon.transform = item.key == dropTargetKey
                ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
            let dot = g.dotSize
            slot.dot.cornerRadius = dot / 2
            slot.dot.frame = viewRect(u: (start + size / 2 - dot / 2).rounded(),
                                      v: (DockGeometry.edgeGap + g.padding * 0.62 - dot / 2).rounded(),
                                      du: dot, dv: dot)
            slot.dot.opacity = showIndicators && item.isRunning ? 1 : 0
        }
        if let d = drag, let slot = layers[d.key] {
            slot.icon.opacity = 0
            slot.dot.opacity = 0
        }
        freshKeys.removeAll()
        CATransaction.commit()

        plateSpan = (strip.plateStart, strip.plateEnd)
        maxIconSize = maxSize
        let plateFrame = viewRect(u: strip.plateStart, v: DockGeometry.edgeGap,
                                  du: strip.plateEnd - strip.plateStart, dv: g.plateThickness).integral
        if #available(macOS 26.0, *), let glass = plate as? NSGlassEffectView {
            glass.cornerRadius = g.cornerRadius
        } else {
            plate.layer?.cornerRadius = g.cornerRadius
        }
        decor.layer?.cornerRadius = g.cornerRadius
        // Always go through the animator: a zero-duration set also cancels an
        // in-flight resize, so pointer moves never fight an exit animation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? duration : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            plate.animator().frame = plateFrame
            decor.animator().frame = plateFrame
        }
        if isHovering { updateLabel() }
    }

    private func iconFrame(_ item: DisplayItem, start: CGFloat, size: CGFloat) -> CGRect {
        let g = geometry
        if item.kind == .separator {
            let length = (g.iconSize * 0.86).rounded()
            return viewRect(u: (start + size / 2).rounded(),
                            v: DockGeometry.edgeGap + (g.plateThickness - length) / 2,
                            du: 1, dv: length)
        }
        return viewRect(u: start, v: DockGeometry.edgeGap + g.padding, du: size, dv: size)
    }

    // MARK: - Hit testing

    /// Index of the slot along the edge at `p`, separators included.
    private func slotIndex(at p: NSPoint) -> Int? {
        guard bounds.contains(p) else { return nil }
        let q = uv(p)
        guard q.y <= DockGeometry.edgeGap + geometry.padding + maxIconSize + 2 else { return nil }
        let half = geometry.gap / 2
        for (i, span) in spans where q.x >= span.start - half && q.x < span.start + span.size + half {
            return i
        }
        return nil
    }

    /// Index of the clickable tile at `p` (never a separator).
    private func index(at p: NSPoint) -> Int? {
        slotIndex(at: p).flatMap { items[$0].kind == .separator ? nil : $0 }
    }

    private func isInHoverRegion(_ p: NSPoint) -> Bool {
        guard bounds.contains(p) else { return false }
        let q = uv(p)
        guard q.x >= plateSpan.start, q.x <= plateSpan.end else { return false }
        let reach = isHovering
            ? DockGeometry.edgeGap + geometry.padding + maxIconSize
            : DockGeometry.edgeGap + geometry.plateThickness
        return q.y <= reach
    }

    /// Screen rect of the plate, grown by `margin`, for finding the dock under a drag.
    func dropRegion(margin: CGFloat) -> NSRect? {
        guard let window, window.isVisible else { return nil }
        let rect = viewRect(u: plateSpan.start - margin, v: 0,
                            du: plateSpan.end - plateSpan.start + margin * 2,
                            dv: DockGeometry.edgeGap + geometry.plateThickness + margin)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func screenRect(forItemAt index: Int) -> NSRect? {
        guard let window, let span = spans[index] else { return nil }
        let rect = iconFrame(items[index], start: span.start, size: span.size)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func screenRect(forKey key: String) -> NSRect? {
        items.firstIndex { $0.key == key }.flatMap(screenRect(forItemAt:))
    }

    // MARK: - Hover & magnification

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                 .cursorUpdate, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if !isHovering { handlePointer(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseMoved(with event: NSEvent) {
        // While hovering the event monitors below already deliver every move.
        if !isHovering { handlePointer(convert(event.locationInWindow, from: nil)) }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil), force: true)
    }

    /// AppKit asks for a cursor only when the pointer enters the view, which is
    /// over the plate, so every move re-checks whether it is on the separator.
    private func updateCursor(at p: NSPoint, force: Bool = false) {
        let onHandle = resizeStart != nil
            || (!locked && slotIndex(at: p).map { items[$0].kind == .separator } == true)
        if onHandle {
            (geometry.edge.isHorizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        } else if showsResizeCursor || force {
            NSCursor.arrow.set()
        }
        showsResizeCursor = onHandle
    }

    private func handlePointer(_ p: NSPoint) {
        guard drag == nil, resizeStart == nil else { return }
        updateCursor(at: p)
        if isInHoverRegion(p) {
            let entering = !isHovering
            if entering { beginHover() }
            hoverU = uv(p).x
            relayout(animated: entering, duration: 0.1)
            hoveredKey = index(at: p).map { items[$0].key }
            updateLabel()
        } else if isHovering {
            endHover()
        }
    }

    private func pointerMovedOnScreen() {
        guard let p = viewPoint(fromScreen: NSEvent.mouseLocation) else { return }
        handlePointer(p)
    }

    /// Pointer moves over transparent pixels go to other apps, so while the dock
    /// is hovered it listens globally; the monitors exist only during a hover.
    private func beginHover() {
        isHovering = true
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.pointerMovedOnScreen()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.pointerMovedOnScreen()
            return event
        }) { monitors.append(local) }
        controller?.hoverChanged(true)
    }

    private func endHover(relayoutAfter: Bool = true) {
        isHovering = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hoverU = nil
        hoveredKey = nil
        controller?.label.hide()
        if relayoutAfter { relayout(animated: true) }
        controller?.hoverChanged(false)
    }

    private func updateLabel() {
        guard !isMenuOpen, let key = hoveredKey, pressKey == nil, let i = items.firstIndex(where: { $0.key == key }),
              let rect = screenRect(forItemAt: i) else {
            controller?.label.hide()
            return
        }
        controller?.label.show(items[i].title, near: rect, edge: geometry.edge)
    }

    // MARK: - Clicks

    private func setPressed(_ key: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, slot) in layers {
            let pressed = k == key
            if pressed, slot.icon.filters == nil {
                let darken = CIFilter(name: "CIColorControls")!
                darken.setValue(-0.28, forKey: kCIInputBrightnessKey)
                slot.icon.filters = [darken]
            } else if !pressed, slot.icon.filters != nil {
                slot.icon.filters = nil
            }
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) {
            showMenu(for: event, at: p)
            return
        }
        if !locked, let i = slotIndex(at: p), items[i].kind == .separator {
            resizeStart = (NSEvent.mouseLocation, configuredIconSize)
            loadIcons()
            if isHovering { endHover() }
            return
        }
        pressKey = index(at: p).map { items[$0].key }
        pressPoint = p
        setPressed(pressKey)
        controller?.label.hide()
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = resizeStart {
            let now = NSEvent.mouseLocation
            let delta: CGFloat
            switch geometry.edge {
            case .bottom: delta = now.y - start.point.y
            case .top: delta = start.point.y - now.y
            case .left: delta = now.x - start.point.x
            case .right: delta = start.point.x - now.x
            }
            controller?.resize(to: start.size + delta)
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard !locked, let key = pressKey, let i = items.firstIndex(where: { $0.key == key }),
                  items[i].kind != .trash,
                  hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 5 else { return }
            setPressed(nil)
            beginDrag(i)
        }
        updateDrag()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressKey = nil
            setPressed(nil)
        }
        if resizeStart != nil {
            resizeStart = nil
            loadIcons()
            pointerMovedOnScreen()
            return
        }
        if drag != nil {
            finishDrag()
            return
        }
        guard let key = pressKey, let i = index(at: convert(event.locationInWindow, from: nil)),
              items[i].key == key else { return }
        let item = items[i]
        if event.modifierFlags.contains(.command), let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            controller?.activate(item, anchor: screenRect(forItemAt: i))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event, at: convert(event.locationInWindow, from: nil))
    }

    private func showMenu(for event: NSEvent, at p: NSPoint) {
        guard let controller else { return }
        controller.label.hide()
        StackPanel.dismissCurrent()
        let i = index(at: p)
        let menu = controller.menu(for: i.map { items[$0] })
        if let i, let span = spans[i] {
            popUp(menu, centeredOn: span.start + span.size / 2, outside: span)
        } else {
            popUp(menu, centeredOn: uv(p).x, outside: nil)
        }
        pointerMovedOnScreen()
        if !isHovering { controller.hoverChanged(false) }
    }

    func showMenu(_ menu: NSMenu, forItem item: DisplayItem) {
        guard let i = items.firstIndex(where: { $0.key == item.key }), let span = spans[i] else { return }
        controller?.label.hide()
        popUp(menu, centeredOn: span.start + span.size / 2, outside: span)
        pointerMovedOnScreen()
    }

    /// Opens `menu` beyond the plate (and the possibly magnified icon), centered
    /// on the icon along the edge, the way the system Dock places its menus.
    private func popUp(_ menu: NSMenu, centeredOn u: CGFloat, outside span: (start: CGFloat, size: CGFloat)?) {
        let g = geometry
        // The menu draws a few points above the requested corner, so this leaves a
        // gap of about 9pt, close to the Dock's own.
        let reach = DockGeometry.edgeGap + max(g.plateThickness, g.padding + (span?.size ?? 0)) + 4
        // NSMenu.size counts ⌥-alternates (Force Quit) that are not drawn.
        // Hiding them does not refresh the cached size, so take them out briefly.
        let alternates = menu.items.enumerated().filter { $0.element.isAlternate }
        alternates.reversed().forEach { menu.removeItem(at: $0.offset) }
        let size = menu.size
        alternates.forEach { menu.insertItem($0.element, at: $0.offset) }
        let w = bounds.width, h = bounds.height
        // popUp(positioning:at:in:) places the menu's top-left corner at the point.
        let corner: NSPoint
        switch g.edge {
        case .bottom: corner = NSPoint(x: u - size.width / 2, y: reach + size.height)
        case .top: corner = NSPoint(x: u - size.width / 2, y: h - reach)
        case .left: corner = NSPoint(x: reach, y: h - u + size.height / 2)
        case .right: corner = NSPoint(x: w - reach - size.width, y: h - u + size.height / 2)
        }
        // popUp returns only once the menu closes.
        isMenuOpen = true
        controller?.label.hide()
        menu.popUp(positioning: nil, at: corner, in: self)
        isMenuOpen = false
    }

    // MARK: - Launch bounce

    private var bounceOffset: NSSize {
        let h = (geometry.iconSize * 0.5).rounded()
        switch geometry.edge {
        case .bottom: return NSSize(width: 0, height: h)
        case .top: return NSSize(width: 0, height: -h)
        case .left: return NSSize(width: h, height: 0)
        case .right: return NSSize(width: -h, height: 0)
        }
    }

    /// Bounces like the system Dock until the app finishes launching (max ~10 s).
    func startBounce(key: String) {
        guard let layer = layers[key]?.icon else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation")
        anim.values = [NSValue(size: .zero), NSValue(size: bounceOffset), NSValue(size: .zero)]
        anim.keyTimes = [0, 0.5, 1]
        anim.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        anim.duration = 0.62
        anim.repeatCount = 16
        layer.add(anim, forKey: "bounce")
        bouncing[key] = Date()
    }

    private func stopBounce(key: String) {
        bouncing[key] = nil
        guard let layer = layers[key]?.icon, layer.animation(forKey: "bounce") != nil else { return }
        let current = (layer.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue ?? .zero
        layer.removeAnimation(forKey: "bounce")
        let settle = CABasicAnimation(keyPath: "transform.translation")
        settle.fromValue = NSValue(size: current)
        settle.toValue = NSValue(size: .zero)
        settle.duration = 0.18
        settle.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(settle, forKey: "settle")
    }

    // MARK: - Dragging icons

    /// Insertion point within `section` (ignoring the dragged item) for a
    /// position along the edge, computed on the gap-free layout so it is stable.
    private func insertion(atU u: CGFloat, section: DockSection) -> Int {
        let list = entries(includeGap: false)
        let strip = layoutStrip(list, hoverU: nil)
        var count = 0
        for (j, entry) in list.enumerated() {
            guard let i = entry, items[i].kind == .pinned, items[i].section == section else { continue }
            if strip.starts[j] + strip.sizes[j] / 2 < u { count += 1 }
        }
        return count
    }

    private func trashKey(atU u: CGFloat) -> String? {
        let list = entries(includeGap: false)
        let strip = layoutStrip(list, hoverU: nil)
        for (j, entry) in list.enumerated() {
            guard let i = entry, items[i].kind == .trash else { continue }
            if u >= strip.starts[j], u <= strip.starts[j] + strip.sizes[j] { return items[i].key }
        }
        return nil
    }

    private func beginDrag(_ i: Int) {
        let item = items[i]
        guard item.kind != .separator else { return }
        let image = layers[item.key]?.icon.contents
        let window = DragIconWindow(image: image.map { $0 as! CGImage }, size: geometry.iconSize)
        drag = DragState(key: item.key, item: item, window: window, insertion: nil)
        if isHovering { endHover(relayoutAfter: false) }
        controller?.hoverChanged(true)
    }

    private func updateDrag() {
        guard var d = drag, let controller else { return }
        let point = NSEvent.mouseLocation
        d.window.move(to: point)
        let target = controller.manager?.controller(at: point)
        if let previous = d.target, previous !== target, previous !== controller {
            previous.dockView.clearExternalGap()
        }
        d.target = target
        var overTrash = false
        if target === controller, let p = viewPoint(fromScreen: point) {
            let u = uv(p).x
            overTrash = trashKey(atU: u) != nil
            d.insertion = overTrash ? nil : insertion(atU: u, section: d.item.section)
            d.removing = overTrash && d.item.kind == .pinned
        } else if let target {
            d.insertion = nil
            d.removing = false
            target.dockView.showExternalGap(atScreen: point, section: d.item.section)
        } else {
            d.insertion = nil
            d.removing = d.item.kind == .pinned
        }
        d.window.alphaValue = d.removing ? 0.5 : 1
        (d.removing && !overTrash ? NSCursor.disappearingItem : NSCursor.arrow).set()
        let changed = d.insertion != drag?.insertion
        drag = d
        if changed { relayout(animated: true) }
    }

    private func finishDrag() {
        guard let d = drag, let controller else { return }
        d.window.orderOut(nil)
        NSCursor.arrow.set()
        drag = nil
        if let target = d.target, target !== controller {
            let index = target.dockView.externalGap?.index ?? Int.max
            target.dockView.clearExternalGap()
            controller.transfer(d.item, to: target, at: index)
        } else if let insertion = d.insertion {
            controller.place(d.item, at: insertion)
        } else if d.removing {
            controller.remove(d.item)
        }
        relayout(animated: true)
        pointerMovedOnScreen()
        if !isHovering { controller.hoverChanged(false) }
    }

    private func cancelDrag() {
        drag?.window.orderOut(nil)
        drag?.target?.dockView.clearExternalGap()
        drag = nil
        NSCursor.arrow.set()
    }

    func showExternalGap(atScreen point: NSPoint, section: DockSection) {
        guard !locked, let p = viewPoint(fromScreen: point) else { return }
        let index = insertion(atU: uv(p).x, section: section)
        guard externalGap?.index != index || externalGap?.section != section else { return }
        externalGap = (section, index)
        relayout(animated: true)
    }

    func clearExternalGap() {
        guard externalGap != nil else { return }
        externalGap = nil
        relayout(animated: true)
    }

    // MARK: - File drops from Finder

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.reveal()
        controller?.hoverChanged(true)
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return [] }
        let u = uv(convert(sender.draggingLocation, from: nil)).x
        let allApps = urls.allSatisfy { $0.pathExtension.lowercased() == "app" }

        // Decide on the gap-free layout: dropping onto the centre of an app opens
        // the files with it, onto the Trash trashes them, anywhere else pins them.
        var target = trashKey(atU: u)
        if target == nil, !allApps {
            let list = entries(includeGap: false)
            let strip = layoutStrip(list, hoverU: nil)
            for (j, entry) in list.enumerated() {
                guard let i = entry, items[i].isApp else { continue }
                if abs(strip.starts[j] + strip.sizes[j] / 2 - u) < geometry.iconSize * 0.32 {
                    target = items[i].key
                }
            }
        }
        let section: DockSection = allApps ? .apps : .others
        let gap = target == nil && !locked ? (section, insertion(atU: u, section: section)) : nil
        if target != dropTargetKey || gap?.1 != externalGap?.index || gap?.0 != externalGap?.section {
            dropTargetKey = target
            externalGap = gap
            if isHovering { endHover(relayoutAfter: false) }
            relayout(animated: true)
        }
        if target != nil { return target?.hasPrefix("trash") == true ? .move : .generic }
        return gap != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetKey = nil
        externalGap = nil
        relayout(animated: true)
        controller?.hoverChanged(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        let target = dropTargetKey.flatMap { key in items.first { $0.key == key } }
        let gap = externalGap
        dropTargetKey = nil
        externalGap = nil
        if let target {
            if target.kind == .trash {
                AppActions.moveToTrash(urls)
            } else {
                controller?.open(urls, with: target)
            }
        } else if let gap {
            controller?.insert(urls, at: gap.index, section: gap.section)
        }
        relayout(animated: true)
        controller?.hoverChanged(false)
        return true
    }
}
