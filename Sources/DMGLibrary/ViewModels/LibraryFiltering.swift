import Foundation

extension LibraryStore {
    /// 当前展示的条目：智能分组 → 搜索 → 高级筛选 → 排序。
    ///
    /// 带缓存：过滤 + 排序（比较器用 localizedCompare，比较贵）每次访问都要全量重算，
    /// 而一次渲染会被访问三四次（isEmpty / count / ForEach），不缓存会白白算好几遍。
    /// 仅在 items / selection / searchText / sortField / sortAscending / filters 变化时
    /// 由 invalidateDerivedState() 标记失效。
    ///
    /// 这是「筛选后的全部条目」——同软件的多个版本都在里面，用于重新解析、批量操作这类
    /// 需要覆盖全量的场合。**列表展示请用 `displayedItems`**，那里做了版本折叠。
    var filteredItems: [DMGItem] {
        if filteredItemsDirty {
            filteredItemsCache = computeFilteredItems()
            filteredItemsDirty = false
        }
        return filteredItemsCache ?? []
    }

    private func computeFilteredItems() -> [DMGItem] {
        var result = items

        switch selection {
        case .smart(let list):
            result = apply(smartList: list, to: result)
        case .category(let name):
            result = result.filter { $0.category == name }
        case .tag(let name):
            result = result.filter { $0.tags.contains(name) }
        }

        result = applySearch(to: result)
        result = applyFilters(to: result)
        return sort(result)
    }

    // MARK: - 版本折叠

    /// 列表真正渲染的条目：同一个软件（相同 groupingKey）只留一条代表项。
    ///
    /// 排序沿用 `filteredItems` 的结果，只是把「不是本组代表项」的剔掉，所以是 O(n)
    /// 而不是重新排一遍。剩下的版本不去数据库里删除，用户在详情的「版本库」里随时能切过去。
    var displayedItems: [DMGItem] {
        if displayedItemsDirty {
            displayedItemsCache = computeDisplayedItems()
            displayedItemsDirty = false
        }
        return displayedItemsCache ?? []
    }

    private func computeDisplayedItems() -> [DMGItem] {
        guard shouldCollapseVersions else { return filteredItems }
        let groups = versionGroups
        return filteredItems.filter { groups[$0.groupingKey]?.first?.id == $0.id }
    }

    /// 当前分组下要不要折叠同软件的多个版本。
    ///
    /// 「重复文件」和「文件失联」这两个列表存在的意义，恰恰是把每一份都摆出来——
    /// 折叠了就自相矛盾：内容相同的两份会合成一行，用户根本没法挑出要删的那份。
    private var shouldCollapseVersions: Bool {
        switch selection {
        case .smart(.duplicates), .smart(.missing): return false
        default: return true
        }
    }

    /// 因折叠而没显示出来的版本数，用于顶栏提示。
    var collapsedVersionCount: Int {
        guard shouldCollapseVersions else { return 0 }
        return filteredItems.count - displayedItems.count
    }

    /// 一个软件的全部版本，按「最新优先」排序。版本库和代表项选取共用这份索引。
    func versionGroup(for item: DMGItem) -> [DMGItem] {
        versionGroups[item.groupingKey] ?? [item]
    }

    /// 该软件一共有几个版本（含自己）。
    func versionCount(for item: DMGItem) -> Int {
        versionGroup(for: item).count
    }

    /// groupingKey → 该软件的全部版本（已排好序）。一次 O(n) 建好，之后全是 O(1) 查表。
    var versionGroups: [String: [DMGItem]] {
        if let cached = groupIndexCache { return cached }

        var grouped: [String: [DMGItem]] = [:]
        for item in items { grouped[item.groupingKey, default: []].append(item) }

        // 用 mapValues 整体替换，而不是 `for key in grouped.keys { grouped[key]?.sort() }`——
        // 那样是「一边遍历字典一边改它」，触发写时复制时会直接崩（mutation during iteration）。
        let sorted = grouped.mapValues { $0.sorted(by: Self.isPreferredOver) }
        groupIndexCache = sorted
        return sorted
    }

