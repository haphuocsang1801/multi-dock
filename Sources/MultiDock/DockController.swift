import AppKit

/// One dock on one display: owns its panel, auto-hide behaviour and the
/// actions behind clicks, menus and drops.
final class DockController {
    let id: UUID
    private(set) var config: DockConfig
    private(set) var screen: NSScreen
    weak var manager: DockManager?

    let panel = DockPanel()
    let dockView = DockView(frame: .zero)
    let label = LabelWindow()
    private let root = NSView()
    private var trigger: EdgeTriggerWindow?
    private var hideWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private(set) var isAutoHidden = false
    private var isFullScreen = false
    /// The system Dock is, or can appear, on this dock's edge of this display, so
    /// this dock stays out of sight instead of stacking on top of it.
    private var yieldsToSystemDock = false

    /// Auto-hide is on, the display shows a full-screen app, or the system Dock has this edge.
    private var autoHides: Bool {
        config.autoHide || (config.hideInFullScreen && isFullScreen) || yieldsToSystemDock
    }

    private var store: ConfigStore? { manager?.store }
    private static let recentLimit = 3

    init(config: DockConfig, screen: NSScreen, manager: DockManager) {
        id = config.id
        self.config = config
        self.screen = screen
        self.manager = manager
        root.wantsLayer = true
        root.addSubview(dockView)
        panel.contentView = root
        dockView.controller = self
        apply(config, screen: screen)
    }

    func close() {
        hideWork?.cancel()
        revealWork?.cancel()
        label.hide()
        trigger?.orderOut(nil)
        panel.orderOut(nil)
    }

    // MARK: - Configuration

    func apply(_ cfg: DockConfig, screen: NSScreen) {
        config = cfg
        self.screen = screen
        let size = CGFloat(cfg.iconSize)
        let magnified = cfg.magnification ? max(size, CGFloat(cfg.magnifiedSize)) : size
        let frame = windowFrame(cross: DockGeometry.crossLength(iconSize: size, magnifiedSize: magnified))
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        root.frame = NSRect(origin: .zero, size: frame.size)
        dockView.frame = NSRect(origin: isAutoHidden ? hiddenOffset : .zero, size: frame.size)
        dockView.configure(edge: cfg.edge, iconSize: size, magnifiedSize: magnified,
                           showIndicators: cfg.showIndicators, dimHidden: cfg.dimHiddenApps,
                           locked: cfg.locked, scale: screen.backingScaleFactor)
        refreshItems()
        (isFullScreen, yieldsToSystemDock) = readScreenState()
        updateAutoHide()
        if !isAutoHidden { panel.orderFrontRegardless() }
    }

