import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MultiDock: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init(store: ConfigStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MultiDock"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ScreenChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

private func connectedScreens() -> [ScreenChoice] {
    NSScreen.screens.map { ScreenChoice(id: $0.stableID, name: $0.localizedName) }
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @State private var selection: UUID?

    var body: some View {
        TabView {
            docksTab.tabItem { Label("Dock", systemImage: "dock.rectangle") }
            GeneralSettingsView().tabItem { Label("Chung", systemImage: "gearshape") }
        }
        .padding(12)
        .onAppear { if selection == nil { selection = store.config.docks.first?.id } }
    }

    private var docksTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.docks) { dock in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dock.screenName).lineLimit(1)
                            Text(subtitle(for: dock)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(dock.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button(action: addDock) { Image(systemName: "plus").frame(width: 20, height: 20) }
                    Button(action: removeSelected) { Image(systemName: "minus").frame(width: 20, height: 20) }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 210)
            Divider()
            if let id = selection, let binding = binding(for: id) {
                DockSettingsForm(store: store, dock: binding)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "dock.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Bấm + để thêm một Dock mới").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func subtitle(for dock: DockConfig) -> String {
        let connected = NSScreen.withStableID(dock.screenID) != nil
        return "Cạnh \(dock.edge.title.lowercased()) · \(dock.items.count) mục" + (connected ? "" : " · chưa kết nối")
    }

    private func binding(for id: UUID) -> Binding<DockConfig>? {
        guard let current = store.config.docks.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.config.docks.first(where: { $0.id == id }) ?? current },
            set: { newValue in store.updateDock(id) { $0 = newValue } }
        )
    }

    private func addDock() {
        let used = Set(store.config.docks.map(\.screenID))
        let screen = NSScreen.screens.first { !used.contains($0.stableID) } ?? NSScreen.main ?? NSScreen.screens[0]
        let dock = DockConfig(screenID: screen.stableID, screenName: screen.localizedName)
        store.mutate { $0.docks.append(dock) }
        selection = dock.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.mutate { $0.docks.removeAll { $0.id == id } }
        selection = store.config.docks.first?.id
    }
}

struct DockSettingsForm: View {
    @ObservedObject var store: ConfigStore
    @Binding var dock: DockConfig

    private var screenChoices: [ScreenChoice] {
        var list = connectedScreens()
        if !list.contains(where: { $0.id == dock.screenID }) {
            list.append(ScreenChoice(id: dock.screenID, name: "\(dock.screenName) (chưa kết nối)"))
        }
        return list
    }

    private var screenBinding: Binding<String> {
        Binding(get: { dock.screenID }, set: { id in
            dock.screenID = id
            if let name = connectedScreens().first(where: { $0.id == id })?.name { dock.screenName = name }
        })
    }

