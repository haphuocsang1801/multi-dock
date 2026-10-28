import Foundation

enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right, top

    var id: String { rawValue }
    var isHorizontal: Bool { self == .bottom || self == .top }

    var title: String {
        switch self {
        case .bottom: return "Dưới"
        case .left: return "Trái"
        case .right: return "Phải"
        case .top: return "Trên"
        }
    }
}

enum RunningAppsMode: String, Codable, CaseIterable, Identifiable {
    /// Only pinned items.
    case none
    /// Pinned items plus running apps that have a visible window on this display.
    case thisScreen
    /// Pinned items plus every running app.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Chỉ mục đã ghim"
        case .thisScreen: return "Thêm app có cửa sổ trên màn hình này"
        case .all: return "Thêm tất cả app đang chạy"
        }
    }
}

enum DockItemKind: String, Codable {
    case app, folder, file
}

enum FolderView: String, Codable, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? "Lưới" : "Danh sách" }
}

enum FolderSort: String, Codable, CaseIterable, Identifiable {
    case name, dateAdded, dateModified, kind
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Tên"
        case .dateAdded: return "Ngày thêm"
        case .dateModified: return "Ngày sửa đổi"
        case .kind: return "Loại"
        }
    }
}

struct DockItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: DockItemKind
    var path: String
    var bundleID: String?
    var name: String
    var folderView: FolderView?
    var folderSort: FolderSort?

    var url: URL { URL(fileURLWithPath: path) }

    static func make(url: URL) -> DockItem {
        // /Applications/Safari.app and friends are symlinks; pin the real bundle.
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let kind: DockItemKind
        if url.pathExtension.lowercased() == "app" {
            kind = .app
        } else if isDir.boolValue {
            kind = .folder
        } else {
            kind = .file
        }
        return DockItem(
            id: UUID(),
            kind: kind,
            path: url.path,
            bundleID: kind == .app ? Bundle(url: url)?.bundleIdentifier : nil,
            name: {
                let name = FileManager.default.displayName(atPath: url.path)
                return kind == .app && name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            }()
        )
    }
}

struct DockConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var screenID: String
    var screenName: String
    var edge: DockEdge = .bottom
    var iconSize: Double = 64
    var magnification = false
    var magnifiedSize: Double = 96
    var autoHide = false
    var autoHideDelay: Double = 0
    var autoHideDuration: Double = 0.25
    /// Tucks the dock away, like auto-hide, while its display shows a full-screen app.
    var hideInFullScreen = true
    /// Trims windows that zoom or tile over the dock (needs Accessibility).
    var reserveSpace = true
    var showIndicators = true
    var runningMode: RunningAppsMode = .thisScreen
    var showRecents = false
    var showTrash = true
    var bounceOnLaunch = true
    var dimHiddenApps = false
    var locked = false
    var style = DockStyle()
    var items: [DockItem] = []

    init(screenID: String, screenName: String, edge: DockEdge = .bottom) {
        self.screenID = screenID
        self.screenName = screenName
        self.edge = edge
    }

    // Tolerates configs written by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        id = try value(.id, UUID())
        screenID = try c.decode(String.self, forKey: .screenID)
        screenName = try value(.screenName, "")
        edge = try value(.edge, .bottom)
        iconSize = try value(.iconSize, 64)
        magnification = try value(.magnification, false)
        magnifiedSize = try value(.magnifiedSize, 96)
        autoHide = try value(.autoHide, false)
        autoHideDelay = try value(.autoHideDelay, 0)
        autoHideDuration = try value(.autoHideDuration, 0.25)
        hideInFullScreen = try value(.hideInFullScreen, true)
        reserveSpace = try value(.reserveSpace, true)
        showIndicators = try value(.showIndicators, true)
        runningMode = try value(.runningMode, .thisScreen)
        showRecents = try value(.showRecents, false)
        showTrash = try value(.showTrash, true)
        bounceOnLaunch = try value(.bounceOnLaunch, true)
        dimHiddenApps = try value(.dimHiddenApps, false)
        locked = try value(.locked, false)
        style = try value(.style, DockStyle())
        items = try value(.items, [])
    }

    var title: String { "\(screenName) · \(edge.title)" }

    /// Keeps the macOS Dock order: apps first, then folders and files.
    mutating func normalizeItems() {
        items = items.filter { $0.kind == .app } + items.filter { $0.kind != .app }
    }
}

struct AppConfig: Codable, Equatable {
    var docks: [DockConfig] = []
    /// Bundle paths of recently used apps, newest first.
    var recentApps: [String] = []
    /// Image paths the user chose, keyed by the app bundle, folder or file they replace.
    var customIcons: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docks = try c.decodeIfPresent([DockConfig].self, forKey: .docks) ?? []
        recentApps = try c.decodeIfPresent([String].self, forKey: .recentApps) ?? []
        customIcons = try c.decodeIfPresent([String: String].self, forKey: .customIcons) ?? [:]
    }
}
