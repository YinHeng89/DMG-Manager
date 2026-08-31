import XCTest
import CryptoKit
@testable import DMGLibrary

final class DatabaseTests: XCTestCase {
    private var sandbox: URL!
    private var database: Database!
    private var repository: ItemRepository!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DMGLibraryDB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("DMGLIBRARY_ROOT", sandbox.path, 1)
        database = try Database(fileURL: sandbox.appendingPathComponent("database.sqlite"))
        try Schema.migrate(database: database)
        repository = ItemRepository(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        unsetenv("DMGLIBRARY_ROOT")
    }

    func testInsertAndFetch() throws {
        var item = DMGItem.sample(id: 0)
        try repository.insert(&item)
        XCTAssertGreaterThan(item.id, 0)

        let fetched = try repository.fetchAll()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.appName, "Google Chrome")
        XCTAssertEqual(fetched.first?.architecture, .appleSilicon)
        XCTAssertEqual(Set(fetched.first?.tags ?? []), ["浏览器", "ARM64"])
        XCTAssertEqual(fetched.first?.parseStatus, .parsed)
    }

    func testUpdateMetadataKeepsParsedFields() throws {
        var item = DMGItem.sample(id: 0)
        try repository.insert(&item)

        item.displayName = "主力浏览器"
        item.note = "公司电脑专用"
        item.category = "开发工具"
        item.favorite = true
        item.tags = ["常用"]
        try repository.updateMetadata(item)

        let fetched = try XCTUnwrap(repository.fetchAll().first)
        XCTAssertEqual(fetched.displayName, "主力浏览器")
        XCTAssertEqual(fetched.note, "公司电脑专用")
        XCTAssertEqual(fetched.category, "开发工具")
        XCTAssertTrue(fetched.favorite)
        XCTAssertEqual(fetched.tags, ["常用"])
        // 解析结果不应被元数据更新覆盖
        XCTAssertEqual(fetched.appName, "Google Chrome")
        XCTAssertEqual(fetched.version, "139.0.7258.76")
    }

    func testDuplicatePathIsRejected() throws {
        var item = DMGItem.sample(id: 0)
        try repository.insert(&item)
        XCTAssertNotNil(try repository.itemID(forPath: item.path))
        XCTAssertNil(try repository.itemID(forPath: "/tmp/nope.dmg"))
    }

    func testTagAndCategoryCounts() throws {
        var chrome = DMGItem.sample(id: 0)
        chrome.tags = ["浏览器", "ARM64"]
        try repository.insert(&chrome)

        var cursor = DMGItem.sample(id: 0)
        cursor.path = "/Users/me/Downloads/Cursor-1.5-universal.dmg"
        cursor.filename = "Cursor-1.5-universal.dmg"
        cursor.displayName = "Cursor"
        cursor.appName = "Cursor"
        cursor.bundleID = "com.todesktop.230313mzl4w4u92"
        cursor.version = "1.5.0"
        cursor.category = "开发工具"
        cursor.architecture = .universal
        cursor.tags = ["开发", "ARM64"]
        try repository.insert(&cursor)

        let tags = try repository.tagCounts()
        XCTAssertEqual(tags.first { $0.name == "ARM64" }?.count, 2)
        XCTAssertEqual(tags.first { $0.name == "浏览器" }?.count, 1)

        let categories = try repository.categoryCounts()
        XCTAssertEqual(categories.first { $0.name == "开发工具" }?.count, 1)
        XCTAssertEqual(categories.first { $0.name == "浏览器" }?.count, 1)
    }

    func testDeleteRemovesTagRelations() throws {
        var item = DMGItem.sample(id: 0)
        item.tags = ["浏览器"]
        try repository.insert(&item)
        try repository.delete(id: item.id)

        XCTAssertTrue(try repository.fetchAll().isEmpty)
        let leftover = try database.query("SELECT COUNT(*) AS c FROM dmg_tags;")
        XCTAssertEqual(leftover.first?["c"]?.intValue, 0)
    }

    func testFileNameGuessing() {
        XCTAssertEqual("Install_MarsEdit_5.8.3.dmg".guessedAppName, "MarsEdit")
        XCTAssertEqual("Chrome_139.0.7258_arm64.dmg".guessedAppName, "Chrome")
        XCTAssertEqual("xxx_2.4.1_arm64.dmg".guessedAppName, "xxx")
    }

    func testSmartCategorizer() {
        XCTAssertEqual(SmartCategorizer.category(for: "googlechrome.dmg"), "浏览器")
        XCTAssertEqual(SmartCategorizer.category(for: "cursor-universal.dmg"), "开发工具")
        XCTAssertEqual(SmartCategorizer.category(for: "iina-1.3.5.dmg"), "多媒体")
        XCTAssertEqual(SmartCategorizer.category(for: "something-unknown.dmg"), "未分类")
    }

    func testSHA256() throws {
        let file = sandbox.appendingPathComponent("payload.bin")
        try Data("hello dmglibrary".utf8).write(to: file)
        let hash = try SHA256Service.hash(fileAt: file)
        XCTAssertEqual(hash.count, 64)

        // 与 CryptoKit 直接结果一致
        var hasher = CryptoKit.SHA256()
        hasher.update(data: Data("hello dmglibrary".utf8))
        XCTAssertEqual(hash, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
