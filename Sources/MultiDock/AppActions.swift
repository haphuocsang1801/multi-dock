import AppKit
import ApplicationServices

enum AppActions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func launch(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    /// Brings an app forward the way the system Dock does (re-open creates a
    /// window if it has none). With Accessibility access, the app's window on
    /// `screen` is raised on top, so each dock switches to "its" window.
    static func focus(_ app: NSRunningApplication, preferring screen: NSScreen?) {
        let pid = app.processIdentifier
        let canRaise = screen != nil && isAccessibilityTrusted
        if canRaise, let screen { raiseWindow(pid: pid, on: screen) }

        guard let url = app.bundleURL else {
            app.activate(options: [])
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            guard canRaise, let screen else { return }
            DispatchQueue.main.async { raiseWindow(pid: pid, on: screen) }
        }
    }

    @discardableResult
    static func raiseWindow(pid: pid_t, on screen: NSScreen) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        // AX lists windows front to back, so the first match is the most recent one.
        for window in windows {
            guard let frame = frame(of: window) else { continue }
            let inter = frame.intersection(screen.frame)
            guard !inter.isNull, inter.width * inter.height >= frame.width * frame.height * 0.4 else { continue }
            if boolAttribute(window, kAXMinimizedAttribute) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return true
        }
        return false
    }

    /// Titled standard windows of an app, front to back (needs Accessibility).
    static func windows(pid: pid_t) -> [(title: String, element: AXUIElement)] {
        guard isAccessibilityTrusted else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) == (kAXStandardWindowSubrole as String),
                  let text = title as? String, !text.isEmpty else { return nil }
            return (text, window)
        }
    }

    static func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        if boolAttribute(window, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.main.async { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            }
        }
    }

    // MARK: - Trash

    static let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    /// Reading ~/.Trash can be denied without Full Disk Access; then it shows as empty.
    static var isTrashFull: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashURL.path) else { return false }
        return names.contains { $0 != ".DS_Store" && $0 != ".localized" }
    }

    /// The Dock's own glass bin (dark and light variants), falling back to the Finder icon.
    static func trashIconPath(dark: Bool) -> String {
        let full = isTrashFull
        let dock = "/System/Library/CoreServices/Dock.app/Contents/Resources/"
            + (full ? "s-trashfull" : "s-trashempty") + (dark ? "2" : "") + "@2x.png"
        if FileManager.default.fileExists(atPath: dock) { return dock }
        return "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
            + (full ? "FullTrashIcon.icns" : "TrashIcon.icns")
    }

    static func openTrash() {
        runFinderScript("tell application \"Finder\" to open trash\ntell application \"Finder\" to activate")
    }

    static func moveToTrash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls)
    }

    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Bạn có chắc muốn xóa vĩnh viễn các mục trong Thùng rác?"
        alert.informativeText = "Bạn không thể hoàn tác thao tác này."
        alert.addButton(withTitle: "Dọn sạch Thùng rác")
        alert.addButton(withTitle: "Hủy")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runFinderScript("tell application \"Finder\" to empty trash")
    }

    private static func runFinderScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("MultiDock: Finder script failed: \(error)") }
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return NSScreen.cocoaRect(fromCG: CGRect(origin: origin, size: size))
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

/// Stack-style folder browser: lists a folder's contents, sub-folders open
/// lazily as sub-menus.
final class FolderMenu: NSMenu, NSMenuDelegate {
    private let folder: URL
    private let sort: FolderSort
    private var loaded = false
    private static let limit = 200

    init(folder: URL, sort: FolderSort = .name) {
        self.folder = folder
        self.sort = sort
        super.init(title: folder.lastPathComponent)
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !loaded else { return }
        loaded = true
        removeAllItems()

        let folder = self.folder
        addItem(ActionMenuItem("Mở trong Finder") { NSWorkspace.shared.open(folder) })
        addItem(.separator())

        let sorted = FolderContents.load(folder, sort: sort)
        if sorted.isEmpty {
            let empty = NSMenuItem(title: "Thư mục trống", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
        for url in sorted.prefix(Self.limit) {
            let isFolder = FolderContents.isBrowsableFolder(url)
            let item = ActionMenuItem(FileManager.default.displayName(atPath: url.path)) {
                NSWorkspace.shared.open(url)
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if isFolder { item.submenu = FolderMenu(folder: url, sort: sort) }
            addItem(item)
        }
        if sorted.count > Self.limit {
            let more = NSMenuItem(title: "… và \(sorted.count - Self.limit) mục khác", action: nil, keyEquivalent: "")
            more.isEnabled = false
            addItem(more)
        }
    }
}
