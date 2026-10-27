import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Survives reboots and re-plugging, unlike the numeric display ID.
    var stableID: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(displayID)"
    }

    static func withStableID(_ id: String) -> NSScreen? {
        screens.first { $0.stableID == id }
    }

    /// Converts a rect in global CoreGraphics coordinates (top-left origin of the
    /// primary display) to Cocoa screen coordinates (bottom-left origin).
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
