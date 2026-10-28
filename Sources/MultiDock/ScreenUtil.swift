import AppKit

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

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

    /// Stable IDs of displays currently showing a full-screen space (a single
    /// full-screen app or Split View). Read from the window server's space list,
    /// which has no public API; the same call AltTab and yabai rely on.
    static var fullScreenIDs: Set<String> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue()
                as? [[String: Any]] else { return [] }
        var ids = Set<String>()
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? Int) == 4,
                  let identifier = display["Display Identifier"] as? String else { continue }
            // "Main" means displays share one set of spaces.
            if identifier == "Main" { return Set(screens.map(\.stableID)) }
            ids.insert(identifier.uppercased())
        }
        return ids
    }

    /// Converts a rect in global CoreGraphics coordinates (top-left origin of the
    /// primary display) to Cocoa screen coordinates (bottom-left origin).
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
