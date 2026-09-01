import Foundation

extension LibraryStore {
    /// 当前展示的条目：智能分组 → 搜索 → 高级筛选 → 排序。
    ///
    /// 带缓存：过滤 + 排序（比较器用 localizedCompare，比较贵）每次访问都要全量重算，
    /// 而一次渲染会被访问三四次（isEmpty / count / ForEach），不缓存会白白算好几遍。
    /// 仅在 items / selection / searchText / sortField / sortAscending / filters 变化时
    /// 由 invalidateFilteredItems() 标记失效。
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
            let hashes = duplicateGroups().flatMap { $0.compactMap(\.sha256) }
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
