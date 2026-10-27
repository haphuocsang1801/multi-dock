import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore.shared
    private var monitor: RunningAppsMonitor!
    private var manager: DockManager!
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        if store.isFirstRun { store.config.docks = Self.defaultDocks() }
        monitor = RunningAppsMonitor()
        manager = DockManager(store: store, monitor: monitor)
        manager.openSettings = { [weak self] in self?.showSettings() }
        setUpStatusItem()
        if store.isFirstRun { store.saveNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// One dock per secondary display (the primary keeps the system Dock),
    /// starting as a copy of the system Dock.
    private static func defaultDocks() -> [DockConfig] {
        let screens = NSScreen.screens
        let secondary = screens.dropFirst()
        var docks: [DockConfig]
        if secondary.isEmpty, let main = screens.first {
            docks = [DockConfig(screenID: main.stableID, screenName: main.localizedName, edge: .left)]
        } else {
            docks = secondary.map { DockConfig(screenID: $0.stableID, screenName: $0.localizedName) }
        }
        for i in docks.indices { SystemDock.apply(to: &docks[i]) }
        return docks
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MultiDock")
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Cài đặt…") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Thoát MultiDock") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }

    private func showSettings() {
        if settings == nil { settings = SettingsWindowController(store: store) }
        settings?.present()
    }
}