    /// 「谁更适合当代表项」：版本号高的优先，其次文件还在的，最后新入库的。
    ///
    /// 版本比较用 VersionComparator（139.0 > 138.0，1.0 > 1.0-beta）；都没版本号时
    /// 按入库时间倒序。这里刻意不用 `item.exists`——它会走 FileManager 查磁盘，
    /// 在排序比较器里调用就是 O(n log n) 次 I/O，改用已经缓存在内存里的解析状态作代理。
    private static func isPreferredOver(_ lhs: DMGItem, _ rhs: DMGItem) -> Bool {
        switch (lhs.version, rhs.version) {
        case (let left?, let right?):
            switch VersionComparator.compare(left, right) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: break
            }
        case (_?, nil): return true   // 有版本号的优先于没解析出来的
        case (nil, _?): return false
        case (nil, nil): break
        }

        let lhsMissing = lhs.parseStatus == .missing
        let rhsMissing = rhs.parseStatus == .missing
        if lhsMissing != rhsMissing { return !lhsMissing }
        return lhs.createdAt > rhs.createdAt
    }

    /// 该条目所属软件的代表项 id（也就是列表里那一行的 id）。
    /// 只在点击这类交互里调用，每次 O(n) 的查找可以接受。
    func representativeID(for id: Int64) -> Int64? {
        guard let item = item(id: id) else { return nil }
        return versionGroups[item.groupingKey]?.first?.id
    }

    /// 当前选中项所属软件的 groupingKey。
    ///
    /// 列表判定高亮时按「组」比较而不是按 id：选中的是「这个软件」，从版本库切到旧版本后
    /// 列表里显示的仍是代表项（最新版），按 id 比的话高亮会凭空消失，看着像没选中。
    ///
    /// 调用方务必在 body 里用 `let` 接住再用（`let key = store.selectedGroupKey`）。
    /// 直接在 ForEach 闭包里访问会每行求值一次，而它内部要在 items 里线性查找，
    /// 整段就退化成 O(n²) 了。
    var selectedGroupKey: String? {
        guard let selectedItemID, let selected = item(id: selectedItemID) else { return nil }
        return selected.groupingKey
    }

    var selectedItem: DMGItem? {
        guard let selectedItemID else { return nil }
        return item(id: selectedItemID)
    }

    var titleForSelection: String {
        switch selection {
        case .smart(let list): return list.title
        case .category(let name): return name
        case .tag(let name): return "#" + name
        }
    }

    /// 侧边栏各分组的条目数。
    func count(for list: SmartList) -> Int {
        switch list {
        case .all: return items.count
        case .favorites: return items.filter(\.favorite).count
        case .recent:
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            return items.filter { $0.createdAt >= cutoff }.count
        case .recentlyUsed: return items.filter { $0.lastOpenedAt != nil }.count
        case .missing: return items.filter { !$0.exists }.count
        case .duplicates: return duplicateGroups().reduce(0) { $0 + $1.count }
        }
    }

    func count(forCategory name: String) -> Int {
        items.filter { $0.category == name }.count
    }

    func count(forTag name: String) -> Int {
        items.filter { $0.tags.contains(name) }.count
    }

    var activeFilterCount: Int {
        var count = 0
        if !filters.architectures.isEmpty { count += 1 }
        if !filters.installStatuses.isEmpty { count += 1 }
        if !filters.parseStatuses.isEmpty { count += 1 }
        if !filters.categories.isEmpty { count += 1 }
        if !filters.requireTags.isEmpty { count += 1 }
        return count
    }

    // MARK: - 智能分组

    private func apply(smartList: SmartList, to input: [DMGItem]) -> [DMGItem] {
        switch smartList {
        case .all:
            return input
        case .favorites:
            return input.filter { $0.favorite }
        case .recent:
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            return input.filter { $0.createdAt >= cutoff }
        case .recentlyUsed:
            return input.filter { $0.lastOpenedAt != nil }
        case .missing:
            return input.filter { !$0.exists }
        case .duplicates:
            // Set 而不是 Array：之前是 flatMap 成数组再 contains，每个条目都要线性扫一遍
            // 哈希清单，整段是 O(n²)。
            let hashes = Set(duplicateGroups().compactMap { $0.first?.sha256 })
            return input.filter { item in
                guard let hash = item.sha256 else { return false }
                return hashes.contains(hash)
            }
        }
    }

    // MARK: - 搜索

    private func applySearch(to input: [DMGItem]) -> [DMGItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return input }
        let terms = query.lowercased().split(separator: " ").map(String.init)

        return input.filter { item in
            // 多个关键词之间是「与」关系
            terms.allSatisfy { term in
                item.searchHaystack.contains(term)
            }
        }
    }

    // MARK: - 高级筛选

    private func applyFilters(to input: [DMGItem]) -> [DMGItem] {
        guard !filters.isEmpty else { return input }
        return input.filter { item in
            if !filters.architectures.isEmpty, !filters.architectures.contains(item.architecture) {
                return false
            }
            if !filters.parseStatuses.isEmpty, !filters.parseStatuses.contains(item.parseStatus) {
                return false
            }
            if !filters.categories.isEmpty, !filters.categories.contains(item.category) {
                return false
            }
            if !filters.requireTags.isEmpty, !Set(item.tags).isSuperset(of: filters.requireTags) {
                return false
            }
            if !filters.installStatuses.isEmpty {
                let name = installStatusName(item.installStatus)
                if !filters.installStatuses.contains(name) { return false }
            }
            return true
        }
    }

    private func installStatusName(_ status: InstallStatus) -> String {
        switch status {
        case .installed: return "installed"
        case .outdated: return "outdated"
        case .newerThanInstalled: return "newer"
        case .notInstalled: return "notInstalled"
        case .unknown: return "unknown"
        }
    }

    // MARK: - 排序

    private func sort(_ input: [DMGItem]) -> [DMGItem] {
        input.sorted { lhs, rhs in
            // 收藏始终靠前（仅在「全部」里生效）
            if case .smart(.all) = selection, lhs.favorite != rhs.favorite {
                return lhs.favorite
            }

            let ascending: Bool
            switch sortField {
            case .name:
                ascending = lhs.effectiveDisplayName.localizedCompare(rhs.effectiveDisplayName) == .orderedAscending
            case .version:
                ascending = VersionComparator.compare(lhs.version ?? "", rhs.version ?? "") == .orderedAscending
            case .size:
                ascending = lhs.fileSize < rhs.fileSize
            case .addedAt:
                ascending = lhs.createdAt < rhs.createdAt
            case .modifiedAt:
                ascending = (lhs.fileModifiedAt ?? .distantPast) < (rhs.fileModifiedAt ?? .distantPast)
            }
            return sortAscending ? ascending : !ascending
        }
    }
}

