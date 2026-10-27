import AppKit

/// Renders each icon once at the largest size a dock can display it, so
/// hovering and magnification only rescale an existing GPU texture.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: CGImage] = [:]

    func image(path: String?, app: NSRunningApplication?, pixelSize: Int) -> CGImage? {
        let source = path ?? app?.bundleURL?.path ?? "pid-\(app?.processIdentifier ?? 0)"
        let key = "\(source)#\(pixelSize)"
        if let cached = cache[key] { return cached }

        let image: NSImage
        if let path, path.hasPrefix("/System/Library/CoreServices/"), !path.hasSuffix(".app"),
           let file = NSImage(contentsOfFile: path) {
            image = file
        } else if let path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let icon = app?.icon {
            image = icon
        } else if let path {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }

        let cg = render(image, pixelSize: pixelSize)
        cache[key] = cg
        return cg
    }

    func invalidate() { cache.removeAll() }

    private func render(_ image: NSImage, pixelSize: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
