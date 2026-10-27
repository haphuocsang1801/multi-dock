import Combine
import Foundation

/// Owns the persisted configuration. Every change is published synchronously
/// (docks re-layout immediately) and written to disk after a short debounce.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }

    let isFirstRun: Bool
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            isFirstRun = false
        } else {
            config = AppConfig()
            isFirstRun = true
        }
    }

    func mutate(_ body: (inout AppConfig) -> Void) {
        var copy = config
        body(&copy)
        config = copy
    }

    func updateDock(_ id: UUID, _ body: (inout DockConfig) -> Void) {
        mutate { cfg in
            guard let i = cfg.docks.firstIndex(where: { $0.id == id }) else { return }
            body(&cfg.docks[i])
        }
    }

    func saveNow() {
        saveWork?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
