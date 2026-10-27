import Foundation

/// Reads the system Dock's preferences so a MultiDock can start as a copy of it.
enum SystemDock {
    private static let domain = "com.apple.dock" as CFString

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    /// Finder, the pinned apps, then pinned folders/files, in Dock order.
    static func items() -> [DockItem] {
        let tiles = ((value("persistent-apps") as? [[String: Any]]) ?? [])
            + ((value("persistent-others") as? [[String: Any]]) ?? [])
        let pinned: [DockItem] = tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return nil }
            let url = URL(string: string) ?? URL(fileURLWithPath: string)
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return DockItem.make(url: url)
        }
        // Finder is always first in the macOS Dock but is not stored in its preferences.
        return pinned.contains { $0.bundleID == "com.apple.finder" } ? pinned : [DockItem.make(url: finder)] + pinned
    }

    /// Copies size, magnification, auto-hide and the pinned items into `dock`.
    static func apply(to dock: inout DockConfig) {
        if let size = value("tilesize") as? Double { dock.iconSize = min(max(size, 16), 128) }
        if let on = value("magnification") as? Bool { dock.magnification = on }
        if let large = value("largesize") as? Double { dock.magnifiedSize = max(dock.iconSize, min(large, 128)) }
        dock.showRecents = value("show-recents") as? Bool ?? false
        if let dim = value("showhidden") as? Bool { dock.dimHiddenApps = dim }
        if let launch = value("launchanim") as? Bool { dock.bounceOnLaunch = launch }
        if let indicators = value("show-process-indicators") as? Bool { dock.showIndicators = indicators }
        let imported = items()
        if !imported.isEmpty { dock.items = imported }
        dock.normalizeItems()
    }
}
