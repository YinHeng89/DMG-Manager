import XCTest
@testable import DMGLibrary

/// 覆盖搜索、筛选、排序、版本库、重复检测这些列表层逻辑。
@MainActor
final class LibraryStoreTests: XCTestCase {
    private var sandbox: URL!
    private var store: LibraryStore!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DMGLibraryStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("DMGLIBRARY_ROOT", sandbox.appendingPathComponent("Data").path, 1)
        store = try LibraryStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        unsetenv("DMGLIBRARY_ROOT")
    }

    // MARK: - 造数据

    private func makeFile(name: String, bytes: Int = 1024) -> URL {
        let url = sandbox.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        return url
    }

    private func add(
        _ name: String,
        appName: String,
        version: String,
        bundleID: String,
        architecture: Architecture,
        favorite: Bool = false,
        tags: [String] = [],
        category: String = "未分类",
        bytes: Int = 1024,
        sha256: String? = nil
    ) throws -> DMGItem {
        let url = makeFile(name: name, bytes: bytes)
        var item = DMGItem(
            path: url.path,
            filename: name,
            displayName: appName,
            category: category,
            favorite: favorite,
            tags: tags,
            fileSize: Int64(bytes),
            sha256: sha256,
            appName: appName,
            bundleID: bundleID,
            version: version,
            architecture: architecture,
            parseStatus: .parsed
        )
        try insert(&item)
        return item
    }

    private func insert(_ item: inout DMGItem) throws {
        // 直接走 repository，避免触发真实挂载
        try store.database.performInsert(&item)
        store.reload()
    }

    // MARK: - 测试

    func testSearchAcrossFields() throws {
        _ = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)
        _ = try add("Cursor_1.5.dmg", appName: "Cursor", version: "1.5.0",
                    bundleID: "com.todesktop.cursor", architecture: .universal,
                    tags: ["开发"])

        store.searchText = "chrome"
        XCTAssertEqual(store.filteredItems.count, 1)
        XCTAssertEqual(store.filteredItems.first?.appName, "Google Chrome")

        store.searchText = "com.todesktop"
        XCTAssertEqual(store.filteredItems.count, 1)

        store.searchText = "开发"
        XCTAssertEqual(store.filteredItems.first?.appName, "Cursor")

        store.searchText = "不存在的关键字"
        XCTAssertTrue(store.filteredItems.isEmpty)

        store.searchText = ""
        XCTAssertEqual(store.filteredItems.count, 2)
    }

    func testNoteIsSearchable() throws {
        var item = try add("MarsEdit.dmg", appName: "MarsEdit", version: "5.8.3",
                           bundleID: "com.red-sweater.marsedit", architecture: .universal)
        item.note = "这是最后一个支持 macOS 13 的版本"
        store.saveMetadata(item)

        store.searchText = "macOS 13"
        XCTAssertEqual(store.filteredItems.count, 1)
    }

    func testSmartListsAndFilters() throws {
        let chrome = try add("Chrome.dmg", appName: "Google Chrome", version: "139.0",
                             bundleID: "com.google.Chrome", architecture: .appleSilicon,
                             favorite: true, tags: ["浏览器"], category: "浏览器")
        _ = try add("IINA.dmg", appName: "IINA", version: "1.3.5",
                    bundleID: "com.colliderli.iina", architecture: .appleSilicon,
                    tags: ["多媒体"], category: "多媒体")

        store.selection = .smart(.favorites)
        XCTAssertEqual(store.filteredItems.map(\.id), [chrome.id])

        store.selection = .category("多媒体")
        XCTAssertEqual(store.filteredItems.count, 1)

        store.selection = .tag("浏览器")
        XCTAssertEqual(store.filteredItems.count, 1)

        store.selection = .smart(.all)
        store.filters.architectures = [.intel]
        XCTAssertTrue(store.filteredItems.isEmpty)

        store.filters = FilterCriteria()
        XCTAssertEqual(store.filteredItems.count, 2)
    }

    func testSorting() throws {
        _ = try add("A.dmg", appName: "A", version: "1.0", bundleID: "a",
                    architecture: .appleSilicon, bytes: 100)
        _ = try add("B.dmg", appName: "B", version: "3.0", bundleID: "b",
                    architecture: .appleSilicon, bytes: 300)

        store.sortField = .size
        store.sortAscending = false
        XCTAssertEqual(store.filteredItems.first?.appName, "B")

        store.sortAscending = true
        XCTAssertEqual(store.filteredItems.first?.appName, "A")

        store.sortField = .name
        store.sortAscending = false
        XCTAssertEqual(store.filteredItems.first?.appName, "B")
    }

    func testVersionLibraryGrouping() throws {
        _ = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)
        let older = try add("Chrome_138.dmg", appName: "Google Chrome", version: "138.0",
                            bundleID: "com.google.Chrome", architecture: .appleSilicon)
        _ = try add("IINA.dmg", appName: "IINA", version: "1.3.5",
                    bundleID: "com.colliderli.iina", architecture: .appleSilicon)

        let latest = try XCTUnwrap(store.items.first { $0.version == "139.0" })
        let related = store.relatedVersions(for: latest)
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual(related.first?.id, older.id)
    }

    func testMissingFileDetection() throws {
        var item = try add("Ghost.dmg", appName: "Ghost", version: "1.0",
                           bundleID: "com.example.ghost", architecture: .appleSilicon)
        XCTAssertTrue(item.exists)

        try FileManager.default.removeItem(atPath: item.path)
        store.reload()
        let reloaded = try XCTUnwrap(store.item(id: item.id))
        XCTAssertFalse(reloaded.exists)
        // 有版本号但系统里没装 → 未安装
        XCTAssertEqual(reloaded.installStatus.displayName, InstallStatus.notInstalled.displayName)

        store.selection = .smart(.missing)
        XCTAssertEqual(store.count(for: .missing), 1)
    }

    func testRelocation() async throws {
        let original = try add("Move_me.dmg", appName: "MoveMe", version: "1.0",
                               bundleID: "com.example.moveme", architecture: .appleSilicon)
        let moved = sandbox.appendingPathComponent("elsewhere/Move_me.dmg")
        try FileManager.default.createDirectory(
            at: moved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(atPath: original.path, toPath: moved.path)

        store.relocate(id: original.id, to: moved)
        let reloaded = try XCTUnwrap(store.item(id: original.id))
        XCTAssertEqual(reloaded.path, moved.path)
        XCTAssertTrue(reloaded.exists)
    }

    func testDeleteRemovesItem() throws {
        let item = try add("Trash.dmg", appName: "Trash", version: "1.0",
                           bundleID: "com.example.trash", architecture: .appleSilicon)
        store.delete(ids: [item.id], moveToTrash: false)
        XCTAssertNil(store.item(id: item.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - 版本折叠

    func testListCollapsesSameAppToLatestVersion() throws {
        _ = try add("Chrome_138.dmg", appName: "Google Chrome", version: "138.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)
        let latest = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                             bundleID: "com.google.Chrome", architecture: .appleSilicon)
        _ = try add("IINA.dmg", appName: "IINA", version: "1.3.5",
                    bundleID: "com.colliderli.iina", architecture: .appleSilicon)

        // 三条记录，Chrome 的两个版本合并成一行
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.displayedItems.count, 2)
        XCTAssertEqual(store.collapsedVersionCount, 1)

        // 留下的是 139 而不是 138
        let row = try XCTUnwrap(store.displayedItems.first { $0.appName == "Google Chrome" })
        XCTAssertEqual(row.id, latest.id)
        XCTAssertEqual(store.versionCount(for: row), 2)
    }

    /// 折叠只是「不显示」，不是删除：filteredItems 必须仍是全量，
    /// 否则「重新解析当前列表」会漏掉折叠掉的旧版本。
    func testCollapsedVersionsStayInFilteredItems() throws {
        _ = try add("Chrome_138.dmg", appName: "Google Chrome", version: "138.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)
        _ = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)

        XCTAssertEqual(store.displayedItems.count, 1)
        XCTAssertEqual(store.filteredItems.count, 2)
    }

    func testVersionGroupIsOrderedLatestFirst() throws {
        let older = try add("Chrome_138.dmg", appName: "Google Chrome", version: "138.0",
                            bundleID: "com.google.Chrome", architecture: .appleSilicon)
        let newer = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                            bundleID: "com.google.Chrome", architecture: .appleSilicon)

        // 从任意一条取，顺序都一样（索引按组算，不依赖传入哪条）
        XCTAssertEqual(store.versionGroup(for: newer).map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.versionGroup(for: older).map(\.id), [newer.id, older.id])
    }

    func testSelectingOldVersionKeepsRowHighlighted() throws {
        let older = try add("Chrome_138.dmg", appName: "Google Chrome", version: "138.0",
                            bundleID: "com.google.Chrome", architecture: .appleSilicon)
        _ = try add("Chrome_139.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon)

        // 从版本库切到旧版本：这一行不在列表里，但代表行仍应算选中
        store.selectedItemID = older.id
        let row = try XCTUnwrap(store.displayedItems.first)
        XCTAssertNotEqual(row.id, older.id)
        XCTAssertEqual(row.groupingKey, store.selectedGroupKey)
        XCTAssertEqual(store.representativeID(for: older.id), row.id)
    }

    /// 「重复文件」存在的意义就是把每一份都摆出来，折叠了就自相矛盾。
    func testDuplicatesListIsNotCollapsed() throws {
        _ = try add("Chrome.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon,
                    sha256: "same-hash")
        _ = try add("Chrome_copy.dmg", appName: "Google Chrome", version: "139.0",
                    bundleID: "com.google.Chrome", architecture: .appleSilicon,
                    sha256: "same-hash")

        store.selection = .smart(.duplicates)
        XCTAssertEqual(store.displayedItems.count, 2)
        XCTAssertEqual(store.collapsedVersionCount, 0)
    }

    func testDuplicateGroupsAreCachedAndInvalidated() throws {
        XCTAssertTrue(store.duplicateGroups().isEmpty)

        _ = try add("A.dmg", appName: "A", version: "1.0", bundleID: "com.example.a",
                    architecture: .appleSilicon, sha256: "shared")
        // 插入后 reload() 会清缓存，所以这里必须能看到新组
        XCTAssertTrue(store.duplicateGroups().isEmpty)

        _ = try add("A_copy.dmg", appName: "A", version: "1.0", bundleID: "com.example.a",
                    architecture: .appleSilicon, sha256: "shared")
        XCTAssertEqual(store.duplicateGroups().count, 1)
        XCTAssertEqual(store.duplicateGroups().first?.count, 2)
    }
}

// 测试专用：直接插入一条记录，绕过真实 DMG 挂载。
extension Database {
    func performInsert(_ item: inout DMGItem) throws {
        let repository = ItemRepository(database: self)
        try repository.insert(&item)
    }
}
