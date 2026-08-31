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

    // MARK: - 视图状态

    var selection: SidebarSelection = .smart(.all)
    var selectedItemID: Int64?
    var searchText = ""
    var browseMode: BrowseMode = .list
    var sortField: SortField = .addedAt
    var sortAscending = false
    var filters = FilterCriteria()
    var watchDirectories: [URL] = []
    var mountedVolumes: [Int64: URL] = [:]

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
        tagCounts = (try? repository.tagCounts()) ?? []
        categoryCounts = (try? repository.categoryCounts()) ?? []
        let builtin = Set(CategoryPresets.builtin)
        customCategories = categoryCounts.map(\.name).filter { !builtin.contains($0) }
    }

    private func loadSettings() {
        if let raw = settings.string(for: SettingsKey.watchDirectories), !raw.isEmpty {
            watchDirectories = raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        if let raw = settings.string(for: SettingsKey.browseMode), let mode = BrowseMode(rawValue: raw) {
            browseMode = mode
        }
    }

    func saveSettings() {
        settings.set(watchDirectories.map(\.path).joined(separator: "\n"), for: SettingsKey.watchDirectories)
        settings.set(browseMode.rawValue, for: SettingsKey.browseMode)
    }

    enum SettingsKey {
        static let watchDirectories = "watchDirectories"
        static let browseMode = "browseMode"
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
        customCategories.append(trimmed)
    }

    // MARK: - 导入

    func importFiles(_ urls: [URL]) async {
        let dmgURLs = urls.filter { $0.pathExtension.lowercased() == "dmg" }
        guard !dmgURLs.isEmpty else {
            errorMessage = "没有可导入的 .dmg 文件"
            return
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
            return
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
        return item
    }

    /// 解析单个条目：pending → parsing → parsed / noApp / failed / missing。
    private func parseOne(id: Int64) async {
        guard var item = item(id: id), item.parseStatus == .pending || item.parseStatus == .parsed else {
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

    /// 扫描文件夹内的所有 DMG。
    func scanFolder(_ folder: URL) async -> Int {
        let urls = DMGScanner.scan(url: folder)
        await importFiles(urls)
        if !watchDirectories.contains(folder) {
            watchDirectories.append(folder)
            saveSettings()
        }
        return urls.count
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
    }

    private func reloadCounters() {
        tagCounts = (try? repository.tagCounts()) ?? []
        categoryCounts = (try? repository.categoryCounts()) ?? []
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

        var updated = item
        await resolveInstallStatus(for: &updated)
        save(updated)
    }

    func copyPath(_ item: DMGItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    // MARK: - 版本库

    /// 同一个软件的其他版本（按 Bundle ID / 名称聚合）。
    func relatedVersions(for item: DMGItem) -> [DMGItem] {
        let key = item.groupingKey
        return items
            .filter { $0.groupingKey == key && $0.id != item.id }
            .sorted { lhs, rhs in
                VersionComparator.compare(lhs.version ?? "", rhs.version ?? "") == .orderedDescending
            }
    }

    /// 重复文件分组（按 SHA-256）。
    func duplicateGroups() -> [[DMGItem]] {
        var groups: [String: [DMGItem]] = [:]
        for item in items {
            guard let hash = item.sha256, !hash.isEmpty else { continue }
            groups[hash, default: []].append(item)
        }
        return groups.values.filter { $0.count > 1 }
            .map { $0.sorted { $0.path < $1.path } }
            .sorted { ($0.first?.filename ?? "") < ($1.first?.filename ?? "") }
    }
}
