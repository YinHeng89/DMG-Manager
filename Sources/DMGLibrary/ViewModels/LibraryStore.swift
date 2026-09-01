import Foundation
import AppKit

/// 侧边栏当前选中的目标。
enum SidebarSelection: Hashable {
    case smart(SmartList)
    case category(String)
    case tag(String)
}

/// 高级筛选条件。
struct FilterCriteria {
    var architectures: Set<Architecture> = []
    var installStatuses: Set<String> = []
    var parseStatuses: Set<ParseStatus> = []
    var categories: Set<String> = []
    var requireTags: Set<String> = []

    var isEmpty: Bool {
        architectures.isEmpty && installStatuses.isEmpty && parseStatuses.isEmpty
        && categories.isEmpty && requireTags.isEmpty
    }
}

/// 整个应用的单一数据源。所有 UI 都通过它读写，保证「单一真相源」。
@MainActor
@Observable
final class LibraryStore {
    // MARK: - 数据

    private(set) var items: [DMGItem] = []
    /// 文件存在性快照：UI 据它判断「文件失联」，而非直接读 `item.exists`。
    /// `exists` 是 computed，外部增删文件不会触发 Observation 重绘，必须靠这个被追踪的属性主动推变化。
    private(set) var presence: [Int64: Bool] = [:]
    private(set) var tagCounts: [(name: String, count: Int)] = []
    private(set) var categoryCounts: [(name: String, count: Int)] = []
    private(set) var customCategories: [String] = []

    // MARK: - 导入状态

    enum ImportStage: String {
        case adding
        case parsing
    }

    var isImporting = false
    var importStage: ImportStage = .adding
    var importCompleted = 0
    var importTotal = 0
    var importStatusMessage = ""
    var errorMessage: String?

    /// 上次启动后自动扫库的结果，供 UI 提示。扫完会自动清空。
    var lastScanResult: ScanOutcome?

    // MARK: - 视图状态

    // 这几个都会影响 filteredItems，一改就让缓存失效。
    // selectedItemID 不在其中：选中哪一条不改变列表内容。
    var selection: SidebarSelection = .smart(.all) { didSet { invalidateDerivedState() } }
    var selectedItemID: Int64?
    var searchText = "" { didSet { invalidateDerivedState() } }
    var browseMode: BrowseMode = .list
    var sortField: SortField = .addedAt { didSet { invalidateDerivedState() } }
    var sortAscending = false { didSet { invalidateDerivedState() } }
    var filters = FilterCriteria() { didSet { invalidateDerivedState() } }
    var watchDirectories: [URL] = []
    var mountedVolumes: [Int64: URL] = [:]

    // MARK: - 派生数据缓存

    /// `filteredItems` 的缓存。过滤 + 排序每次访问都要全量重算（比较器用 localizedCompare，
    /// 比普通字符串比较贵一个量级），而一次渲染会被访问三四次（isEmpty / count / ForEach），
    /// 不缓存会白白重复计算。
    ///
    /// 放在这里而不是过滤逻辑所在的 LibraryFiltering.swift，是因为 Swift 不允许在
    /// extension 里写存储属性。
    var filteredItemsCache: [DMGItem]?
    var filteredItemsDirty = true

    /// `displayedItems` 的缓存，同一渲染周期会被访问多次。
    var displayedItemsCache: [DMGItem]?
    var displayedItemsDirty = true

    /// groupingKey → 该软件的全部版本（已按「最新优先」排好序）。
    ///
    /// 一次 O(n) 建好之后，版本库、代表项选取、版本计数、选中态判定全都变成 O(1) 查表。
    /// 之前 `relatedVersions(for:)` 是按 item.id 各缓存一份，每选中一个新条目都要对全量
    /// items 重新扫一遍并排序——选中切换一多就是 N 次 O(n log n)。
    /// 和 `filteredItemsCache` 一样放在主类型里（extension 不能写存储属性），
    /// 读它的是 LibraryFiltering.swift 里的分组逻辑，所以不能是 private。
    var groupIndexCache: [String: [DMGItem]]?

    /// `duplicateGroups()` 的缓存。侧边栏每次 body 都要问一次重复数，
    /// 不缓存等于每次重绘都重扫全表。
    var duplicateGroupsCache: [[DMGItem]]?

