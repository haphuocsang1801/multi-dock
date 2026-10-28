import AppKit

/// A color stored in sRGB so configs read the same on every display.
struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum DockBackground: String, Codable, CaseIterable, Identifiable {
    /// Liquid Glass on macOS 26, the blurred HUD material before it.
    case glass
    case solid
    /// No plate at all: the icons float over the desktop.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "Kính"
        case .solid: return "Màu đặc"
        case .none: return "Trong suốt"
        }
    }
}

enum DockTheme: String, Codable, CaseIterable, Identifiable {
    case system, classic, graphite, ocean, sunset, forest, neonPink, neonCyan, neonLime, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Hệ thống"
        case .classic: return "macOS cổ điển"
        case .graphite: return "Than chì"
        case .ocean: return "Đại dương"
        case .sunset: return "Hoàng hôn"
        case .forest: return "Rừng"
        case .neonPink: return "Neon hồng"
        case .neonCyan: return "Neon xanh"
        case .neonLime: return "Neon chanh"
        case .custom: return "Tùy chỉnh"
        }
    }

    /// The style this theme starts from; nil for the themes that keep the current colors.
    var preset: DockStyle? {
        var s = DockStyle()
        s.theme = self
        switch self {
        case .system, .custom:
            return self == .system ? s : nil
        case .classic:
            s.background = .solid
            s.backgroundColor = RGBAColor(hex: 0xE6E6E8)
            s.backgroundOpacity = 0.78
            s.borderColor = RGBAColor(hex: 0xFFFFFF, alpha: 0.7)
            s.indicatorColor = RGBAColor(hex: 0x1C1C1E)
        case .graphite:
            s.background = .solid
            s.backgroundColor = RGBAColor(hex: 0x232326)
            s.backgroundOpacity = 0.88
            s.borderColor = RGBAColor(hex: 0xFFFFFF, alpha: 0.14)
            s.indicatorColor = RGBAColor(hex: 0xF2F2F7)
        case .ocean:
            s.backgroundColor = RGBAColor(hex: 0x0E4A73)
            s.backgroundOpacity = 0.7
            s.borderColor = RGBAColor(hex: 0x6CCFF6, alpha: 0.6)
            s.indicatorColor = RGBAColor(hex: 0x8FE3FF)
        case .sunset:
            s.background = .solid
            s.backgroundColor = RGBAColor(hex: 0x8C4442)
            s.backgroundOpacity = 0.92
            s.borderColor = RGBAColor(hex: 0xC9837A, alpha: 0.9)
            s.borderWidth = 1.5
            s.indicatorColor = RGBAColor(hex: 0xFFD9C2)
        case .forest:
            s.backgroundColor = RGBAColor(hex: 0x1F5A3C)
            s.backgroundOpacity = 0.7
            s.borderColor = RGBAColor(hex: 0x8FD6A8, alpha: 0.5)
            s.indicatorColor = RGBAColor(hex: 0xC8F2D4)
        case .neonPink, .neonCyan, .neonLime:
            let neon: UInt32 = self == .neonPink ? 0xFF2BD6 : self == .neonCyan ? 0x00E5FF : 0xA6FF00
            s.background = .solid
            s.backgroundColor = RGBAColor(hex: 0x0B0710)
            s.backgroundOpacity = 0.85
            s.borderColor = RGBAColor(hex: neon)
            s.borderWidth = 1.5
            s.glow = true
            s.indicatorColor = RGBAColor(hex: neon)
        }
        return s
    }

    /// Swatch colors for the theme picker: fill and outline.
    var swatch: (fill: NSColor, stroke: NSColor) {
        guard let p = preset, self != .system else {
            return (.windowBackgroundColor, .separatorColor)
        }
        return (p.backgroundColor.nsColor, p.borderColor.nsColor.withAlphaComponent(1))
    }
}

/// How one dock looks. The system theme follows Light/Dark and leaves the glass
/// untinted; every other theme uses the stored colors.
struct DockStyle: Codable, Equatable {
    var theme: DockTheme = .system
    var background: DockBackground = .glass
    var backgroundColor = RGBAColor(hex: 0x2C2C2E)
    /// Fill strength of a solid plate, or tint strength of the glass.
    var backgroundOpacity: Double = 0.8
    var borderColor = RGBAColor(hex: 0xFFFFFF, alpha: 0.2)
    var borderWidth: Double = 0.5
    /// Lights the border up like a neon tube.
    var glow = false
    var indicatorColor = RGBAColor(hex: 0xFFFFFF)
    /// Extra space between tiles, in points.
    var iconGap: Double = 0
    /// Corner radius as a fraction of the plate's thickness; 0.5 makes a pill.
    var cornerRoundness: Double = 0.27

    var usesSystemColors: Bool { theme == .system }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockStyle()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        theme = try value(.theme, d.theme)
        background = try value(.background, d.background)
        backgroundColor = try value(.backgroundColor, d.backgroundColor)
        backgroundOpacity = try value(.backgroundOpacity, d.backgroundOpacity)
        borderColor = try value(.borderColor, d.borderColor)
        borderWidth = try value(.borderWidth, d.borderWidth)
        glow = try value(.glow, d.glow)
        indicatorColor = try value(.indicatorColor, d.indicatorColor)
        iconGap = try value(.iconGap, d.iconGap)
        cornerRoundness = try value(.cornerRoundness, d.cornerRoundness)
    }

    /// Switches to `theme`, keeping the layout (gap, roundness) the user chose.
    mutating func apply(_ theme: DockTheme) {
        guard var preset = theme.preset else {
            self.theme = theme
            return
        }
        preset.iconGap = iconGap
        preset.cornerRoundness = cornerRoundness
        self = preset
    }
}

/// Images the user picked for apps, folders and files. Each is copied into
/// Application Support so it survives the original being moved or deleted.
enum CustomIcons {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiDock/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func isCustom(_ path: String) -> Bool {
        path.hasPrefix(directory.path + "/")
    }

    /// Asks for an image and makes it the icon of whatever lives at `target`.
    static func choose(for target: String, name: String, store: ConfigStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .applicationBundle]
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Chọn ảnh (PNG, ICNS, JPEG…) hoặc một app để lấy biểu tượng cho “\(name)”"
        panel.prompt = "Dùng biểu tượng"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // An app (or anything without image data) lends its Finder icon instead.
        let image = url.pathExtension.lowercased() == "app" ? nil : NSImage(contentsOf: url)
        let icon = image ?? NSWorkspace.shared.icon(forFile: url.path)
        let file = directory.appendingPathComponent("\(UUID().uuidString).png")
        guard let png = squarePNG(icon, pixels: 512), (try? png.write(to: file, options: .atomic)) != nil else { return }
        set(file.path, for: target, store: store)
    }

    /// Fits the image into a transparent square, as large as the dock ever draws it.
    private static func squarePNG(_ image: NSImage, pixels: Int) -> Data? {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let side = CGFloat(pixels)
        let scale = side / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func reset(_ target: String, store: ConfigStore) {
        set(nil, for: target, store: store)
    }

    private static func set(_ path: String?, for target: String, store: ConfigStore) {
        if let old = store.config.customIcons[target], isCustom(old) {
            try? FileManager.default.removeItem(atPath: old)
        }
        store.mutate { $0.customIcons[target] = path }
    }
}
