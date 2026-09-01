import SwiftUI

/// 设置窗口。
///
/// 这里刻意**不持有 store、也不读任何数据**：四个页面各自是独立的 `View`。
/// SwiftUI 的 `@Observable` 是按 View 粒度追踪依赖的，如果把它们写成 `SettingsView`
/// 的计算属性，任何一页读到的数据一变（`body` 求值就会订阅），整个 `SettingsView`
/// 连同标签栏都会被重绘；解析时 `items` 每解析完一个条目就变一次，标签栏图标就会一直抖。
/// 拆成独立 View 后，只有真正数据变了的那一个页面会重绘，标签栏始终不动。
struct SettingsView: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(prefs.t("settings.general"), systemImage: "gearshape") }
            LibrarySettingsTab()
                .tabItem { Label(prefs.t("settings.library"), systemImage: "externaldrive") }
            DataSettingsTab()
                .tabItem { Label(prefs.t("settings.data"), systemImage: "internaldrive") }
            AboutSettingsTab()
                .tabItem { Label(prefs.t("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
        .preferredColorScheme(prefs.appearance.colorScheme)
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Picker(prefs.t("settings.language"), selection: Binding(
                get: { prefs.language },
                set: { prefs.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }

            Picker(prefs.t("settings.appearance"), selection: Binding(
                get: { prefs.appearance },
                set: { prefs.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases) { value in
                    Text(appearanceTitle(value)).tag(value)
                }
            }

            Picker(prefs.t("settings.defaultView"), selection: Binding(
                get: { store.browseMode },
                set: { store.browseMode = $0; store.saveSettings() }
            )) {
                Text(prefs.t("settings.list")).tag(BrowseMode.list)
                Text(prefs.t("settings.grid")).tag(BrowseMode.grid)
            }

            Picker(prefs.t("settings.sort"), selection: Binding(
                get: { store.sortField },
                set: { store.sortField = $0 }
            )) {
                ForEach(SortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }

            Toggle(prefs.t("settings.ascending"), isOn: Binding(
                get: { store.sortAscending },
                set: { store.sortAscending = $0 }
            ))
        }
        .formStyle(.grouped)
        .padding()
    }

    private func appearanceTitle(_ value: AppAppearance) -> String {
        switch value {
        case .system: return prefs.t("appearance.system")
        case .light: return prefs.t("appearance.light")
        case .dark: return prefs.t("appearance.dark")
        }
    }
}

// MARK: - 资料库

/// 只负责「扫描目录」的增删与状态展示，**不做扫描、不做解析**。
///
/// 这里刻意不读 `store.isImporting`，也不放扫描按钮 / 进度条 / 结果文案：
/// 解析过程中这些状态会高频变化，只要订阅了就会把整个页面拖进反复重绘。
/// 扫描与解析统一由主窗口的「操作」菜单负责，进度也在主窗口显示。
private struct LibrarySettingsTab: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    @State private var showFolderPicker = false

    /// 目录的展示信息。
    ///
    /// 缓存而不是在 body 里现算：统计条目数要逐条比对路径（O(n)），
    /// 判断目录是否存在还要访问磁盘，放在 body 里会被反复执行。
    private struct DirectoryInfo: Identifiable {
        let url: URL
        let count: Int
        let exists: Bool

        var id: String { url.path }
    }

    @State private var directoryInfo: [DirectoryInfo] = []

    var body: some View {
        Form {
            Section {
                if directoryInfo.isEmpty {
                    Text(prefs.t("settings.noDirs"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(directoryInfo) { info in
                        directoryRow(info)
                    }
                }

                Button {
                    showFolderPicker = true
                } label: {
                    Label(prefs.t("settings.addDir"), systemImage: "plus")
                }
            } header: {
                // 叫「扫描目录」而不是「监控目录」：这里没有后台文件监听，
                // 目录只用于扫描导入和失联文件找回。
                Text(prefs.t("settings.scanDirs"))
            } footer: {
                Text(prefs.t("settings.scanDirs.footer"))
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { (result: Result<URL, Error>) in
            if case .success(let url) = result {
                store.addWatchDirectory(url) // 内部按解析后的真实路径去重
                Task {
                    // 后台导入，进度由主窗口显示；本页不持有任何扫描状态。
                    await store.scanFolder(url)
                    refreshDirectoryInfo()
                }
            }
        }
        .task { refreshDirectoryInfo() }
        .onChange(of: store.watchDirectories) { _, _ in refreshDirectoryInfo() }
    }

    private func directoryRow(_ info: DirectoryInfo) -> some View {
        HStack(spacing: 6) {
                Image(systemName: info.exists ? "folder" : "exclamationmark.triangle.fill")
                    .foregroundStyle(info.exists ? Color.secondary : Color.orange)
                    .help(info.exists ? "" : prefs.t("settings.dirMissing"))

            Text(info.url.path)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(prefs.t("browser.itemCount", info.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                store.removeWatchDirectory(info.url)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help(prefs.t("settings.removeDir.help"))
        }
    }

    private func refreshDirectoryInfo() {
        directoryInfo = store.watchDirectories.map {
            DirectoryInfo(url: $0, count: store.itemCount(in: $0), exists: store.directoryExists($0))
        }
    }
}

// MARK: - 数据

private struct DataSettingsTab: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var showBackupDone = false

    var body: some View {
        Form {
            Section {
                Text(AppPaths.root.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                HStack {
                    Button(prefs.t("settings.showInFinder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database])
                    }
                    Button(prefs.t("settings.openIconCache")) {
                        NSWorkspace.shared.open(AppPaths.thumbnails)
                    }
                }
            } header: {
                Text(prefs.t("settings.dataLocation"))
            }

            Section {
                HStack {
                    Button(prefs.t("settings.backupNow")) {
                        BackupService.snapshot(database: AppPaths.database)
                        showBackupDone = true
                    }
                    if showBackupDone {
                        Label(prefs.t("settings.backedUp"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button(prefs.t("settings.openBackupDir")) {
                        NSWorkspace.shared.open(AppPaths.backups)
                    }
                }
            } header: {
                Text(prefs.t("settings.backup"))
            } footer: {
                Text(prefs.t("settings.backup.footer", BackupService.keepCount))
            }

            // LabeledContent 让数值右对齐：解析时数字变化只影响左边缘，不会顶高整行。
            Section(prefs.t("settings.stats")) {
                LabeledContent(prefs.t("settings.stat.packages")) {
                    Text("\(store.items.count)")
                        .monospacedDigit()
                }
                LabeledContent(prefs.t("settings.stat.tags")) {
                    Text("\(store.tagCounts.count)")
                        .monospacedDigit()
                }
                LabeledContent(prefs.t("settings.stat.categories")) {
                    Text("\(store.categoryCounts.count)")
                        .monospacedDigit()
                }
                LabeledContent(prefs.t("settings.stat.totalSize")) {
                    Text(ByteFormatter.string(fromBytes: store.items.reduce(0) { $0 + $1.fileSize }))
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 关于

private struct AboutSettingsTab: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("DMG Library")
                    .font(.title2.weight(.semibold))
                Text(prefs.t("about.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(prefs.t("about.tagline"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label(prefs.t("about.noAccount"), systemImage: "lock.fill")
                Label(prefs.t("about.localOnly"), systemImage: "internaldrive")
                Label(prefs.t("about.untouched"), systemImage: "hand.raised.fill")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            Spacer()
        }
        .padding(24)
    }
}