    /// 所有派生缓存的统一失效点：items 变了、或者任何影响列表的输入变了都要走这里。
    private func invalidateDerivedState() {
        filteredItemsDirty = true
        filteredItemsCache = nil
        displayedItemsDirty = true
        displayedItemsCache = nil
        groupIndexCache = nil
        duplicateGroupsCache = nil
    }

    let database: Database
    private let repository: ItemRepository
    private let settings: SettingsStore

    init() throws {
        AppPaths.ensureDirectories()
        BackupService.snapshot(database: AppPaths.database)
        self.database = try Database(fileURL: AppPaths.database)
        try Schema.migrate(database: database)
        self.repository = ItemRepository(database: database)
        self.settings = SettingsStore(database: database)
        reload()
        repository.pruneOrphanTags() // 启动时清掉历史遗留的无引用标签
        loadSettings()
    }

    // MARK: - 读取

    func reload() {
        items = (try? repository.fetchAll()) ?? []
        invalidateDerivedState()
        tagCounts = (try? repository.tagCounts()) ?? []
        categoryCounts = (try? repository.categoryCounts()) ?? []
        customCategories = (try? repository.customCategories()) ?? []
    }

    private func loadSettings() {
        if let raw = settings.string(for: SettingsKey.watchDirectories), !raw.isEmpty {
            watchDirectories = Self.decodeDirectories(raw)
            dedupeWatchDirectories() // 清理历史遗留的重复目录
        }
        if let raw = settings.string(for: SettingsKey.browseMode), let mode = BrowseMode(rawValue: raw) {
            browseMode = mode
        }
    }

    func saveSettings() {
        settings.set(Self.encodeDirectories(watchDirectories), for: SettingsKey.watchDirectories)
        settings.set(browseMode.rawValue, for: SettingsKey.browseMode)
    }

    enum SettingsKey {
        static let watchDirectories = "watchDirectories"
        static let browseMode = "browseMode"
    }

    // MARK: - 扫描目录

    /// 目录比较键。解析符号链接并抹平尾斜杠，让 `/a/Downloads`、`/a/Downloads/`、
    /// 以及指向同一处的 `/System/Volumes/Data/...` 都算作同一个目录。
    /// 不去重的话同一个目录会被加进来多次：重复扫描，还会让 `ForEach` 拿到重复 id。
    private static func directoryKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 便宜的路径归一化（不碰磁盘），用于逐条比对，避免上千次 I/O。
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 路径理论上允许含换行符，`\n` 拼接读回来会被拆成两条，所以改用 JSON 数组。
    private static func encodeDirectories(_ urls: [URL]) -> String {
        let paths = urls.map(\.path)
        guard let data = try? JSONEncoder().encode(paths),
              let json = String(data: data, encoding: .utf8) else {
            return paths.joined(separator: "\n") // 编码失败时退回旧格式
        }
        return json
    }

