import AppKit

enum FolderContents {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey,
        .contentModificationDateKey, .localizedTypeDescriptionKey,
    ]

    static func load(_ folder: URL, sort: FolderSort) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let values = Dictionary(uniqueKeysWithValues: urls.map { ($0, try? $0.resourceValues(forKeys: Set(keys))) })
        func byName(_ a: URL, _ b: URL) -> Bool {
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        return urls.sorted { a, b in
            let va = values[a] ?? nil, vb = values[b] ?? nil
            switch sort {
            case .name:
                return byName(a, b)
            case .dateAdded:
                return (va?.addedToDirectoryDate ?? .distantPast) > (vb?.addedToDirectoryDate ?? .distantPast)
            case .dateModified:
                return (va?.contentModificationDate ?? .distantPast) > (vb?.contentModificationDate ?? .distantPast)
            case .kind:
                let ka = va?.localizedTypeDescription ?? "", kb = vb?.localizedTypeDescription ?? ""
                return ka == kb ? byName(a, b) : ka.localizedStandardCompare(kb) == .orderedAscending
            }
        }
    }

    static func isBrowsableFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }
}

/// Grid "stack" that pops out of a folder tile, like the macOS Dock's Grid view.
final class StackPanel: OverlayPanel {
    private static var current: StackPanel?

    private let folder: URL
    private var monitors: [Any] = []
    private var path: [URL]

    static func toggle(folder: URL, sort: FolderSort, anchor: NSRect, edge: DockEdge) {
        if let open = current {
            open.dismiss()
            if open.folder == folder { return }
        }
        let panel = StackPanel(folder: folder)
        current = panel
        panel.show(sort: sort, anchor: anchor, edge: edge)
    }

    static func dismissCurrent() { current?.dismiss() }

    private init(folder: URL) {
        self.folder = folder
        path = [folder]
        super.init(level: .popUpMenu)
        hasShadow = true
    }

    private var sort: FolderSort = .name
    private var anchor: NSRect = .zero
    private var edge: DockEdge = .bottom

    private func show(sort: FolderSort, anchor: NSRect, edge: DockEdge) {
        self.sort = sort
        self.anchor = anchor
        self.edge = edge
        rebuild()
        orderFrontRegardless()
        let dismissOnOutsideClick: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                     handler: dismissOnOutsideClick) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            dismissOnOutsideClick(event)
            return event
        }) { monitors.append(l) }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    private func open(_ url: URL) {
        if FolderContents.isBrowsableFolder(url) {
            path.append(url)
            rebuild()
        } else {
            NSWorkspace.shared.open(url)
            dismiss()
        }
    }

    private func rebuild() {
        let current = path.last!
        let urls = FolderContents.load(current, sort: sort).prefix(300)

        let cell = NSSize(width: 96, height: 92)
        let columns = max(1, min(urls.count, urls.count > 16 ? 6 : 5))
        let rows = Int(ceil(Double(max(urls.count, 1)) / Double(columns)))
        let gridSize = NSSize(width: CGFloat(columns) * cell.width, height: CGFloat(rows) * cell.height)
        let inset: CGFloat = 14, header: CGFloat = 34, footer: CGFloat = 40
        let visibleHeight = min(gridSize.height, cell.height * 4.5)
        let size = NSSize(width: max(gridSize.width, 260) + inset * 2,
                          height: visibleHeight + header + footer + inset)

        let background = Self.makeBackground()
        background.frame = NSRect(origin: .zero, size: size)

        let title = NSTextField(labelWithString: FileManager.default.displayName(atPath: current.path))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 40, y: size.height - header + 4, width: size.width - 80, height: 22)
        background.addSubview(title)

        if path.count > 1 {
            let back = NSButton(title: "", image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Quay lại")!,
                                target: self, action: #selector(goBack))
            back.isBordered = false
            back.frame = NSRect(x: inset, y: size.height - header + 4, width: 24, height: 22)
            background.addSubview(back)
        }

        let grid = FlippedView(frame: NSRect(origin: .zero, size: NSSize(width: max(gridSize.width, 260), height: max(gridSize.height, visibleHeight))))
        let xOffset = (grid.frame.width - gridSize.width) / 2
        for (i, url) in urls.enumerated() {
            let tile = StackTile(url: url) { [weak self] in self?.open(url) }
            tile.frame = NSRect(x: xOffset + CGFloat(i % columns) * cell.width,
                                y: CGFloat(i / columns) * cell.height,
                                width: cell.width, height: cell.height)
            grid.addSubview(tile)
        }
        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "Thư mục trống")
            empty.textColor = .secondaryLabelColor
            empty.sizeToFit()
            empty.setFrameOrigin(NSPoint(x: (grid.frame.width - empty.frame.width) / 2, y: 30))
            grid.addSubview(empty)
        }
        let scroll = NSScrollView(frame: NSRect(x: inset, y: footer, width: size.width - inset * 2, height: visibleHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = gridSize.height > visibleHeight
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        background.addSubview(scroll)

        let openButton = NSButton(title: "Mở trong Finder", target: self, action: #selector(openInFinder))
        openButton.bezelStyle = .rounded
        openButton.sizeToFit()
        openButton.setFrameOrigin(NSPoint(x: (size.width - openButton.frame.width) / 2, y: 8))
        background.addSubview(openButton)

        contentView = background
        setFrame(NSRect(origin: origin(for: size), size: size), display: true)
    }

    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 10
        var p: NSPoint
        switch edge {
        case .bottom: p = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .top: p = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        case .left: p = NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right: p = NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let vf = screen.visibleFrame
            p.x = min(max(p.x, vf.minX + 8), vf.maxX - size.width - 8)
            p.y = min(max(p.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return p
    }

    @objc private func goBack() {
        guard path.count > 1 else { return }
        path.removeLast()
        rebuild()
    }

    @objc private func openInFinder() {
        NSWorkspace.shared.open(path.last!)
        dismiss()
    }

    static func makeBackground() -> NSView {
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            view = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true
            view = effect
        }
        return view
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Icon + name cell inside a stack; highlights on hover.
private final class StackTile: NSView {
    private let action: () -> Void
    private let highlight = CALayer()

    init(url: URL, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerRadius = 10
        highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: 18, y: 6, width: 60, height: 52)
        addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: FileManager.default.displayName(atPath: url.path))
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 4, y: 60, width: 88, height: 30)
        addSubview(label)
        toolTip = url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 4, dy: 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { highlight.opacity = 1 }
    override func mouseExited(with event: NSEvent) { highlight.opacity = 0 }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
