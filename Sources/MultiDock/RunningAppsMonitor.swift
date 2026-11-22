import AppKit

/// Tracks running GUI apps, which displays they have visible windows on, and
/// which display hosts the system Dock. Driven by NSWorkspace notifications; the
/// window scan only runs (on a tolerant timer) while some dock needs it.
final class RunningAppsMonitor {
    private(set) var apps: [NSRunningApplication] = []
    private(set) var hiddenPIDs: Set<pid_t> = []
    private var pidsByScreen: [String: Set<pid_t>] = [:]
    /// Each display's full-screen spaces and the space it shows.
    private(set) var spaces: [String: DisplaySpaces] = [:]
    /// The display the system Dock is showing on, if it is showing. It moves to
    /// whichever display the pointer lingers at the bottom of.
    private(set) var systemDockScreenID: String?
    /// Notification badges from the system Dock, keyed by bundle path (needs Accessibility).
    private(set) var badges: [String: String] = [:]

    var onChange: (() -> Void)?
    /// Called with an app's bundle URL when it launches or quits (feeds "recent apps").
    var onAppUsed: ((URL) -> Void)?

    var needsWindowTracking = false {
        didSet {
            guard needsWindowTracking != oldValue else { return }
            updateTimer()
            scheduleRefresh()
        }
    }

    private var timer: Timer?
    private var refreshWork: DispatchWorkItem?
    private var lastBadgeRead = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if note.name == NSWorkspace.didLaunchApplicationNotification
                    || note.name == NSWorkspace.didTerminateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.activationPolicy == .regular, app.processIdentifier != self.selfPID,
                   let url = app.bundleURL {
                    self.onAppUsed?(url)
                }
                // A dock can still land on a brand-new full-screen space, so the
                // switch is acted on without waiting.
                if note.name == NSWorkspace.activeSpaceDidChangeNotification { self.refresh() }
                self.scheduleRefresh()
                // New apps usually open their first window a moment after launching,
                // and entering or leaving full screen finishes its animation later.
                if note.name == NSWorkspace.didLaunchApplicationNotification
                    || note.name == NSWorkspace.activeSpaceDidChangeNotification {
                    self.scheduleRefresh(after: 0.8)
                }
            })
        }
        refresh()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        timer?.invalidate()
    }

    func pids(onScreen screenID: String) -> Set<pid_t> {
        pidsByScreen[screenID] ?? []
    }

    func badge(for item: DisplayItem) -> String? {
        guard item.isApp, let url = item.fileURL else { return nil }
        return badges[SystemDockMenu.bundlePath(url)]
    }

    func runningApp(for item: DockItem) -> NSRunningApplication? {
        guard item.kind == .app else { return nil }
        return apps.first { app in
            if let bid = item.bundleID, let other = app.bundleIdentifier { return bid == other }
            return app.bundleURL?.standardizedFileURL.path == item.path
        }
    }

    func scheduleRefresh(after delay: TimeInterval = 0.05) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refresh() {
        let newApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != selfPID
        }
        let scan = needsWindowTracking ? scanWindows() : (pidsByScreen: [:], systemDock: nil)
        let newHidden = Set(newApps.filter(\.isHidden).map(\.processIdentifier))
        let newSpaces = NSScreen.spaces
        let newBadges = needsWindowTracking ? currentBadges() : [:]
        let changed = newApps.map(\.processIdentifier) != apps.map(\.processIdentifier)
            || scan.pidsByScreen != pidsByScreen || newHidden != hiddenPIDs || newSpaces != spaces
            || scan.systemDock != systemDockScreenID || newBadges != badges
        apps = newApps
        badges = newBadges
        pidsByScreen = scan.pidsByScreen
        systemDockScreenID = scan.systemDock
        hiddenPIDs = newHidden
        spaces = newSpaces
        if changed { onChange?() }
    }

    /// Badges change at most every second or so, while refresh can run ten times
    /// a second near the system Dock, so the Dock is asked at most once a second.
    private func currentBadges() -> [String: String] {
        guard Date().timeIntervalSince(lastBadgeRead) >= 1 else { return badges }
        lastBadgeRead = Date()
        return SystemDockMenu.badges()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard needsWindowTracking else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scanWindows() -> (pidsByScreen: [String: Set<pid_t>], systemDock: String?) {
        let screens = NSScreen.screens.map { ($0.stableID, $0.frame) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return ([:], nil) }
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var map: [String: Set<pid_t>] = [:]
        var systemDock: String?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            // The system Dock draws in one window spanning its display, present only while it shows.
            if pid == dockPID, layer == dockLevel,
               let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                systemDock = Self.screenID(for: NSScreen.cocoaRect(fromCG: bounds), in: screens)
                continue
            }
            guard layer == 0,
                  pid != selfPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 60, bounds.height >= 60
            else { continue }
            if let id = Self.screenID(for: NSScreen.cocoaRect(fromCG: bounds), in: screens) {
                map[id, default: []].insert(pid)
            }
        }
        return (map, systemDock)
    }

    /// The display holding most of `rect`.
    private static func screenID(for rect: CGRect, in screens: [(String, CGRect)]) -> String? {
        var best: (id: String, area: CGFloat)?
        for (id, frame) in screens {
            let inter = rect.intersection(frame)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > (best?.area ?? 0) { best = (id, area) }
        }
        return best?.id
    }
}