    /// 读取时兼容旧的换行分隔格式，老数据不会丢。
    private static func decodeDirectories(_ raw: String) -> [URL] {
        if let data = raw.data(using: .utf8),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// 添加扫描目录；已存在同义目录时静默忽略。
    func addWatchDirectory(_ url: URL) {
        let key = Self.directoryKey(url)
        guard !watchDirectories.contains(where: { Self.directoryKey($0) == key }) else { return }
        watchDirectories.append(url)
        saveSettings()
    }

    /// 移除扫描目录。只影响以后是否扫描它，**不会删除已入库的条目**。
    func removeWatchDirectory(_ url: URL) {
        let key = Self.directoryKey(url)
        watchDirectories.removeAll { Self.directoryKey($0) == key }
        saveSettings()
    }

    private func dedupeWatchDirectories() {
        var seen = Set<String>()
        var unique: [URL] = []
        for directory in watchDirectories where seen.insert(Self.directoryKey(directory)).inserted {
            unique.append(directory)
        }
        guard unique.count != watchDirectories.count else { return }
        watchDirectories = unique
        saveSettings()
    }

    /// 该目录下已入库的条目数。
    func itemCount(in directory: URL) -> Int {
        let prefix = Self.normalizedPath(directory.path)
        return items.filter { item in
            let path = Self.normalizedPath(item.path)
            return path == prefix || path.hasPrefix(prefix + "/")
        }.count
    }

    /// 目录当前是否还在（被删除或移动过就是 false）。
    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    var allCategories: [String] {
        let merged = Set(CategoryPresets.builtin + categoryCounts.map(\.name) + customCategories)
        return merged.sorted { lhs, rhs in
            if lhs == CategoryPresets.uncategorized { return false }
            if rhs == CategoryPresets.uncategorized { return true }
            return lhs.localizedCompare(rhs) == .orderedAscending
        }
    }

    func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !allCategories.contains(trimmed) else { return }
        do {
            try repository.addCategory(trimmed)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        customCategories = (try? repository.customCategories()) ?? []
    }

    /// 该分类当前是否正被至少一个条目使用。
    func isCategoryInUse(_ name: String) -> Bool {
        categoryCounts.contains { $0.name == name && $0.count > 0 }
    }

    /// 分类能否删除：内置预设不可删；正被使用的不可删（和标签「还有人引用就留着」同理，
    /// 删掉会让条目失去分类）。
    func canDeleteCategory(_ name: String) -> Bool {
        guard !CategoryPresets.builtin.contains(name) else { return false }
        return !isCategoryInUse(name)
    }

    /// 删除一个未使用的自建分类。使用中的会被 `canDeleteCategory` 拦下。
    func deleteCategory(_ name: String) {
        guard canDeleteCategory(name) else { return }
        do {
            try repository.deleteCategory(name)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        customCategories = (try? repository.customCategories()) ?? []
    }

    // MARK: - 导入

    /// 返回真正新入库的条目数（已经导入过的不算）。
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Int {
        let dmgURLs = urls.filter { $0.pathExtension.lowercased() == "dmg" }
        guard !dmgURLs.isEmpty else {
            errorMessage = "没有可导入的 .dmg 文件"
            return 0
        }

        // 串行保护：两个导入并发跑会互相踩 isImporting / importTotal / importCompleted，
        // 先结束的那个会把进度条提前关掉，数字也会乱跳。
        guard !isImporting else {
            errorMessage = "已有导入或扫描在进行中"
            return 0
        }

        isImporting = true
        defer {
            isImporting = false
            importStatusMessage = ""
        }

        // 阶段 1：快速入库（只读文件属性，不挂载）
        importStage = .adding
        importCompleted = 0
        importTotal = dmgURLs.count
        var addedIDs: [Int64] = []

        for url in dmgURLs {
            importStatusMessage = url.lastPathComponent
            if let item = await addPlaceholder(url) {
                addedIDs.append(item.id)
            }
            importCompleted += 1
        }

        guard !addedIDs.isEmpty else {
            reload()
            return 0
        }

        // 阶段 2：逐个挂载解析
        importStage = .parsing
        importCompleted = 0
        importTotal = addedIDs.count

        for id in addedIDs {
            await parseOne(id: id)
            importCompleted += 1
        }

        reload()
        await computeMissingHashes()
        return addedIDs.count
    }

    /// 只把文件信息写入库，状态为 pending，不触发挂载解析。
    private func addPlaceholder(_ url: URL) async -> DMGItem? {
        if (try? repository.itemID(forPath: url.path)) != nil {
            return nil // 已经导入过
        }

        let facts = FileFactsReader.read(url: url)
        var item = DMGItem(
            path: url.path,
            filename: url.lastPathComponent,
            displayName: url.lastPathComponent.guessedAppName,
            category: SmartCategorizer.category(for: url.lastPathComponent),
            fileSize: facts.size,
            fileCreatedAt: facts.createdAt,
            fileModifiedAt: facts.modifiedAt,
            parseStatus: .pending,
            createdAt: Date(),
            updatedAt: Date()
        )

        do {
            try repository.insert(&item)
        } catch {
            return nil
        }
        items.append(item)
        invalidateDerivedState()
        return item
    }

    /// 解析单个条目：pending → parsing → parsed / noApp / failed / missing。
    private func parseOne(id: Int64) async {
        guard var item = item(id: id) else { return }
        // 之前标记过 .missing 但文件回来了：当作 pending 重新解析，清掉失联状态（自愈）。
        let recoverable = item.parseStatus == .missing && item.exists
        guard item.parseStatus == .pending || item.parseStatus == .parsed || recoverable else {
            return
        }
        guard item.exists else {
            item.parseStatus = .missing
            item.parseError = "原始文件已不存在"
            save(item)
            return
        }

        item.parseStatus = .parsing
        item.parseError = nil
        importStatusMessage = item.filename
        try? repository.update(item)
        upsert(item)

        let url = item.fileURL
        let iconName = UUID().uuidString
        let result = await Task.detached(priority: .utility) {
            DMGInspectionService.inspect(fileURL: url, iconName: iconName)
        }.value
        IconStore.shared.delete(named: item.iconFilename)
        DMGInspectionService.apply(result, to: &item)
        item.iconFilename = result.iconFilename

        if let appName = result.appInfo?.name, !appName.isEmpty {
            item.displayName = appName
        }
        if item.category == CategoryPresets.uncategorized, let appName = item.appName {
            item.category = SmartCategorizer.category(for: appName)
        }

        await resolveInstallStatus(for: &item)
        item.updatedAt = Date()
        try? repository.update(item)
        upsert(item)
    }

    /// 一次目录扫描的结果。区分「扫到多少」和「新增多少」——
    /// 已经入库的文件会被跳过，两个数通常不一样。
    struct ScanOutcome: Sendable {
        let scanned: Int
        let added: Int
        /// 目录里的 .dmg 超过上限，没扫全。
        let truncated: Bool
    }

    /// 扫描文件夹内的所有 DMG 并导入。
    ///
    /// 目录枚举放在后台线程：它是同步递归遍历整棵目录树，
    /// 放在主线程（本类整体是 @MainActor）会一路卡住界面。
    @discardableResult
    func scanFolder(_ folder: URL) async -> ScanOutcome {
        guard !isImporting else {
            return ScanOutcome(scanned: 0, added: 0, truncated: false)
        }

        let result = await Task.detached(priority: .utility) {
            DMGScanner.scan(url: folder)
        }.value

        addWatchDirectory(folder)

        // 一个都没有时不要走 importFiles，否则会弹「没有可导入的 .dmg 文件」这种误导性提示。
        guard !result.urls.isEmpty else {
            return ScanOutcome(scanned: 0, added: 0, truncated: result.truncated)
        }

        let added = await importFiles(result.urls)
        return ScanOutcome(scanned: result.urls.count, added: added, truncated: result.truncated)
    }

    /// 依次扫描所有目录并汇总。期间 `isImporting` 为 true，可用来禁用按钮。
    @discardableResult
    func scanAllWatchDirectories() async -> ScanOutcome {
        var scanned = 0
        var added = 0
        var truncated = false
        // 快照一份再遍历：addWatchDirectory 可能改动数组，避免边遍历边改。
        for directory in watchDirectories {
            let outcome = await scanFolder(directory)
            scanned += outcome.scanned
            added += outcome.added
            truncated = truncated || outcome.truncated
        }
        return ScanOutcome(scanned: scanned, added: added, truncated: truncated)
    }

    /// 启动后自动扫库：在后台进行，不阻塞首屏。
    ///
    /// - 没有监控目录时直接返回，避免无谓扫描。
    /// - 已有文件按路径与数据库比对（`addPlaceholder` 会查 `itemID(forPath:)`，
    ///   已入库的直接跳过），**仅新增真正的新 DMG**，不会重复导入。
    /// - 扫完把结果写入 `lastScanResult`，由 UI 弹出提示，几秒后自动清空。
    private var hasScannedOnLaunch = false
    func scanWatchDirectoriesOnLaunch() async {
        guard !hasScannedOnLaunch else { return }
        hasScannedOnLaunch = true
        guard !watchDirectories.isEmpty else { return }

        let outcome = await scanAllWatchDirectories()
        guard outcome.scanned > 0 else { return }

        lastScanResult = outcome
        Task {
            try? await Task.sleep(for: .seconds(6))
            lastScanResult = nil
        }
    }

    // MARK: - 更新

    func save(_ item: DMGItem) {
        var updated = item
        updated.updatedAt = Date()
        do {
            try repository.update(updated)
            upsert(updated)
            reloadCounters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 只保存用户编辑的元数据，不动解析结果。
    func saveMetadata(_ item: DMGItem) {
        var updated = item
        updated.updatedAt = Date()
        do {
            try repository.updateMetadata(updated)
            upsert(updated)
            reloadCounters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(id: Int64) {
        guard var item = item(id: id) else { return }
        item.favorite.toggle()
        saveMetadata(item)
    }

    private func upsert(_ item: DMGItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        invalidateDerivedState()
    }

    private func reloadCounters() {
        tagCounts = (try? repository.tagCounts()) ?? []
        categoryCounts = (try? repository.categoryCounts()) ?? []
        customCategories = (try? repository.customCategories()) ?? []
    }

    func item(id: Int64) -> DMGItem? {
        items.first { $0.id == id }
    }

    // MARK: - 删除

    /// 从库中移除；trash 为 true 时同时把原始 DMG 移到废纸篓。
    func delete(ids: Set<Int64>, moveToTrash: Bool) {
        for id in ids {
            guard let item = item(id: id) else { continue }
            if moveToTrash {
                NSWorkspace.shared.recycle([item.fileURL]) { _, _ in }
            }
            IconStore.shared.delete(named: item.iconFilename)
            try? repository.delete(id: id)
            if let mounted = mountedVolumes.removeValue(forKey: id) {
                DiskImageService.detach(mountPoint: mounted)
            }
        }
        items.removeAll { ids.contains($0.id) }
        invalidateDerivedState()
        if let selectedItemID, ids.contains(selectedItemID) { self.selectedItemID = nil }
        reloadCounters()
    }

    // MARK: - 后台维护

    /// 重新解析选中的条目（例如之前解析失败或用户要求重试）。
    func reparse(ids: Set<Int64>) async {
        let targets = ids.compactMap { item(id: $0) }.filter { $0.parseStatus.isResolved || $0.parseStatus == .pending }
        guard !targets.isEmpty else { return }

        isImporting = true
        importStage = .parsing
        importTotal = targets.count
        importCompleted = 0
        defer {
            isImporting = false
            importStatusMessage = ""
        }

        for item in targets {
            var reset = item
            reset.parseStatus = .pending
            reset.parseError = nil
            try? repository.update(reset)
            upsert(reset)
        }

        for id in targets.map(\.id) {
            await parseOne(id: id)
            importCompleted += 1
        }

        reload()
        await computeMissingHashes()
    }

    /// 启动时的文件状态检查：失联的尝试自动重连。
    func refreshFileStatus() async {
        var relocatedCount = 0
        for item in items where !item.exists {
            let url = item.fileURL
            let roots = watchDirectories
            guard let candidate = await Task.detached(priority: .utility, operation: {
                FileLocator.locate(item: item, searchRoots: roots)
            }).value, candidate.url.path != url.path else {
                var updated = item
                updated.parseStatus = .missing
                save(updated)
                continue
            }
            var updated = item
            updated.path = candidate.url.path
            updated.filename = candidate.url.lastPathComponent
            let facts = FileFactsReader.read(url: candidate.url)
            updated.fileSize = facts.size
            updated.fileCreatedAt = facts.createdAt
            updated.fileModifiedAt = facts.modifiedAt
            updated.parseStatus = .pending
            updated.parseError = nil
            save(updated)
            relocatedCount += 1
        }

        if relocatedCount > 0 {
            await reparse(ids: Set(items.filter { $0.parseStatus == .pending }.map(\.id)))
        }
    }

    /// 重新采样每个条目在磁盘上的存在性，写入 `presence`。
    /// 解决「外部删除/恢复文件后界面不重绘」的问题：`exists` 是 computed，不触发 Observation，
    /// 必须靠这个被追踪的属性把变化推出去。仅在存在性实际变化时更新并失效派生缓存，避免无谓重绘。
    func refreshPresence() {
        var next: [Int64: Bool] = [:]
        for item in items { next[item.id] = item.exists }
        guard next != presence else { return }
        presence = next
        invalidateDerivedState()
    }

    /// 刷新所有条目的安装状态。
    func refreshInstallStatus() async {
        var updatedItems: [DMGItem] = []
        for item in items {
            var updated = item
            await resolveInstallStatus(for: &updated)
            if updated.installedVersion != item.installedVersion || updated.installedPath != item.installedPath {
                try? repository.update(updated)
                updatedItems.append(updated)
            }
        }
        for updated in updatedItems { upsert(updated) }
    }

    private func resolveInstallStatus(for item: inout DMGItem) async {
        let bundleID = item.bundleID
        let appName = item.appName
        let resolved = await Task.detached(priority: .utility) {
            InstalledAppService.shared.resolve(bundleID: bundleID, appName: appName)
        }.value
        item.installedVersion = resolved.version
        item.installedPath = resolved.path
    }

    /// 后台补算缺失的 SHA-256，用于重复检测与失联重连。
    func computeMissingHashes() async {
        let targets = items.filter { ($0.sha256?.isEmpty ?? true) && $0.exists }
        guard !targets.isEmpty else { return }

        for target in targets {
            let url = target.fileURL
            guard let hash = await Task.detached(priority: .background, operation: {
                try? SHA256Service.hash(fileAt: url)
            }).value else { continue }

            var updated = target
            updated.sha256 = hash
            try? repository.update(updated)
            upsert(updated)
        }
    }

    /// 手动重定位：用户自己选择新文件。
    func relocate(id: Int64, to url: URL) {
        guard var item = item(id: id) else { return }
        let facts = FileFactsReader.read(url: url)
        item.path = url.path
        item.filename = url.lastPathComponent
        item.fileSize = facts.size
        item.fileCreatedAt = facts.createdAt
        item.fileModifiedAt = facts.modifiedAt
        item.parseStatus = .pending
        item.parseError = nil
        save(item)
        Task { await reparse(ids: [id]) }
    }

    // MARK: - 文件操作

    func revealInFinder(_ item: DMGItem) {
        guard item.exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    /// 打开 DMG（系统会挂载并弹出 Finder 窗口）。
    func open(_ item: DMGItem) {
        guard item.exists else { return }
        NSWorkspace.shared.open(item.fileURL)
        repository.touchLastOpened(id: item.id)
        if var updated = self.item(id: item.id) {
            updated.lastOpenedAt = Date()
            upsert(updated)
        }
    }

    /// 静默挂载（不弹窗口），之后可一键卸载。
    ///
    /// hdiutil 需要 1~3 秒，放到后台跑，避免卡住界面。
    func mount(_ item: DMGItem) async {
        guard item.exists, mountedVolumes[item.id] == nil else { return }
        let url = item.fileURL
        let itemID = item.id

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try DiskImageService.attach(imageURL: url)
            }.value
            mountedVolumes[itemID] = volume.mountPoint
            if var updated = self.item(id: itemID) {
                updated.volumeName = volume.volumeName ?? updated.volumeName
                upsert(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmount(_ item: DMGItem) {
        guard let mountPoint = mountedVolumes.removeValue(forKey: item.id) else { return }
        DiskImageService.detach(mountPoint: mountPoint)
    }

    func revealMountedVolume(_ item: DMGItem) {
        guard let mountPoint = mountedVolumes[item.id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([mountPoint])
    }

    /// 把 DMG 内的 App 拖到 /Applications —— 由用户显式触发，且只在确认后执行。
    func installApp(_ item: DMGItem) async throws {
        guard let relativePath = item.appRelativePath, item.exists else { return }
        let volume = try DiskImageService.attach(imageURL: item.fileURL)
        defer {
            if mountedVolumes[item.id] == nil {
                DiskImageService.detach(mountPoint: volume.mountPoint)
            }
        }
        let appURL = volume.mountPoint.appendingPathComponent(relativePath)
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(appURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.copyItem(at: appURL, to: destination)

        // 刚装好的 App 还没进 InstalledAppService 的缓存：先强制重新扫描，
        // 否则 resolve 扫不到 → installedVersion 仍是 nil → 安装状态徽章不刷新。
        InstalledAppService.shared.rebuild()

        var updated = item
        await resolveInstallStatus(for: &updated)
        save(updated)
    }

    func copyPath(_ item: DMGItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    // MARK: - 版本库

    /// 同一个软件的其他版本（按 Bundle ID / 名称聚合），按「最新优先」排序。
    /// 走 `versionGroups` 索引，O(1) 查表。
    func relatedVersions(for item: DMGItem) -> [DMGItem] {
        versionGroup(for: item).filter { $0.id != item.id }
    }

    /// 重复文件分组（按 SHA-256）。
    ///
    /// 只保留成员数 > 1 的组；组内按路径排，组之间按文件名排。带缓存，
    /// 侧边栏每次重绘都要问一次重复数，不缓存等于每次都重扫全表。
    func duplicateGroups() -> [[DMGItem]] {
        if let cached = duplicateGroupsCache { return cached }

        var groups: [String: [DMGItem]] = [:]
        for item in items {
            guard let hash = item.sha256, !hash.isEmpty else { continue }
            groups[hash, default: []].append(item)
        }

        let result = groups.values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.path < $1.path } }
            .sorted {
                let lhs = $0.first?.filename ?? ""
                let rhs = $1.first?.filename ?? ""
                // 同名不同路径时再比路径，否则同名的两组顺序会随字典遍历顺序抖动
                if lhs != rhs { return lhs < rhs }
                return ($0.first?.path ?? "") < ($1.first?.path ?? "")
            }
        duplicateGroupsCache = result
        return result
    }
}
