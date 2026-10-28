import AppKit
import ApplicationServices

/// The strip a dock keeps free along its edge, like the space the system Dock
/// takes out of `NSScreen.visibleFrame`.
struct ReservedArea {
    var rect: NSRect
    var edge: DockEdge

    /// `frame` cut back to stop at the strip, or nil when it does not reach into
    /// it. A window lying wholly inside the strip is left alone.
    func clamp(_ frame: NSRect) -> NSRect? {
        guard frame.intersects(rect) else { return nil }
        var r = frame
        switch edge {
        case .bottom:
            guard frame.maxY > rect.maxY else { return nil }
            r.origin.y = rect.maxY
            r.size.height = frame.maxY - rect.maxY
        case .top:
            guard frame.minY < rect.minY else { return nil }
            r.size.height = rect.minY - frame.minY
        case .left:
            guard frame.maxX > rect.maxX else { return nil }
            r.origin.x = rect.maxX
            r.size.width = frame.maxX - rect.maxX
        case .right:
            guard frame.minX < rect.minX else { return nil }
            r.size.width = rect.minX - frame.minX
        }
        return r
    }
}

/// Only the system Dock can reserve screen space, so apps zoom and tile their
/// windows right over a MultiDock. With Accessibility access this watches window
/// resizes and trims any window that grows into a dock's strip, the way windows
/// stop at the system Dock. Moving a window is left alone: macOS also lets you
/// drag one under the Dock.
final class WindowAvoider {
    /// Strips of the docks currently showing; read on every check.
    var reservedAreas: () -> [ReservedArea] = { [] }

    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [AXUIElement] = []
    private var checkWork: DispatchWorkItem?

    private static let notifications = [kAXWindowCreatedNotification, kAXWindowResizedNotification]

    deinit { observers.keys.forEach(stopObserving) }

    /// Watches exactly `pids` while `enabled` and trusted. Cheap to call often;
    /// apps that were not ready for an observer last time are retried.
    func sync(enabled: Bool, pids: [pid_t]) {
        let wanted = enabled && AppActions.isAccessibilityTrusted ? Set(pids) : []
        for pid in observers.keys where !wanted.contains(pid) { stopObserving(pid) }
        for pid in wanted where observers[pid] == nil { startObserving(pid) }
    }

    private func startObserving(_ pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowAvoiderCallback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registered on the app, these arrive for each of its windows.
        let added = Self.notifications.filter {
            AXObserverAddNotification(observer, app, $0 as CFString, refcon) == .success
        }
        // A just-launched app may not answer yet; the next sync tries again.
        guard !added.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func windowChanged(_ window: AXUIElement) {
        if !pending.contains(where: { CFEqual($0, window) }) { pending.append(window) }
        scheduleCheck(after: 0)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runChecks() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runChecks() {
        // Trimming mid-drag would fight the pointer; wait for the button to come up.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return scheduleCheck(after: 0.1) }
        let windows = pending
        pending = []
        guard !windows.isEmpty else { return }
        windows.forEach(trim)
        // A zoom animation can still be growing the window after the first notice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            windows.forEach { self?.trim($0) }
        }
    }

    private func trim(_ window: AXUIElement) {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == (kAXStandardWindowSubrole as String),
              !AppActions.boolAttribute(window, "AXFullScreen"),
              let frame = AppActions.frame(of: window) else { return }
        var target = frame
        for area in reservedAreas() {
            if let clamped = area.clamp(target) { target = clamped }
        }
        guard target != frame, target.width >= 60, target.height >= 60 else { return }
        let cg = NSScreen.cgRect(fromCocoa: target)
        // Shrink first so moving never pushes the far edge past where it was.
        var size = cg.size
        var origin = cg.origin
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}

private func windowAvoiderCallback(_: AXObserver, element: AXUIElement, _: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowAvoider>.fromOpaque(refcon).takeUnretainedValue().windowChanged(element)
}