extension DMGItem {
    /// 搜索用的完整文本（小写），覆盖文档要求的所有可搜索字段。
    var searchHaystack: String {
        if let cached = searchCache { return cached }
        let parts = [
            effectiveDisplayName,
            filename,
            note,
            tags.joined(separator: " "),
            appName ?? "",
            version ?? "",
            bundleID ?? "",
            developer ?? "",
            category,
            path
        ]
        let value = parts.joined(separator: " ").lowercased()
        searchCache = value
        return value
    }

    private var searchCache: String? {
        get { SearchCache.shared.value(for: self) }
        nonmutating set { SearchCache.shared.set(newValue, for: self) }
    }
}

/// 搜索文本缓存：列表滚动时避免反复拼接字符串。
private final class SearchCache: @unchecked Sendable {
    static let shared = SearchCache()
    private var storage: [Int64: (hash: Int, value: String)] = [:]
    private let lock = NSLock()

    func value(for item: DMGItem) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = storage[item.id], entry.hash == item.contentHash else { return nil }
        return entry.value
    }

    func set(_ value: String?, for item: DMGItem) {
        lock.lock(); defer { lock.unlock() }
        if let value {
            storage[item.id] = (item.contentHash, value)
        } else {
            storage.removeValue(forKey: item.id)
        }
    }
}

extension DMGItem {
    /// 参与搜索的字段指纹，用于判断缓存是否过期。
    var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(displayName)
        hasher.combine(filename)
        hasher.combine(note)
        hasher.combine(tags)
        hasher.combine(appName)
        hasher.combine(version)
        hasher.combine(bundleID)
        hasher.combine(developer)
        hasher.combine(category)
        hasher.combine(path)
        return hasher.finalize()
    }
}