    private func windowFrame(cross: CGFloat) -> NSRect {
        let vf = screen.visibleFrame
        switch config.edge {
        case .bottom: return NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: cross)
        case .top: return NSRect(x: vf.minX, y: vf.maxY - cross, width: vf.width, height: cross)
        case .left: return NSRect(x: vf.minX, y: vf.minY, width: cross, height: vf.height)
        case .right: return NSRect(x: vf.maxX - cross, y: vf.minY, width: cross, height: vf.height)
        }
    }

    /// Picks up a new icon style or appearance (the Trash image differs in Dark).
    func reloadIcons() {
        refreshItems()
        dockView.reloadIcons()
    }

    func refreshItems() {
        guard let monitor = manager?.monitor else { return }
        var apps: [DisplayItem] = []
        var others: [DisplayItem] = []
        var pinnedPIDs = Set<pid_t>()
        for item in config.items {
            let app = monitor.runningApp(for: item)
            if let app { pinnedPIDs.insert(app.processIdentifier) }
            let display = DisplayItem(kind: .pinned, key: "p:\(item.id)", dockItem: item, app: app,
                                      title: Self.displayName(item.name), isRunning: app != nil,
                                      isHidden: app.map { monitor.hiddenPIDs.contains($0.processIdentifier) } ?? false)
            if item.kind == .app { apps.append(display) } else { others.append(display) }
        }

        let running: [NSRunningApplication]
        switch config.runningMode {
        case .none:
            running = []
        case .all:
            running = monitor.apps.filter { !pinnedPIDs.contains($0.processIdentifier) }
        case .thisScreen:
            let onScreen = monitor.pids(onScreen: screen.stableID)
            running = monitor.apps.filter {
                onScreen.contains($0.processIdentifier) && !pinnedPIDs.contains($0.processIdentifier)
            }
        }
        var middle = running.map { app in
            DisplayItem(kind: .running, key: "r:\(app.processIdentifier)", app: app,
                        title: app.localizedName ?? "App", isRunning: true,
                        isHidden: monitor.hiddenPIDs.contains(app.processIdentifier))
        }
        if config.showRecents, let recent = store?.config.recentApps {
            // Like macOS: recently used apps that are neither pinned nor running.
            var taken = Set(config.items.map(\.path))
            monitor.apps.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }.forEach { taken.insert($0) }
            let paths = recent.filter { !taken.contains($0) && FileManager.default.fileExists(atPath: $0) }
            for path in paths.prefix(Self.recentLimit) {
                middle.append(DisplayItem(kind: .recent, key: "rc:\(path)", appURL: URL(fileURLWithPath: path),
                                          title: Self.displayName(FileManager.default.displayName(atPath: path)),
                                          isRunning: false, iconPath: path))
            }
        }
        if config.showTrash {
            let dark = dockView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            others.append(DisplayItem(kind: .trash, key: "trash", title: "Thùng rác", isRunning: false,
                                      iconPath: AppActions.trashIconPath(dark: dark)))
        }

        // Like macOS, running apps follow the pinned ones directly; the recent-apps
        // section gets its own separator.
        var result = apps
        if !middle.isEmpty {
            if !result.isEmpty, config.showRecents { result.append(separator("sep-a")) }
            result += middle
        }
        if !others.isEmpty {
            if !result.isEmpty { result.append(separator("sep-b")) }
            result += others
        }
        dockView.setItems(result)
    }

    /// Dock labels never show the ".app" extension, whatever Finder's setting.
    private static func displayName(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func separator(_ key: String) -> DisplayItem {
        DisplayItem(kind: .separator, key: key, title: "", isRunning: false)
    }

    // MARK: - Auto-hide

    private var hiddenOffset: NSPoint {
        let c = config.edge.isHorizontal ? panel.frame.height : panel.frame.width
        switch config.edge {
        case .bottom: return NSPoint(x: 0, y: -c)
        case .top: return NSPoint(x: 0, y: c)
        case .left: return NSPoint(x: -c, y: 0)
        case .right: return NSPoint(x: c, y: 0)
        }
    }

    private func readScreenState() -> (fullScreen: Bool, yields: Bool) {
        guard let monitor = manager?.monitor else { return (false, false) }
        let id = screen.stableID
        let fullScreen = monitor.fullScreenIDs.contains(id)
        // In full screen the system Dock appears at the pointer's edge on its own.
        let yields = (monitor.systemDockScreenID == id && SystemDock.edge == config.edge)
            || (config.hideInFullScreen && fullScreen && SystemDock.occupies(config.edge, of: screen))
        return (fullScreen, yields)
    }

    /// Re-reads full screen and the system Dock's whereabouts; when either makes
    /// the dock step aside, it goes at once rather than after the usual idle delay.
    func updateScreenState() {
        let state = readScreenState()
        guard state != (isFullScreen, yieldsToSystemDock) else { return }
        (isFullScreen, yieldsToSystemDock) = state
        updateAutoHide()
        // The system Dock arrives under the pointer, so this one leaves even mid-hover.
        if autoHides, !isAutoHidden, !dockView.isHovering || yieldsToSystemDock {
            hideWork?.cancel()
            hide()
        }
    }

    var isYieldingToSystemDock: Bool { yieldsToSystemDock }

    /// Whether `point` is within this dock's reach of its screen edge, where the
    /// system Dock would slide in if it shares the edge.
    func isNearEdge(_ point: NSPoint) -> Bool {
        let f = screen.frame
        guard f.contains(point) else { return false }
        let reach = (config.edge.isHorizontal ? panel.frame.height : panel.frame.width) + 4
        switch config.edge {
        case .bottom: return point.y - f.minY < reach
        case .top: return f.maxY - point.y < reach
        case .left: return point.x - f.minX < reach
        case .right: return f.maxX - point.x < reach
        }
    }

    private func updateAutoHide() {
        guard autoHides else {
            trigger?.orderOut(nil)
            trigger = nil
            if isAutoHidden { reveal() }
            return
        }
        if yieldsToSystemDock {
            trigger?.orderOut(nil)
            trigger = nil
            if !isAutoHidden, !dockView.isHovering { scheduleHide(after: 0.8) }
            return
        }
        if trigger == nil {
            let t = EdgeTriggerWindow()
            t.onEnter = { [weak self] in self?.edgeTouched() }
            trigger = t
        }
        // The trigger sits on the physical edge so the pointer can rest on it.
        let f = screen.frame, vf = screen.visibleFrame, t: CGFloat = 2
        let rect: NSRect
        switch config.edge {
        case .bottom: rect = NSRect(x: vf.minX, y: f.minY, width: vf.width, height: t)
        case .top: rect = NSRect(x: vf.minX, y: vf.maxY - t, width: vf.width, height: t)
        case .left: rect = NSRect(x: f.minX, y: vf.minY, width: t, height: vf.height)
        case .right: rect = NSRect(x: f.maxX - t, y: vf.minY, width: t, height: vf.height)
        }
        trigger?.setFrame(rect, display: false)
        if isAutoHidden {
            trigger?.orderFrontRegardless()
        } else if !dockView.isHovering {
            scheduleHide(after: 0.8)
        }
    }

    private func edgeTouched() {
        revealWork?.cancel()
        guard config.autoHideDelay > 0.01 else { return reveal() }
        // Honour the show delay, but only if the pointer is still at the edge.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let trigger = self.trigger,
                  trigger.frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) else { return }
            self.reveal()
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.autoHideDelay, execute: work)
    }

    func reveal() {
        hideWork?.cancel()
        guard isAutoHidden else { return }
        isAutoHidden = false
        trigger?.orderOut(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.autoHideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dockView.animator().setFrameOrigin(.zero)
        }
        // If the pointer only brushed the edge, tuck the dock away again.
        scheduleHide(after: 1.2)
    }

    private func hide() {
        guard autoHides, !isAutoHidden else { return }
        isAutoHidden = true
        label.hide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = config.autoHideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dockView.animator().setFrameOrigin(hiddenOffset)
        }, completionHandler: { [weak self] in
            guard let self, self.isAutoHidden else { return }
            self.panel.orderOut(nil)
            self.trigger?.orderFrontRegardless()
        })
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        guard autoHides else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dockView.isHovering else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hoverChanged(_ inside: Bool) {
        if inside {
            hideWork?.cancel()
        } else {
            scheduleHide(after: 0.5)
        }
    }

    // MARK: - Actions

    func activate(_ item: DisplayItem, anchor: NSRect?) {
        switch item.kind {
        case .separator:
            return
        case .trash:
            AppActions.openTrash()
        case .running:
            if let app = item.app { AppActions.focus(app, preferring: screen) }
        case .recent:
            if let url = item.appURL { launch(url, key: item.key) }
        case .pinned:
            guard let dockItem = item.dockItem else { return }
            switch dockItem.kind {
            case .app:
                if let app = item.app {
                    AppActions.focus(app, preferring: screen)
                } else {
                    launch(dockItem.url, key: item.key)
                }
            case .folder:
                showFolder(dockItem, item: item, anchor: anchor)
            case .file:
                NSWorkspace.shared.open(dockItem.url)
            }
        }
    }

    private func launch(_ url: URL, key: String) {
        AppActions.launch(url)
        if config.bounceOnLaunch { dockView.startBounce(key: key) }
    }

    private func showFolder(_ dockItem: DockItem, item: DisplayItem, anchor: NSRect?) {
        let sort = dockItem.folderSort ?? .name
        if (dockItem.folderView ?? .grid) == .grid, let anchor {
            label.hide()
            StackPanel.toggle(folder: dockItem.url, sort: sort, anchor: anchor, edge: config.edge)
        } else {
            dockView.showMenu(FolderMenu(folder: dockItem.url, sort: sort), forItem: item)
        }
    }

    func open(_ urls: [URL], with item: DisplayItem) {
        guard let appURL = item.fileURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: cfg)
        if !item.isRunning, config.bounceOnLaunch { dockView.startBounce(key: item.key) }
    }

    func resize(to size: CGFloat) {
        let value = Double(min(max(size, 16), 128).rounded())
        guard value != config.iconSize else { return }
        store?.updateDock(id) { dock in
            dock.iconSize = value
            dock.magnifiedSize = max(dock.magnifiedSize, value)
        }
    }

    /// Edits pinned items keeping apps before folders/files, like the macOS Dock.
    private func updateItems(_ body: (inout [DockItem]) -> Void) {
        guard !config.locked else { return }
        store?.updateDock(id) { dock in
            body(&dock.items)
            dock.normalizeItems()
        }
    }

    /// Inserts `item` into its section (apps or others) at `index` within that section.
    private static func insert(_ item: DockItem, into items: inout [DockItem], at index: Int) {
        items.removeAll { $0.id == item.id || $0.path == item.path }
        let isApp = item.kind == .app
        let sectionPositions = items.indices.filter { (items[$0].kind == .app) == isApp }
        let position: Int
        if index < sectionPositions.count {
            position = sectionPositions[max(index, 0)]
        } else if let last = sectionPositions.last {
            position = last + 1
        } else {
            position = isApp ? 0 : items.count
        }
        items.insert(item, at: position)
    }

    func insert(_ urls: [URL], at index: Int, section: DockSection) {
        updateItems { items in
            var appIndex = section == .apps ? index : Int.max
            var otherIndex = section == .others ? index : Int.max
            for url in urls {
                let item = DockItem.make(url: url)
                if item.kind == .app {
                    Self.insert(item, into: &items, at: appIndex)
                    if appIndex != Int.max { appIndex += 1 }
                } else {
                    Self.insert(item, into: &items, at: otherIndex)
                    if otherIndex != Int.max { otherIndex += 1 }
                }
            }
        }
    }

    private func dockItem(for item: DisplayItem) -> DockItem? {
        if let existing = item.dockItem { return existing }
        return (item.app?.bundleURL ?? item.appURL).map(DockItem.make(url:))
    }

    /// Reorders a pinned item, or pins a running/recent app, at a position in its section.
    func place(_ item: DisplayItem, at index: Int) {
        guard let moved = dockItem(for: item) else { return }
        updateItems { Self.insert(moved, into: &$0, at: index) }
    }

    func remove(_ item: DisplayItem) {
        switch item.kind {
        case .recent:
            guard let path = item.appURL?.path else { return }
            store?.mutate { $0.recentApps.removeAll { $0 == path } }
        case .pinned:
            guard let dockItem = item.dockItem else { return }
            updateItems { $0.removeAll { $0.id == dockItem.id } }
        default:
            return
        }
    }

    func transfer(_ item: DisplayItem, to other: DockController, at index: Int) {
        guard let moved = dockItem(for: item), !other.config.locked else { return }
        let sourceID = id, targetID = other.id, removeFromSource = item.kind == .pinned && !config.locked
        store?.mutate { cfg in
            if removeFromSource, let s = cfg.docks.firstIndex(where: { $0.id == sourceID }) {
                cfg.docks[s].items.removeAll { $0.id == moved.id }
            }
            guard let t = cfg.docks.firstIndex(where: { $0.id == targetID }) else { return }
            Self.insert(moved, into: &cfg.docks[t].items, at: index)
            cfg.docks[t].normalizeItems()
        }
    }

    private func updateFolder(_ item: DockItem, _ body: @escaping (inout DockItem) -> Void) {
        store?.updateDock(id) { dock in
            guard let i = dock.items.firstIndex(where: { $0.id == item.id }) else { return }
            body(&dock.items[i])
        }
    }

    // MARK: - Menus

    func menu(for item: DisplayItem?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let item else {
            addDockSettings(to: menu)
            return menu
        }
        switch item.kind {
        case .separator:
            addDockSettings(to: menu)
        case .trash:
            menu.addItem(ActionMenuItem("Mở") { AppActions.openTrash() })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Dọn sạch Thùng rác") { AppActions.emptyTrash() })
        case .pinned where item.dockItem?.kind == .folder:
            addFolderItems(for: item, to: menu)
        default:
            addAppOrFileItems(for: item, to: menu)
        }
        return menu
    }

    private func addAppOrFileItems(for item: DisplayItem, to menu: NSMenu) {
        if let app = item.app, let entries = SystemDockMenu.entries(for: app), !entries.isEmpty {
            addSystemDockItems(entries, of: app, for: item, to: menu)
            return
        }
        if item.app != nil, !AppActions.isAccessibilityTrusted {
            menu.addItem(ActionMenuItem("Cấp quyền Trợ năng để hiện menu đầy đủ…") {
                AppActions.requestAccessibility()
                // A grant left over from an older build looks enabled but no longer
                // applies; the pane is where it can be removed and added again.
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
            menu.addItem(.separator())
        }
        if let app = item.app {
            let windows = AppActions.windows(pid: app.processIdentifier)
            for window in windows {
                menu.addItem(ActionMenuItem(window.title) { AppActions.raise(window.element, of: app) })
            }
            if !windows.isEmpty { menu.addItem(.separator()) }
        }

        let options = optionsMenu(for: item)
        let optionsItem = NSMenuItem(title: "Tùy chọn", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        menu.addItem(.separator())

        if let app = item.app {
            menu.addItem(ActionMenuItem(app.isHidden ? "Hiện" : "Ẩn") {
                if app.isHidden { app.unhide() } else { app.hide() }
            })
            let quit = ActionMenuItem("Thoát") { app.terminate() }
            let forceQuit = ActionMenuItem("Buộc thoát") { app.forceTerminate() }
            forceQuit.isAlternate = true
            forceQuit.keyEquivalentModifierMask = .option
            menu.addItem(quit)
            menu.addItem(forceQuit)
        } else {
            menu.addItem(ActionMenuItem("Mở") { [weak self] in self?.activate(item, anchor: nil) })
        }
    }

    /// The system Dock's menu for the app, with its Options submenu swapped for
    /// ours, since that one edits the system Dock rather than this one.
    private func addSystemDockItems(_ entries: [SystemDockMenu.Entry], of app: NSRunningApplication,
                                    for item: DisplayItem, to menu: NSMenu) {
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            if entry.hasSubmenu {
                let options = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                options.submenu = optionsMenu(for: item)
                menu.addItem(options)
                continue
            }
            if entry.isHeader {
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: entry.title))
                } else {
                    let header = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                continue
            }
            let title = entry.title
            let menuItem = ActionMenuItem(title, state: entry.mark.isEmpty ? .off : (entry.mark == "✓" ? .on : .mixed)) {
                SystemDockMenu.press(index: index, title: title, of: app)
            }
            if !entry.mark.isEmpty, entry.mark != "✓" {
                // Minimized windows carry a diamond in the Dock's menu.
                menuItem.mixedStateImage = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
            }
            menuItem.isEnabled = entry.enabled
            if entry.isAlternate, let previous = menu.items.last, !previous.isSeparatorItem {
                menuItem.isAlternate = true
                menuItem.keyEquivalentModifierMask = .option
            }
            menu.addItem(menuItem)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    private func optionsMenu(for item: DisplayItem) -> NSMenu {
        let options = NSMenu()
        options.autoenablesItems = false
        if !config.locked {
            if item.kind == .pinned {
                options.addItem(ActionMenuItem(item.isApp ? "Giữ trong Dock" : "Xóa khỏi Dock",
                                               state: item.isApp ? .on : .off) { [weak self] in
                    self?.remove(item)
                })
            } else if item.isApp {
                options.addItem(ActionMenuItem("Giữ trong Dock") { [weak self] in
                    self?.place(item, at: Int.max)
                })
            }
        }
        if let url = item.fileURL {
            options.addItem(ActionMenuItem("Hiển thị trong Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        let others = manager?.controllers.filter { $0 !== self && !$0.config.locked } ?? []
        if !others.isEmpty, item.kind != .trash {
            options.addItem(.separator())
            let sub = NSMenu()
            for other in others {
                sub.addItem(ActionMenuItem(other.config.title) { [weak self, weak other] in
                    guard let self, let other else { return }
                    self.transfer(item, to: other, at: Int.max)
                })
            }
            let moveItem = NSMenuItem(title: item.kind == .pinned ? "Chuyển sang Dock" : "Ghim vào Dock",
                                      action: nil, keyEquivalent: "")
            moveItem.submenu = sub
            options.addItem(moveItem)
        }
        if item.kind == .recent {
            options.addItem(.separator())
            options.addItem(ActionMenuItem("Xóa khỏi mục gần đây") { [weak self] in self?.remove(item) })
        }
        return options
    }

    private func addFolderItems(for item: DisplayItem, to menu: NSMenu) {
        guard let folder = item.dockItem else { return }
        let sort = NSMenu()
        for option in FolderSort.allCases {
            sort.addItem(ActionMenuItem(option.title, state: (folder.folderSort ?? .name) == option ? .on : .off) {
                [weak self] in self?.updateFolder(folder) { $0.folderSort = option }
            })
        }
        let sortItem = NSMenuItem(title: "Sắp xếp theo", action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        menu.addItem(sortItem)

        let view = NSMenu()
        for option in FolderView.allCases {
            view.addItem(ActionMenuItem(option.title, state: (folder.folderView ?? .grid) == option ? .on : .off) {
                [weak self] in self?.updateFolder(folder) { $0.folderView = option }
            })
        }
        let viewItem = NSMenuItem(title: "Xem nội dung dưới dạng", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        menu.addItem(viewItem)
        menu.addItem(.separator())

        let optionsItem = NSMenuItem(title: "Tùy chọn", action: nil, keyEquivalent: "")
        optionsItem.submenu = optionsMenu(for: item)
        menu.addItem(optionsItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Mở “\(folder.name)”") { NSWorkspace.shared.open(folder.url) })
    }

    private func addDockSettings(to menu: NSMenu) {
        menu.addItem(ActionMenuItem(config.autoHide ? "Tắt ẩn" : "Bật ẩn") { [weak self] in
            guard let self else { return }
            self.store?.updateDock(self.id) { $0.autoHide.toggle() }
        })
        menu.addItem(ActionMenuItem("Ẩn khi toàn màn hình", state: config.hideInFullScreen ? .on : .off) {
            [weak self] in
            guard let self else { return }
            self.store?.updateDock(self.id) { $0.hideInFullScreen.toggle() }
        })
        menu.addItem(ActionMenuItem(config.magnification ? "Tắt phóng to" : "Bật phóng to") { [weak self] in
            guard let self else { return }
            self.store?.updateDock(self.id) { $0.magnification.toggle() }
        })
        menu.addItem(.separator())

        let edges = NSMenu()
        for edge in DockEdge.allCases {
            edges.addItem(ActionMenuItem(edge.title, state: config.edge == edge ? .on : .off) { [weak self] in
                guard let self else { return }
                self.store?.updateDock(self.id) { $0.edge = edge }
            })
        }
        let edgeItem = NSMenuItem(title: "Vị trí trên màn hình", action: nil, keyEquivalent: "")
        edgeItem.submenu = edges
        menu.addItem(edgeItem)

        if NSScreen.screens.count > 1 {
            let screens = NSMenu()
            for s in NSScreen.screens {
                let sid = s.stableID, name = s.localizedName
                screens.addItem(ActionMenuItem(name, state: sid == screen.stableID ? .on : .off) { [weak self] in
                    guard let self else { return }
                    self.store?.updateDock(self.id) { $0.screenID = sid; $0.screenName = name }
                })
            }
            let screenItem = NSMenuItem(title: "Màn hình", action: nil, keyEquivalent: "")
            screenItem.submenu = screens
            menu.addItem(screenItem)
        }

        menu.addItem(ActionMenuItem("Khóa nội dung Dock", state: config.locked ? .on : .off) { [weak self] in
            guard let self else { return }
            self.store?.updateDock(self.id) { $0.locked.toggle() }
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Cài đặt Dock…") { [weak self] in self?.manager?.openSettings?() })
    }
}
