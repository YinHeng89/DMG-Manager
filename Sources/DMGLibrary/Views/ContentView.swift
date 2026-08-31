import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isSearching = false
    @State private var showFilters = false
    @State private var showSettings = false
    @State private var pendingDeletion: Set<Int64> = []
    @State private var confirmDeleteWithTrash = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            BrowserPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 430, max: 560)
        } detail: {
            DetailPane(item: store.selectedItem)
        }
        .navigationTitle(store.titleForSelection)
        .toolbar { toolbarContent }
        .searchable(
            text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
            isPresented: $isSearching,
            placement: .toolbar,
            prompt: Text("搜索名称 / 备注 / 标签 / Bundle ID")
        )
        .sheet(isPresented: $showFilters) { FilterPanelView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog(
            "从资料库中移除",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            presenting: pendingDeletion
        ) { ids in
            Button("仅从资料库移除", role: .destructive) {
                store.delete(ids: ids, moveToTrash: false)
                pendingDeletion = []
            }
            Button("移到废纸篓", role: .destructive) {
                store.delete(ids: ids, moveToTrash: true)
                pendingDeletion = []
            }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: { _ in
            Text("元数据会被删除，但原始 DMG 文件不会被修改。选择「移到废纸篓」会同时删除磁盘上的文件。")
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay { dropOverlay }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryAddFiles)) { _ in
            presentAddPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryScanFolder)) { _ in
            presentScanPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryFocusSearch)) { _ in
            isSearching = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .librarySelectItem)) { notification in
            if let id = notification.object as? Int64 {
                store.selection = .smart(.all)
                store.searchText = ""
                store.selectedItemID = id
            }
        }
        .task {
            await store.refreshFileStatus()
            await store.refreshInstallStatus()
        }
    }

    // MARK: - 文件选择（NSOpenPanel 比 SwiftUI fileImporter 稳定）

    /// 弹出系统文件选择器，批量添加 DMG。
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.dmg]
        panel.message = "选择要加入资料库的 DMG 文件"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        Task { await store.importFiles(urls) }
    }

    /// 弹出文件夹选择器，递归扫描其中的 DMG。
    private func presentScanPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要扫描的文件夹"
        panel.prompt = "扫描"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await store.scanFolder(url) }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                presentAddPanel()
            } label: {
                Label("添加", systemImage: "plus")
            }
            .help("添加 DMG 到资料库")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    presentScanPanel()
                } label: {
                    Label("扫描文件夹…", systemImage: "folder.badge.magnifyingglass")
                }
                Button {
                    Task { await store.reparse(ids: Set(store.filteredItems.map(\.id))) }
                } label: {
                    Label("重新解析当前列表", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await store.refreshInstallStatus() }
                } label: {
                    Label("刷新安装状态", systemImage: "checkmark.circle")
                }
                Button {
                    Task { await store.computeMissingHashes() }
                } label: {
                    Label("补齐校验和", systemImage: "number")
                }
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showFilters.toggle()
            } label: {
                Label("筛选", systemImage: store.activeFilterCount == 0
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .help("高级筛选")
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("视图", selection: Binding(
                get: { store.browseMode },
                set: { store.browseMode = $0; store.saveSettings() }
            )) {
                ForEach(BrowseMode.allCases) { mode in
                    Image(systemName: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("切换列表 / 图标视图")
        }
    }

    // MARK: - 拖拽导入

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.blue.opacity(0.7), lineWidth: 3)
                    )
                VStack(spacing: 12) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 44))
                    Text("松手即可加入资料库")
                        .font(.title3.weight(.medium))
                    Text("原始文件不会被移动或修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(40)
            }
            .padding(24)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, url.pathExtension.lowercased() == "dmg" else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else {
                errorMessage = "只支持 .dmg 文件"
                return
            }
            Task { await store.importFiles(urls) }
        }
        return true
    }
}

/// 中间列：列表 / 图标视图 + 导入进度 + 空状态。
struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.isImporting {
                ImportProgressBanner()
            }

            if store.filteredItems.isEmpty {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.browseMode == .list {
                ItemListView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ItemGridView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBarView(items: store.filteredItems)
        }
    }
}

struct ImportProgressBanner: View {
    @Environment(LibraryStore.self) private var store

    private var stageTitle: String {
        switch store.importStage {
        case .adding: return "正在添加"
        case .parsing: return "正在解析"
        }
    }

    private var stageSymbol: String {
        switch store.importStage {
        case .adding: return "plus"
        case .parsing: return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Image(systemName: stageSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(stageTitle) \(store.importCompleted)/\(store.importTotal)")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            if !store.importStatusMessage.isEmpty {
                Text(store.importStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("添加 DMG") {
                NotificationCenter.default.post(name: .libraryAddFiles, object: nil)
            }
            Button("扫描文件夹") {
                NotificationCenter.default.post(name: .libraryScanFolder, object: nil)
            }
        }
    }

    private var emptyTitle: String {
        if !store.searchText.isEmpty { return "没有匹配结果" }
        switch store.selection {
        case .smart(.favorites): return "还没有收藏"
        case .smart(.missing): return "没有失联文件"
        case .smart(.duplicates): return "没有重复文件"
        case .smart(.recentlyUsed): return "还没有打开记录"
        default: return "资料库是空的"
        }
    }

    private var emptySymbol: String {
        if !store.searchText.isEmpty { return "magnifyingglass" }
        switch store.selection {
        case .smart(.favorites): return "star"
        case .smart(.missing): return "checkmark.icloud"
        case .smart(.duplicates): return "doc.on.doc"
        default: return "opticaldisc"
        }
    }

    private var emptyDescription: String {
        if !store.searchText.isEmpty {
            return "试试其他关键词，或清空搜索框。"
        }
        return "把 DMG 拖进窗口，或扫描整个下载文件夹。"
    }
}

struct StatusBarView: View {
    let items: [DMGItem]

    var body: some View {
        HStack(spacing: 12) {
            Text("\(items.count) 个安装包")
            Text("·")
            Text(ByteFormatter.string(fromBytes: items.reduce(0) { $0 + $1.fileSize }))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
