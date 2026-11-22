import AppKit
import Combine

/// Replaces the running app with the `MultiDock.zip` attached to the latest
/// GitHub release, then relaunches it. The new bundle must carry the same
/// code-signing identifier, so macOS keeps the Accessibility grant and the
/// login item.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, download: URL)
        case installing
        case failed(String)
    }

    static let shared = Updater()

    private static let latestRelease = URL(string: "https://api.github.com/repos/haphuocsang1801/multi-dock/releases/latest")!
    private static let assetName = "MultiDock.zip"
    private static let signingRequirement = "=identifier \"com.hasang.multidock\""

    @Published private(set) var state: State = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() {
        guard state != .checking, state != .installing else { return }
        state = .checking
        Task {
            do {
                state = try await fetchLatest()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func install() {
        guard case let .available(_, download) = state else { return }
        state = .installing
        Task {
            do {
                try await downloadAndRelaunch(from: download)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> State {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noRelease }

        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard Self.isNewer(version, than: currentVersion) else { return .upToDate }
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else { throw UpdateError.noAsset }
        return .available(version: version, download: asset.browser_download_url)
    }

    private func downloadAndRelaunch(from url: URL) async throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable(target.deletingLastPathComponent().path)
        }

        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiDock-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(Self.assetName)
        try FileManager.default.moveItem(at: file, to: zip)

        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("MultiDock.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.badArchive }
        do {
            try await Self.run("/usr/bin/codesign", ["--verify", "--strict", "-R", Self.signingRequirement, newApp.path])
        } catch {
            throw UpdateError.badSignature
        }

        // The script waits for this process to exit, swaps the bundles (putting
        // the old one back if the swap fails) and opens whichever is in place.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old"; then
          if mv "$2" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; fi
        fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        rm -rf "$4"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "multidock-update",
                          String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, work.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// Compares dotted numeric versions, so 1.10.0 is newer than 1.9.2.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.tool(tool))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum UpdateError: LocalizedError {
    case noRelease, noAsset, download, badArchive, badSignature
    case notWritable(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .noRelease: return "Không đọc được bản phát hành mới nhất trên GitHub."
        case .noAsset: return "Bản phát hành mới nhất không có file MultiDock.zip."
        case .download: return "Tải bản cập nhật không thành công."
        case .badArchive: return "File tải về không chứa MultiDock.app."
        case .badSignature: return "Bản tải về không phải MultiDock (chữ ký không khớp), đã hủy cập nhật."
        case let .notWritable(path): return "Không có quyền ghi vào \(path)."
        case let .tool(tool): return "Lệnh \(tool) bị lỗi."
        }
    }
}
