import AppKit

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ connection: Int32, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ connection: Int32, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> CGError

/// The window server ignores cursor changes from an app that is not active, and
/// MultiDock never is, so the resize cursor over a dock's separator needs this.
/// The connection property has no public equivalent.
func allowCursorChangesInBackground() {
    let connection = CGSMainConnectionID()
    _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

struct DisplaySpaces: Equatable {
    /// The space the display shows.
    var current: Int
    var fullScreen: [Int]

    var showsFullScreen: Bool { fullScreen.contains(current) }
}

/// macOS carries a window that joins all spaces onto a full-screen space only
/// once a switch to it has ended, so it flashes up there before anyone can hide
/// it. Settling which of `fullScreen` it belongs to beforehand avoids that.
func setFullScreenSpaces(of window: NSWindow, to keep: [Int], outOf fullScreen: [Int]) {
    let connection = CGSMainConnectionID()
    let windows = [window.windowNumber] as CFArray
    let leave = fullScreen.filter { !keep.contains($0) }
    if !leave.isEmpty { CGSRemoveWindowsFromSpaces(connection, windows, leave as CFArray) }
    if !keep.isEmpty { CGSAddWindowsToSpaces(connection, windows, keep as CFArray) }
}

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

    /// Each display's full-screen spaces (a single full-screen app or Split View)
    /// and the space it shows, by stable ID. Read from the window server's space
    /// list, which has no public API; the same call AltTab and yabai rely on.
    static var spaces: [String: DisplaySpaces] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue()
                as? [[String: Any]] else { return [:] }
        var result: [String: DisplaySpaces] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            else { continue }
            let fullScreen = (display["Spaces"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? Int) == 4 }
                .compactMap { $0["ManagedSpaceID"] as? Int }
            let entry = DisplaySpaces(current: current, fullScreen: fullScreen)
            // "Main" means displays share one set of spaces.
            if identifier == "Main" { return Dictionary(uniqueKeysWithValues: screens.map { ($0.stableID, entry) }) }
            result[identifier.uppercased()] = entry
        }
        return result
    }

    /// Converts a rect in global CoreGraphics coordinates (top-left origin of the
    /// primary display) to Cocoa screen coordinates (bottom-left origin).
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The inverse of `cocoaRect(fromCG:)`, for positioning windows through Accessibility.
    static func cgRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
