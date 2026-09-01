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
            // 三栏的最小宽度之和必须远小于窗口宽度，否则 NSSplitView 会按
            // holdingPriority 自动折叠侧边栏（表现为「整个布局发生变化」，
            // 同时分栏 frame 跳到标题栏底下：顶部横线消失、竖分隔线贯穿整个窗口）。
            // 详情列以前没有宽度约束，它的最小宽度完全由内容决定（操作按钮排 ≈400pt），
            // 选中条目后就会把可用空间吃光，所以这里必须显式给一个小下限。
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            BrowserPane()
                .navigationSplitViewColumnWidth(min: 300, ideal: 430, max: 560)
        } detail: {
            DetailPane(item: store.selectedItem)
                .navigationSplitViewColumnWidth(min: 320, ideal: 520, max: 900)
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
        .overlay { WindowChromeFix() }
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
                    Task { await store.scanAllWatchDirectories() }
                } label: {
                    Label("扫描所有目录", systemImage: "arrow.clockwise")
                }
                .disabled(store.watchDirectories.isEmpty)
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

/// 中间列：固定顶栏 + 列表 / 图标视图 + 导入进度 + 空状态 + 底部状态栏。
struct BrowserPane: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏常驻：既展示当前分组/筛选状态，也让这一列顶部始终有固定内容
            BrowserHeaderBar()

            if store.isImporting {
                ImportProgressBanner()
                Divider()
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

            // 状态栏作为普通子视图，而不是 safeAreaInset：
            // safeAreaInset 会改写这一列的安全区，拖动分栏时容易和分栏的安全区计算打架。
            StatusBarView(items: store.filteredItems)
        }
    }
}

/// 中间列固定顶栏：显示当前分组名 + 搜索/筛选状态 + 条目数。
/// 常驻，既展示状态，也让这一列顶部始终有固定内容（分栏竖线就不会往上穿透）。
private struct BrowserHeaderBar: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Text(store.titleForSelection)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                if !store.searchText.isEmpty {
                    Image(systemName: "magnifyingglass")
                }
                if store.activeFilterCount > 0 {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            Spacer(minLength: 8)

            Text("\(store.filteredItems.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
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

/// 窗口层的两处兜底，用 AppKit 直接处理（SwiftUI 没有对应 API）。
///
/// 1. 标题栏下方的横线固定常显：系统默认 `.automatic`，SwiftUI 每次布局都会按
///    「内容有没有滚到标题栏下面」重设一次，拖动分栏时会被改回隐藏，
///    横线一没就露出竖分隔线的顶端。
/// 2. 禁止分栏自动折叠：空间不够时 NSSplitView 会按 holdingPriority 折叠侧边栏，
///    这是「整个布局发生变化」的直接原因。
/// 3. 顶棚（shield）：一旦分栏 frame 顶进标题栏底下，就在越界的那一截上盖一条
///    不透明条，把贯穿上来的竖分隔线和跳上去的内容一起挡住。布局正常时高度算出来
///    是 0，完全隐形，不影响原生观感。
///
/// 这里用一个铺满窗口、不拦截鼠标的 NSView，在每个布局时机都重新钉一次。
private struct WindowChromeFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowFixView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowFixView)?.applyFixes()
    }
}

private final class WindowFixView: NSView {
    override var isOpaque: Bool { false }

    /// 不参与命中测试，避免挡住下面内容的鼠标事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private weak var split: NSSplitView?
    private var shield: ShieldView?
    private var frameObserver: NSObjectProtocol?

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFixes()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyFixes()
    }

    override func layout() {
        super.layout()
        applyFixes()
    }

    func applyFixes() {
        guard let window else { return }

        if window.titlebarSeparatorStyle != .line {
            window.titlebarSeparatorStyle = .line
        }

        if let controller = Self.findSplitViewController(in: window.contentViewController) {
            for item in controller.splitViewItems where item.canCollapse {
                item.canCollapse = false
            }
        }

        guard let split = Self.findSplitView(in: window.contentView) else { return }
        if self.split !== split {
            self.split = split
            installShield(for: split)
        }
        updateShield()
    }

    // MARK: - 顶棚

    private func installShield(for split: NSSplitView) {
        guard let superview = split.superview else { return }
        let shield = ShieldView(frame: .zero)
        superview.addSubview(shield, positioned: .above, relativeTo: split)
        self.shield = shield

        // 分栏 frame 一变就重算顶棚（坐标统一换算到窗口坐标系，不受视图是否翻转影响）
        split.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: split,
            queue: .main
        ) { [weak self] _ in
            self?.updateShield()
        }
    }

    private func updateShield() {
        guard let window,
              let contentView = window.contentView,
              let split,
              let shield,
              split.superview != nil else { return }

        let splitFrame = split.convert(split.bounds, to: nil)
        let layoutFrame = contentView.convert(window.contentLayoutRect, to: nil)

        // 分栏顶边高出「工具栏下沿」的那一截，就是需要盖住的部分
        let overflow = max(0, splitFrame.maxY - layoutFrame.maxY)
        guard overflow > 0.5 else {
            shield.isHidden = true
            shield.frame = .zero
            return
        }

        let windowRect = NSRect(x: splitFrame.minX, y: layoutFrame.maxY,
                                width: splitFrame.width, height: overflow)
        shield.frame = shield.superview?.convert(windowRect, from: nil) ?? .zero
        shield.isHidden = false
    }

    // MARK: - 查找分栏

    private static func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = findSplitView(in: subview) { return found }
        }
        return nil
    }

    private static func findSplitViewController(in controller: NSViewController?) -> NSSplitViewController? {
        guard let controller else { return nil }
        if let split = controller as? NSSplitViewController { return split }
        for child in controller.children {
            if let found = findSplitViewController(in: child) { return found }
        }
        return nil
    }
}

/// 顶棚：不透明、不拦鼠标，只用来盖住分栏越界的那一截。
private final class ShieldView: NSView {
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

struct StatusBarView: View {
    let items: [DMGItem]

    var body: some View {
        HStack(spacing: 12) {
            Text("总大小 \(ByteFormatter.string(fromBytes: items.reduce(0) { $0 + $1.fileSize }))")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
