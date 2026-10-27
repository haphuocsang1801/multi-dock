import AppKit

/// The menu the system Dock shows for a running app: its windows, the app's own
/// commands (applicationDockMenu, e.g. Chrome profiles), Show All Windows, Hide,
/// Quit. Apps hand that menu only to the Dock, so it is read from the Dock's
/// accessibility tree and its commands are replayed there. The system Dock's
/// menu is open for about a tenth of a second while this happens.
enum SystemDockMenu {
    struct Entry {
        let title: String
        let enabled: Bool
        let mark: String
        let isSeparator: Bool
        /// Section titles such as Chrome's "Profiles" carry no action.
        let isHeader: Bool
        /// Shown in place of the previous entry while ⌥ is held (Hide Others, Force Quit).
        let isAlternate: Bool
        /// Only the Dock's own "Options" entry has a submenu.
        let hasSubmenu: Bool
    }

    /// kAXMenuItemModifierOption from HIServices/AXRoleConstants.h.
    private static let optionModifier = 1 << 1

    private static let menuAttributes = [
        kAXTitleAttribute, kAXEnabledAttribute, "AXMenuItemMarkChar", "AXMenuItemCmdModifiers",
        kAXIdentifierAttribute, kAXChildrenAttribute,
    ] as CFArray

    static func entries(for app: NSRunningApplication) -> [Entry]? {
        withOpenMenu(for: app) { items in
            items.map { item in
                var values: CFArray?
                AXUIElementCopyMultipleAttributeValues(item, menuAttributes, [], &values)
                let v = (values as? [Any]) ?? []
                func value<T>(_ i: Int) -> T? { i < v.count ? v[i] as? T : nil }
                let title: String = value(0) ?? ""
                let enabled: Bool = value(1) ?? false
                let modifiers: Int = value(3) ?? 0
                let identifier: String? = value(4)
                let children: [AXUIElement] = value(5) ?? []
                return Entry(title: title, enabled: enabled, mark: value(2) ?? "",
                             isSeparator: title.isEmpty && !enabled,
                             isHeader: !title.isEmpty && identifier == nil && children.isEmpty,
                             isAlternate: modifiers & Self.optionModifier != 0,
                             hasSubmenu: !children.isEmpty)
            }
        }
    }

    /// Runs the entry at `index` through the system Dock, if the menu still matches.
    static func press(index: Int, title: String, of app: NSRunningApplication) {
        _ = withOpenMenu(for: app, cancel: false) { items -> Bool in
            guard index < items.count,
                  copyString(items[index], kAXTitleAttribute) == title else {
                if let menu = items.first.flatMap(parent) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
                return false
            }
            AXUIElementPerformAction(items[index], kAXPressAction as CFString)
            return true
        }
    }

    // MARK: - Accessibility

    private static func withOpenMenu<T>(for app: NSRunningApplication, cancel: Bool = true,
                                        _ body: ([AXUIElement]) -> T) -> T? {
        guard AXIsProcessTrusted(), let tile = dockTile(for: app) else { return nil }
        guard AXUIElementPerformAction(tile, "AXShowMenu" as CFString) == .success else { return nil }
        var menu: AXUIElement?
        for _ in 0..<60 {
            if let first = copyChildren(tile).first { menu = first; break }
            usleep(5_000)
        }
        guard let menu else { return nil }
        let result = body(copyChildren(menu))
        if cancel { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        return result
    }

    private static func dockTile(for app: NSRunningApplication) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let list = copyChildren(root).first else { return nil }
        let bundle = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
        let tiles = copyChildren(list)
        if let bundle, let tile = tiles.first(where: { tile in
            var url: CFTypeRef?
            AXUIElementCopyAttributeValue(tile, kAXURLAttribute as CFString, &url)
            return (url as? URL)?.resolvingSymlinksInPath().standardizedFileURL == bundle
        }) {
            return tile
        }
        return tiles.first { copyString($0, kAXTitleAttribute) == app.localizedName }
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func copyString(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value as? String
    }

    private static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
