import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showBackupDone = false
    @State private var showFolderPicker = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            libraryTab
                .tabItem { Label("资料库", systemImage: "externaldrive") }
            dataTab
                .tabItem { Label("数据", systemImage: "internaldrive") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }

    // MARK: - 通用

    private var generalTab: some View {
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

    // MARK: - 资料库

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("监控目录")
                    .font(.headline)
                Spacer()
                Button {
                    showFolderPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加目录，用于扫描与自动重新定位")
            }

            if store.watchDirectories.isEmpty {
                Text("还没有监控目录。文件失联时，软件会在这些目录里帮你找回来。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                List {
                    ForEach(store.watchDirectories, id: \.path) { directory in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(directory.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                store.watchDirectories.removeAll { $0.path == directory.path }
                                store.saveSettings()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.bordered)
            }

            Button("立即扫描所有监控目录") {
                Task {
                    for directory in store.watchDirectories {
                        _ = await store.scanFolder(directory)
                    }
                }
            }
            .disabled(store.watchDirectories.isEmpty)

            Spacer()
        }
        .padding()
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { (result: Result<URL, Error>) in
            if case .success(let url) = result {
                if !store.watchDirectories.contains(url) {
                    store.watchDirectories.append(url)
                    store.saveSettings()
                }
                Task { _ = await store.scanFolder(url) }
            }
        }
    }

    // MARK: - 数据

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("数据位置")
                        .font(.headline)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("备份")
                        .font(.headline)
                    Text("启动时自动快照，最多保留 \(BackupService.keepCount) 份。数据库使用 WAL 模式，崩溃也不会丢备注。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("统计")
                        .font(.headline)
                    Text("\(store.items.count) 个安装包 · \(store.tagCounts.count) 个标签 · \(store.categoryCounts.count) 个分类")
                        .font(.callout)
                    Text("总大小 \(ByteFormatter.string(fromBytes: store.items.reduce(0) { $0 + $1.fileSize }))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - 关于

    private var aboutTab: some View {
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
