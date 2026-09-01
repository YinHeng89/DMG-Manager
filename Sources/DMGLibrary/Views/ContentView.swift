import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

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
            prompt: Text(prefs.t("search.prompt"))
        )
        .sheet(isPresented: $showFilters) { FilterPanelView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog(
            prefs.t("remove.fromLibrary.title"),
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            presenting: pendingDeletion
        ) { ids in
            Button(prefs.t("remove.onlyMeta"), role: .destructive) {
                store.delete(ids: ids, moveToTrash: false)
                pendingDeletion = []
            }
            Button(prefs.t("remove.toTrash"), role: .destructive) {
                store.delete(ids: ids, moveToTrash: true)
                pendingDeletion = []
            }
            Button(prefs.t("remove.cancel"), role: .cancel) { pendingDeletion = [] }
        } message: { _ in
            Text(prefs.t("remove.message"))
        }
        .alert(prefs.t("alert.error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(prefs.t("alert.ok")) { errorMessage = nil }
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

    }

    // MARK: - 文件选择（NSOpenPanel 比 SwiftUI fileImporter 稳定）

    /// 弹出系统文件选择器，批量添加 DMG。
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.dmg]
        panel.message = prefs.t("panel.add.message")
        panel.prompt = prefs.t("panel.add.prompt")
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
        panel.message = prefs.t("panel.scan.message")
        panel.prompt = prefs.t("panel.scan.prompt")
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
                Label(prefs.t("tb.add"), systemImage: "plus")
            }
            .help(prefs.t("tb.add.help"))
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    presentScanPanel()
                } label: {
                    Label(prefs.t("tb.scanFolder"), systemImage: "folder.badge.magnifyingglass")
                }
                Button {
                    Task { await store.scanAllWatchDirectories() }
                } label: {
                    Label(prefs.t("tb.scanAll"), systemImage: "arrow.clockwise")
                }
                .disabled(store.watchDirectories.isEmpty)
                Button {
                    // 用 filteredItems 而不是 displayedItems：列表折叠掉的旧版本也要一起重解析，
                    // 否则它们永远停在旧的解析结果上（而且不会再被扫到）。
                    Task { await store.reparse(ids: Set(store.filteredItems.map(\.id))) }
                } label: {
                    Label(prefs.t("tb.reparseList"), systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await store.refreshInstallStatus() }
                } label: {
                    Label(prefs.t("tb.refreshInstall"), systemImage: "checkmark.circle")
                }
                Button {
                    Task { await store.computeMissingHashes() }
                } label: {
                    Label(prefs.t("tb.fillHashes"), systemImage: "number")
                }
            } label: {
                Label(prefs.t("tb.more"), systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showFilters.toggle()
            } label: {
                Label(prefs.t("tb.filter"), systemImage: store.activeFilterCount == 0
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .help(prefs.t("tb.filter.help"))
        }

        ToolbarItem(placement: .primaryAction) {
            Picker(prefs.t("tb.view"), selection: Binding(
                get: { store.browseMode },
                set: { store.browseMode = $0; store.saveSettings() }
            )) {
                ForEach(BrowseMode.allCases) { mode in
                    Image(systemName: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(prefs.t("tb.view.help"))
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
                    Text(prefs.t("drop.release"))
                        .font(.title3.weight(.medium))
                    Text(prefs.t("drop.hint"))
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
                errorMessage = prefs.t("drop.onlyDmg")
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

            if let scan = store.lastScanResult, scan.scanned > 0 {
                ScanResultBanner(result: scan)
                Divider()
            }

            if store.displayedItems.isEmpty {
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
            //
            // 统计跟着「看到的」走：列表折叠了旧版本，总大小就算折叠后的，
            // 否则用户看到的条目数和总大小对不上。
            StatusBarView(items: store.displayedItems)
        }
    }
}

/// 中间列固定顶栏：显示当前分组名 + 搜索/筛选状态 + 条目数。
/// 常驻，既展示状态，也让这一列顶部始终有固定内容（分栏竖线就不会往上穿透）。
private struct BrowserHeaderBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

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

            // 折叠掉的旧版本不算进条目数，另给一句说明，免得用户以为它们被删了
            if store.collapsedVersionCount > 0 {
                Text(prefs.t("browser.collapsed", store.collapsedVersionCount))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(prefs.t("browser.itemCount", store.displayedItems.count))
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
    @Environment(Preferences.self) private var prefs

    private var stageTitle: String {
        switch store.importStage {
        case .adding: return prefs.t("import.adding")
        case .parsing: return prefs.t("import.parsing")
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

/// 启动后自动扫库的结果提示：扫到多少、新增多少，6 秒后由 store 自动清空。
struct ScanResultBanner: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs
    let result: LibraryStore.ScanOutcome

    private var message: String {
        if result.added > 0 {
            return prefs.t("scan.doneAdded", result.added, result.scanned)
        }
        return prefs.t("scan.doneLatest", result.scanned)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.added > 0 ? "checkmark.circle.fill" : "magnifyingglass")
                .font(.callout)
                .foregroundStyle(result.added > 0 ? .green : .secondary)
            Text(message)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button {
                store.lastScanResult = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button(prefs.t("tb.add")) {
                NotificationCenter.default.post(name: .libraryAddFiles, object: nil)
            }
            Button(prefs.t("tb.scanFolder")) {
                NotificationCenter.default.post(name: .libraryScanFolder, object: nil)
            }
        }
    }

    private var emptyTitle: String {
        if !store.searchText.isEmpty { return prefs.t("empty.noMatch") }
        switch store.selection {
        case .smart(.favorites): return prefs.t("empty.noFavorites")
        case .smart(.missing): return prefs.t("empty.noMissing")
        case .smart(.duplicates): return prefs.t("empty.noDuplicates")
        case .smart(.recentlyUsed): return prefs.t("empty.noRecent")
        default: return prefs.t("empty.empty")
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
            return prefs.t("empty.noMatch.hint")
        }
        return prefs.t("empty.addHint")
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
    private weak var splitController: NSSplitViewController?
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

        // 全窗口视图树递归遍历很贵（三栏 + 详情编辑器有上千个 NSView），而分栏对象一旦
        // 找到就不会变。所以只在还没找到时遍历一次，之后都复用缓存——否则每次 SwiftUI
        // 重绘（也就是每次点击选中）和每次布局都要遍历整棵树，点击就会明显延迟。
        if self.split == nil {
            splitController = Self.findSplitViewController(in: window.contentViewController)
            split = Self.findSplitView(in: window.contentView)
            if let split { installShield(for: split) }
        }

        if let controller = splitController {
            for item in controller.splitViewItems where item.canCollapse {
                item.canCollapse = false
            }
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
    @Environment(Preferences.self) private var prefs

    var body: some View {
        HStack(spacing: 12) {
            Text(prefs.t("statusbar.totalSize", ByteFormatter.string(fromBytes: items.reduce(0) { $0 + $1.fileSize })))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