    var body: some View {
        Form {
            Section("Vị trí") {
                Picker("Màn hình", selection: screenBinding) {
                    ForEach(screenChoices) { Text($0.name).tag($0.id) }
                }
                Picker("Cạnh màn hình", selection: $dock.edge) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Kích thước và phóng to") {
                LabeledContent("Kích thước") {
                    HStack {
                        Text("Nhỏ").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $dock.iconSize, in: 16...128, step: 1)
                        Text("Lớn").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(dock.iconSize))").monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                }
                Toggle("Phóng to", isOn: $dock.magnification)
                if dock.magnification {
                    LabeledContent("Mức phóng to") {
                        HStack {
                            Text("Ít").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $dock.magnifiedSize, in: dock.iconSize...max(dock.iconSize + 1, 128), step: 1)
                            Text("Nhiều").font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(max(dock.magnifiedSize, dock.iconSize)))").monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }

            DockStyleSection(style: $dock.style)

            Section("Hành vi") {
                Toggle("Tự động ẩn và hiện Dock", isOn: $dock.autoHide)
                if dock.autoHide {
                    LabeledContent("Độ trễ khi hiện") {
                        HStack {
                            Slider(value: $dock.autoHideDelay, in: 0...1, step: 0.05)
                            Text(String(format: "%.2fs", dock.autoHideDelay)).monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Tốc độ ẩn/hiện") {
                        HStack {
                            Text("Nhanh").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $dock.autoHideDuration, in: 0...1, step: 0.05)
                            Text("Chậm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Tự động ẩn khi app ở chế độ toàn màn hình", isOn: $dock.hideInFullScreen)
                    .help("Dock tránh sang một bên khi màn hình này đang có app toàn màn hình; đưa chuột ra cạnh màn hình để hiện lại. Nếu Dock hệ thống nằm cùng cạnh, chỉ Dock hệ thống hiện để hai Dock không chồng lên nhau")
                Toggle("Giữ chỗ cho Dock khi phóng to cửa sổ", isOn: $dock.reserveSpace)
                    .help("Cửa sổ phóng to hoặc xếp kín màn hình sẽ dừng ở mép Dock như với Dock hệ thống, thay vì nằm dưới Dock. Cần quyền Trợ năng; không áp dụng khi Dock đang ẩn")
                Toggle("Hiệu ứng khi mở ứng dụng", isOn: $dock.bounceOnLaunch)
                Toggle("Hiển thị chỉ báo cho ứng dụng đang mở", isOn: $dock.showIndicators)
                Toggle("Làm mờ biểu tượng của ứng dụng bị ẩn", isOn: $dock.dimHiddenApps)
                Toggle("Hiển thị ứng dụng gần đây trong Dock", isOn: $dock.showRecents)
                Toggle("Hiển thị Thùng rác", isOn: $dock.showTrash)
                Toggle("Khóa nội dung Dock (không kéo thả, thêm, xóa)", isOn: $dock.locked)
            }

            Section("App đang chạy") {
                Picker("Hiển thị", selection: $dock.runningMode) {
                    ForEach(RunningAppsMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                if dock.items.isEmpty {
                    Text("Chưa có mục nào. Kéo app, thư mục hoặc file từ Finder thả vào Dock, hoặc bấm Thêm.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dock.items) { item in
                    HStack {
                        Image(nsImage: icon(for: item)).resizable().frame(width: 20, height: 20)
                        Text(item.name)
                        Spacer()
                        Button { CustomIcons.choose(for: item.path, name: item.name, store: store) } label: {
                            Image(systemName: "photo")
                        }
                        .help("Đổi biểu tượng")
                        if store.config.customIcons[item.path] != nil {
                            Button { CustomIcons.reset(item.path, store: store) } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .help("Dùng biểu tượng gốc")
                        }
                        Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(dock.items.first?.id == item.id)
                        Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(dock.items.last?.id == item.id)
                        Button { dock.items.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Thêm app, thư mục hoặc file…", action: addItems)
                    Spacer()
                    Button("Sao chép từ Dock hệ thống") { SystemDock.apply(to: &dock) }
                        .help("Lấy các mục đã ghim, kích thước và phóng to từ Dock của macOS")
                }
            } header: {
                Text("Mục đã ghim")
            }
        }
        .formStyle(.grouped)
    }

    private func icon(for item: DockItem) -> NSImage {
        store.config.customIcons[item.path].flatMap(NSImage.init(contentsOfFile:))
            ?? NSWorkspace.shared.icon(forFile: item.path)
    }

    private func move(_ item: DockItem, by delta: Int) {
        guard let i = dock.items.firstIndex(where: { $0.id == item.id }) else { return }
        let j = i + delta
        guard dock.items.indices.contains(j), (dock.items[j].kind == .app) == (item.kind == .app) else { return }
        dock.items.swapAt(i, j)
    }

    private func addItems() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Thêm"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let item = DockItem.make(url: url)
            if !dock.items.contains(where: { $0.path == item.path }) { dock.items.append(item) }
        }
        dock.normalizeItems()
    }
}

/// Theme, background and spacing of one dock. Editing a color or the border
/// turns the theme into Custom, starting from what is on screen.
struct DockStyleSection: View {
    @Binding var style: DockStyle

    var body: some View {
        Section("Giao diện") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chủ đề")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 10) {
                    ForEach(DockTheme.allCases) { theme in
                        Button { style.apply(theme) } label: { swatch(theme) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Picker("Nền", selection: $style.background) {
                ForEach(DockBackground.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if style.usesSystemColors {
                Text("Màu theo giao diện Sáng/Tối của macOS. Chọn một chủ đề khác hoặc Tùy chỉnh để tự chọn màu.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if style.background != .none {
                    ColorPicker("Màu nền", selection: color(\.backgroundColor), supportsOpacity: false)
                    LabeledContent(style.background == .glass ? "Độ đậm màu kính" : "Độ đục của nền") {
                        HStack {
                            Slider(value: themed(\.backgroundOpacity), in: 0...1)
                            Text("\(Int(style.backgroundOpacity * 100))%").monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    ColorPicker("Màu viền", selection: color(\.borderColor))
                    LabeledContent("Độ dày viền") {
                        HStack {
                            Slider(value: themed(\.borderWidth), in: 0...4, step: 0.5)
                            Text(String(format: "%.1f", style.borderWidth)).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Toggle("Viền phát sáng (neon)", isOn: themed(\.glow))
                }
                ColorPicker("Màu chấm chỉ báo và vạch ngăn", selection: color(\.indicatorColor))
            }

            LabeledContent("Khoảng cách giữa icon") {
                HStack {
                    Slider(value: $style.iconGap, in: 0...24, step: 1)
                    Text("\(Int(style.iconGap))").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if style.background != .none {
                LabeledContent("Bo góc") {
                    HStack {
                        Text("Vuông").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $style.cornerRoundness, in: 0...0.5)
                        Text("Tròn").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Khôi phục mặc định") { style = DockStyle() }
                    .disabled(style == DockStyle())
                    .help("Đưa chủ đề, nền, màu, khoảng cách và bo góc của Dock này về như ban đầu")
            }
        }
    }

    private func swatch(_ theme: DockTheme) -> some View {
        let colors = theme == .custom
            ? (fill: style.backgroundColor.nsColor, stroke: style.borderColor.nsColor.withAlphaComponent(1))
            : theme.swatch
        let selected = style.theme == theme
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: colors.fill))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: colors.stroke), lineWidth: 1.5))
                .overlay {
                    if theme == .system {
                        Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 22)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            Text(theme.title).font(.caption2).lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .frame(minWidth: 84)
        .contentShape(Rectangle())
    }

    private func markCustom() {
        if style.theme != .custom { style.theme = .custom }
    }

    private func themed<T>(_ key: WritableKeyPath<DockStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: {
            style[keyPath: key] = $0
            markCustom()
        })
    }

    private func color(_ key: WritableKeyPath<DockStyle, RGBAColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: style[keyPath: key].nsColor) }, set: {
            style[keyPath: key] = RGBAColor(NSColor($0))
            markCustom()
        })
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var axTrusted = AppActions.isAccessibilityTrusted
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Mở MultiDock khi đăng nhập", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set($0) }
            }
            Section {
                LabeledContent("Quyền Trợ năng (Accessibility)") {
                    if axTrusted {
                        Label("Đã cấp", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Cấp quyền…") { AppActions.requestAccessibility() }
                    }
                }
            } footer: {
                Text("Không bắt buộc. Khi có quyền, bấm vào app trên một Dock sẽ đưa đúng cửa sổ của app nằm trên màn hình đó lên trước, và cửa sổ phóng to sẽ dừng ở mép Dock thay vì nằm dưới Dock.")
                    .foregroundStyle(.secondary)
            }
            UpdateSection()
            Section {
                Text("Mẹo: kéo app từ Finder thả vào Dock để ghim, kéo icon ra ngoài để xóa, kéo sang Dock khác để chuyển. Thả file lên icon app để mở bằng app đó. Bấm chuột phải vào Dock để đổi nhanh vị trí và tùy chọn.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in axTrusted = AppActions.isAccessibilityTrusted }
    }
}

/// Checks GitHub for a newer release when shown; one click installs it.
struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Cập nhật") {
            LabeledContent("Phiên bản hiện tại", value: updater.currentVersion)
            HStack {
                status
                Spacer()
                action
            }
        }
        .onAppear { if updater.state == .idle { updater.check() } }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            Text("Đang kiểm tra…").foregroundStyle(.secondary)
        case .upToDate:
            Label("Bạn đang dùng bản mới nhất", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .available(version, _):
            Label("Đã có bản \(version)", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .installing:
            ProgressView().controlSize(.small)
            Text("Đang tải và cài đặt, app sẽ tự mở lại…").foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.state {
        case let .available(version, _):
            Button("Cập nhật lên \(version)") { updater.install() }.buttonStyle(.borderedProminent)
        case .idle, .upToDate, .failed:
            Button("Kiểm tra cập nhật") { updater.check() }
        case .checking, .installing:
            EmptyView()
        }
    }
}
