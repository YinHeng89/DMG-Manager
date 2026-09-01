import SwiftUI

/// 设置窗口。
///
/// 这里刻意**不持有 store、也不读任何数据**：四个页面各自是独立的 `View`。
/// SwiftUI 的 `@Observable` 是按 View 粒度追踪依赖的，如果把它们写成 `SettingsView`
/// 的计算属性，任何一页读到的数据一变（`body` 求值就会订阅），整个 `SettingsView`
/// 连同标签栏都会被重绘；解析时 `items` 每解析完一个条目就变一次，标签栏图标就会一直抖。
/// 拆成独立 View 后，只有真正数据变了的那一个页面会重绘，标签栏始终不动。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            LibrarySettingsTab()
                .tabItem { Label("资料库", systemImage: "externaldrive") }
            DataSettingsTab()
                .tabItem { Label("数据", systemImage: "internaldrive") }
            AboutSettingsTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Form {
            Picker("默认视图", selection: Binding(
                get: { store.browseMode },
                set: { store.browseMode = $0; store.saveSettings() }
            )) {
                Text("列表").tag(BrowseMode.list)
                Text("图标").tag(BrowseMode.grid)
            }

            Picker("排序", selection: Binding(
                get: { store.sortField },
                set: { store.sortField = $0 }
            )) {
                ForEach(SortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }

            Toggle("升序排列", isOn: Binding(
                get: { store.sortAscending },
                set: { store.sortAscending = $0 }
            ))
        }
        .formStyle(.grouped)
        .padding()
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
                    Text("还没有添加目录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(directoryInfo) { info in
                        directoryRow(info)
                    }
                }

                Button {
                    showFolderPicker = true
                } label: {
                    Label("添加目录…", systemImage: "plus")
                }
            } header: {
                // 叫「扫描目录」而不是「监控目录」：这里没有后台文件监听，
                // 目录只用于扫描导入和失联文件找回。
                Text("扫描目录")
            } footer: {
                Text("目录用于扫描导入 DMG，以及文件失联时找回原文件。移除目录只是不再扫描它，已入库的条目会保留。导入与解析请在主窗口的「操作」菜单里进行。")
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
                .help(info.exists ? "" : "目录已不存在，可能已被删除或移动")

            Text(info.url.path)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("\(info.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                store.removeWatchDirectory(info.url)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("移除目录（不会删除已入库的条目）")
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
    @State private var showBackupDone = false

    var body: some View {
        Form {
            Section {
                Text(AppPaths.root.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                HStack {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database])
                    }
                    Button("打开图标缓存") {
                        NSWorkspace.shared.open(AppPaths.thumbnails)
                    }
                }
            } header: {
                Text("数据位置")
            }

            Section {
                HStack {
                    Button("立即备份") {
                        BackupService.snapshot(database: AppPaths.database)
                        showBackupDone = true
                    }
                    if showBackupDone {
                        Label("已备份", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("打开备份目录") {
                        NSWorkspace.shared.open(AppPaths.backups)
                    }
                }
            } header: {
                Text("备份")
            } footer: {
                Text("启动时自动快照，最多保留 \(BackupService.keepCount) 份。数据库使用 WAL 模式，崩溃也不会丢备注。")
            }

            // LabeledContent 让数值右对齐：解析时数字变化只影响左边缘，不会顶高整行。
            Section("统计") {
                LabeledContent("安装包") {
                    Text("\(store.items.count)")
                        .monospacedDigit()
                }
                LabeledContent("标签") {
                    Text("\(store.tagCounts.count)")
                        .monospacedDigit()
                }
                LabeledContent("分类") {
                    Text("\(store.categoryCounts.count)")
                        .monospacedDigit()
                }
                LabeledContent("总大小") {
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
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("DMG Library")
                    .font(.title2.weight(.semibold))
                Text("一个不改变原始文件的 Mac 安装包资料库")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Keep the file. Organize the meaning.\n文件不动，信息由你定义。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("无账号、无服务器、无云端、无遥测", systemImage: "lock.fill")
                Label("所有数据只存在你的 Mac 上", systemImage: "internaldrive")
                Label("原始 DMG 永不被重命名、移动或修改", systemImage: "hand.raised.fill")
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
