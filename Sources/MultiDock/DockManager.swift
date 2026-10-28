import AppKit
import Combine

/// Keeps one DockController per configured dock whose display is connected.
final class DockManager {
    let store: ConfigStore
    let monitor: RunningAppsMonitor
    var openSettings: (() -> Void)?

    private var byID: [UUID: DockController] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var appearanceObservers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var iconReloadPending = false
    private var pointerMonitors: [Any] = []
    private var quickWatch: Timer?
    private var quickWatchUntil = Date.distantPast
    /// Cached for pointer moves; changing it restarts the system Dock, which
    /// changes screen parameters and so passes through reconcile.
    private var systemDockEdge = SystemDock.edge

    var controllers: [DockController] {
        store.config.docks.compactMap { byID[$0.id] }
    }

    init(store: ConfigStore, monitor: RunningAppsMonitor) {
        self.store = store
        self.monitor = monitor

        // @Published delivers the new value before the property is updated, so
        // reconcile works from the value it is handed.
        store.$config
            .sink { [weak self] cfg in self?.reconcile(cfg) }
            .store(in: &cancellables)

        monitor.onChange = { [weak self] in
            self?.byID.values.forEach {
                $0.updateScreenState()
                $0.refreshItems()
            }
        }
        monitor.onAppUsed = { [weak self] url in
            let path = url.resolvingSymlinksInPath().path
            self?.store.mutate { cfg in
                cfg.recentApps.removeAll { $0 == path }
                cfg.recentApps.insert(path, at: 0)
                cfg.recentApps = Array(cfg.recentApps.prefix(10))
            }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.pointerMoved()
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { pointerMonitors.append(local) }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            IconCache.shared.invalidate()
            self.reconcile(self.store.config)
            self.monitor.scheduleRefresh()
        }

        // System Settings › Appearance: icon style (Default/Dark/Clear/Tinted), its
        // tint and folder color, and Light/Dark when icons follow the appearance.
        // AppKit re-posts the window server's change under this (unpublished) name.
        let iconStyleChanged = Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification")
        for center in [NotificationCenter.default, NSWorkspace.shared.notificationCenter] {
            appearanceObservers.append(center.addObserver(forName: iconStyleChanged, object: nil, queue: .main) {
                [weak self] _ in self?.scheduleIconReload()
            })
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleIconReload() }
        }
        // Fallback in case that name changes: the stored preference itself. The
        // delay leaves AppKit time to apply the new style before icons re-render.
        iconStyleSignature = Self.currentIconStyleSignature()
        appearanceObservers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let signature = Self.currentIconStyleSignature()
            guard signature != self.iconStyleSignature else { return }
            self.iconStyleSignature = signature
            self.scheduleIconReload(after: 0.6)
        })
    }

    private var iconStyleSignature = ""

    /// The system Dock slides in a moment after the pointer rests at its edge and
    /// leaves soon after the pointer does. The regular scan is too slow to keep up,
    /// so while the pointer is near a dock it could cover (or while a dock is
    /// standing aside for it) look for it several times a second.
    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        guard byID.values.contains(where: {
            $0.isYieldingToSystemDock || ($0.config.edge == systemDockEdge && $0.isNearEdge(point))
        }) else { return }
        quickWatchUntil = Date().addingTimeInterval(1.5)
        guard quickWatch == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self, Date() < self.quickWatchUntil else {
                timer.invalidate()
                self?.quickWatch = nil
                return
            }
            self.monitor.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        quickWatch = t
    }

    private static func currentIconStyleSignature() -> String {
        ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor", "AppleIconAppearanceCustomTintColor"]
            .map { String(describing: UserDefaults.standard.object(forKey: $0) ?? "") }
            .joined(separator: "|")
    }

    /// Coalesces bursts of appearance notifications into one re-render.
    private func scheduleIconReload(after delay: TimeInterval = 0.15) {
        guard !iconReloadPending else { return }
        iconReloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.iconReloadPending = false
            IconCache.shared.invalidate()
            self.byID.values.forEach { $0.reloadIcons() }
        }
    }

    private func reconcile(_ cfg: AppConfig) {
        systemDockEdge = SystemDock.edge
        let screens = Dictionary(NSScreen.screens.map { ($0.stableID, $0) }, uniquingKeysWith: { a, _ in a })
        var alive = Set<UUID>()
        for dock in cfg.docks {
            guard let screen = screens[dock.screenID] else { continue }
            alive.insert(dock.id)
            if let existing = byID[dock.id] {
                existing.apply(dock, screen: screen)
            } else {
                byID[dock.id] = DockController(config: dock, screen: screen, manager: self)
            }
        }
        for (id, controller) in byID where !alive.contains(id) {
            controller.close()
            byID[id] = nil
        }
        // Also tells each dock where the system Dock is, so every dock needs the scan.
        monitor.needsWindowTracking = !cfg.docks.isEmpty
    }

    /// The dock whose plate is under `point` (screen coordinates), if any.
    func controller(at point: NSPoint) -> DockController? {
        byID.values.first { controller in
            let margin = controller.dockView.geometry.iconSize * 0.6
            return controller.dockView.dropRegion(margin: margin)?.contains(point) ?? false
        }
    }
}
