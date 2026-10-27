import AppKit

/// Tracks running GUI apps and which displays they have visible windows on.
/// Driven by NSWorkspace notifications; the window scan only runs (on a slow,
/// tolerant timer) while some dock needs per-display information.
final class RunningAppsMonitor {
    private(set) var apps: [NSRunningApplication] = []
    private(set) var hiddenPIDs: Set<pid_t> = []
    private var pidsByScreen: [String: Set<pid_t>] = [:]

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
                self.scheduleRefresh()
                // New apps usually open their first window a moment after launching.
                if note.name == NSWorkspace.didLaunchApplicationNotification {
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
        let newMap = needsWindowTracking ? scanWindows() : [:]
        let newHidden = Set(newApps.filter(\.isHidden).map(\.processIdentifier))
        let changed = newApps.map(\.processIdentifier) != apps.map(\.processIdentifier)
            || newMap != pidsByScreen || newHidden != hiddenPIDs
        apps = newApps
        pidsByScreen = newMap
        hiddenPIDs = newHidden
        if changed { onChange?() }
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

    private func scanWindows() -> [String: Set<pid_t>] {
        let screens = NSScreen.screens.map { ($0.stableID, $0.frame) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var map: [String: Set<pid_t>] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != selfPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 60, bounds.height >= 60
            else { continue }
            let rect = NSScreen.cocoaRect(fromCG: bounds)
            var best: (id: String, area: CGFloat)?
            for (id, frame) in screens {
                let inter = rect.intersection(frame)
                guard !inter.isNull else { continue }
                let area = inter.width * inter.height
                if area > (best?.area ?? 0) { best = (id, area) }
            }
            if let best { map[best.id, default: []].insert(pid) }
        }
        return map
    }
}
