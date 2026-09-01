import Foundation

/// dmg_items 的读写入口。标签与分类的聚合查询也放在这里。
final class ItemRepository {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    // MARK: - 读取

    func fetchAll() throws -> [DMGItem] {
        let rows = try database.query("SELECT * FROM dmg_items;")
        var tagsByID: [Int64: [String]] = [:]
        for row in (try? database.query("""
            SELECT dmg_id, name FROM dmg_tags
            JOIN tags ON tags.id = dmg_tags.tag_id
            ORDER BY tags.name COLLATE NOCASE;
            """)) ?? [] {
            guard let dmgID = row["dmg_id"]?.intValue, let name = row["name"]?.stringValue else { continue }
            tagsByID[dmgID, default: []].append(name)
        }
        return rows.compactMap { row in
            var item = DMGItem(row: row)
            item?.tags = tagsByID[row["id"]?.intValue ?? 0] ?? []
            return item
        }
    }

    /// 已存在该路径的记录则返回 true，用于导入去重。
    func itemID(forPath path: String) throws -> Int64? {
        try database.query(
            "SELECT id FROM dmg_items WHERE path = ?;",
            bindings: [.value(path)]
        ).first?["id"]?.intValue
    }

    // MARK: - 写入

    /// 参与写入的列。占位符由列数自动生成，避免手写 `?` 数量与列数不一致。
    private static let writableColumns = [
        "path", "filename", "display_name", "display_name_is_custom", "note", "category", "favorite",
        "file_size", "file_created_at", "file_modified_at", "sha256", "volume_name",
        "app_name", "bundle_id", "version", "build", "developer", "architecture",
        "minimum_os", "app_relative_path", "icon_filename",
        "installed_version", "installed_path",
        "parse_status", "parse_error", "last_opened_at", "created_at", "updated_at"
    ]

    @discardableResult
    func insert(_ item: inout DMGItem) throws -> Int64 {
        let sql = """
        INSERT INTO dmg_items (\(Self.writableColumns.joined(separator: ", ")))
        VALUES (\(Self.placeholders));
        """
        let id = try database.run(sql, bindings: item.insertBindings())
        item.id = id
        try setTags(itemID: id, tags: item.tags)
        return id
    }

    func update(_ item: DMGItem) throws {
        let assignments = Self.writableColumns.map { "\($0) = ?" }.joined(separator: ", ")
        let sql = "UPDATE dmg_items SET \(assignments) WHERE id = ?;"
        try database.run(sql, bindings: item.insertBindings() + [.value(item.id)])
        try setTags(itemID: item.id, tags: item.tags)
    }

    /// 只更新后台解析得到的安装状态，不触碰用户元数据，避免覆盖并发的用户编辑。
    func updateInstallStatus(id: Int64, version: String?, path: String?) throws {
        try database.run(
            "UPDATE dmg_items SET installed_version = ?, installed_path = ? WHERE id = ?;",
            bindings: [.value(version), .value(path), .value(id)]
        )
    }

    /// 只更新后台补算的 SHA-256，不触碰其它列，避免覆盖并发的用户编辑。
    func updateSHA256(id: Int64, hash: String) throws {
        try database.run(
            "UPDATE dmg_items SET sha256 = ? WHERE id = ?;",
            bindings: [.value(hash), .value(id)]
        )
    }

    private static var placeholders: String {
        Array(repeating: "?", count: writableColumns.count).joined(separator: ", ")
    }

    /// 只更新用户可编辑的元数据字段（名称 / 备注 / 分类 / 收藏），避免覆盖扫描结果。
    func updateMetadata(_ item: DMGItem) throws {
        try database.run("""
            UPDATE dmg_items SET display_name = ?, display_name_is_custom = ?, note = ?, category = ?, favorite = ?, updated_at = ?
            WHERE id = ?;
            """, bindings: [
                .value(item.displayName),
                .value(item.displayNameIsCustom),
                .value(item.note),
                .value(item.category),
                .value(item.favorite),
                .value(Date().timeIntervalSince1970),
                .value(item.id)
            ])
        try setTags(itemID: item.id, tags: item.tags)
    }

    func delete(id: Int64) throws {
        try database.run("DELETE FROM dmg_items WHERE id = ?;", bindings: [.value(id)])
    }

    func touchLastOpened(id: Int64) {
        _ = try? database.run(
            "UPDATE dmg_items SET last_opened_at = ?, updated_at = ? WHERE id = ?;",
            bindings: [.value(Date().timeIntervalSince1970), .value(Date().timeIntervalSince1970), .value(id)]
        )
    }

    // MARK: - 标签 / 分类

    func setTags(itemID: Int64, tags: [String]) throws {
        try database.transaction {
            try database.run("DELETE FROM dmg_tags WHERE dmg_id = ?;", bindings: [.value(itemID)])
            for rawTag in tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                try database.run("INSERT OR IGNORE INTO tags(name) VALUES(?);", bindings: [.value(tag)])
                try database.run("""
                    INSERT OR IGNORE INTO dmg_tags(dmg_id, tag_id)
                    SELECT ?, id FROM tags WHERE name = ?;
                    """, bindings: [.value(itemID), .value(tag)])
            }
            // 清理孤儿标签：从最后一个引用它的条目移除后，自动从词表删除，
            // 这样「常用标签 / 侧栏 / 筛选器」里就不会再出现没人用的标签。
            try database.run("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM dmg_tags);")
        }
    }

    /// 全部标签及每个标签下的条目数。只返回仍被至少一个条目引用的标签，
    /// 无引用的孤儿标签不会出现（已随 setTags 自动清理）。
    func tagCounts() throws -> [(name: String, count: Int)] {
        let rows = try database.query("""
            SELECT tags.name AS name, COUNT(dmg_tags.dmg_id) AS count
            FROM tags
            JOIN dmg_tags ON dmg_tags.tag_id = tags.id
            GROUP BY tags.id
            ORDER BY count DESC, tags.name COLLATE NOCASE;
            """)
        return rows.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return (name, Int(row["count"]?.intValue ?? 0))
        }
    }

    /// 删除没有任何条目引用的孤儿标签，保持标签词表只保留「还有人用」的标签。
    func pruneOrphanTags() {
        _ = try? database.run("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM dmg_tags);")
    }

    /// 用户自建的分类词表（不依赖 dmg_items，包含尚未分配给任何条目的分类）。
    func customCategories() throws -> [String] {
        let rows = try database.query("SELECT name FROM categories ORDER BY name COLLATE NOCASE;")
        return rows.compactMap { $0["name"]?.stringValue }
    }

    func addCategory(_ name: String) throws {
        try database.run("INSERT OR IGNORE INTO categories(name) VALUES(?);", bindings: [.value(name)])
    }

    func deleteCategory(_ name: String) throws {
        try database.run("DELETE FROM categories WHERE name = ?;", bindings: [.value(name)])
    }

    func categoryCounts() throws -> [(name: String, count: Int)] {
        let rows = try database.query("""
            SELECT category AS name, COUNT(*) AS count
            FROM dmg_items
            GROUP BY category
            ORDER BY count DESC, name COLLATE NOCASE;
            """)
        return rows.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return (name, Int(row["count"]?.intValue ?? 0))
        }
    }

    func renameCategory(from old: String, to new: String) throws {
        try database.run(
            "UPDATE dmg_items SET category = ?, updated_at = ? WHERE category = ?;",
            bindings: [.value(new), .value(Date().timeIntervalSince1970), .value(old)]
        )
    }
}

// MARK: - 行映射

extension DMGItem {
    init?(row: [String: DatabaseValue]) {
        guard let id = row["id"]?.intValue,
              let path = row["path"]?.stringValue,
              let filename = row["filename"]?.stringValue else { return nil }

        self.init(
            id: id,
            path: path,
            filename: filename,
            displayName: row["display_name"]?.stringValue ?? "",
            displayNameIsCustom: row["display_name_is_custom"]?.boolValue ?? false,
            note: row["note"]?.stringValue ?? "",
            category: row["category"]?.stringValue ?? CategoryPresets.uncategorized,
            favorite: row["favorite"]?.boolValue ?? false,
            tags: [],
            fileSize: row["file_size"]?.intValue ?? 0,
            fileCreatedAt: row["file_created_at"]?.doubleValue?.asDate,
            fileModifiedAt: row["file_modified_at"]?.doubleValue?.asDate,
            sha256: row["sha256"]?.stringValue,
            volumeName: row["volume_name"]?.stringValue,
            appName: row["app_name"]?.stringValue,
            bundleID: row["bundle_id"]?.stringValue,
            version: row["version"]?.stringValue,
            build: row["build"]?.stringValue,
            developer: row["developer"]?.stringValue,
            architecture: Architecture(rawValue: row["architecture"]?.stringValue ?? "") ?? .unknown,
            minimumOS: row["minimum_os"]?.stringValue,
            appRelativePath: row["app_relative_path"]?.stringValue,
            iconFilename: row["icon_filename"]?.stringValue,
            installedVersion: row["installed_version"]?.stringValue,
            installedPath: row["installed_path"]?.stringValue,
            parseStatus: ParseStatus(rawValue: row["parse_status"]?.stringValue ?? "") ?? .pending,
            parseError: row["parse_error"]?.stringValue,
            lastOpenedAt: row["last_opened_at"]?.doubleValue?.asDate,
            createdAt: row["created_at"]?.doubleValue?.asDate ?? Date(),
            updatedAt: row["updated_at"]?.doubleValue?.asDate ?? Date()
        )
    }

    func insertBindings() -> [DatabaseValue] {
        [
            .value(path), .value(filename), .value(displayName), .value(displayNameIsCustom), .value(note),
            .value(category), .value(favorite),
            .value(fileSize), .value(fileCreatedAt?.timeIntervalSince1970),
            .value(fileModifiedAt?.timeIntervalSince1970), .value(sha256), .value(volumeName),
            .value(appName), .value(bundleID), .value(version), .value(build),
            .value(developer), .value(architecture.rawValue),
            .value(minimumOS), .value(appRelativePath), .value(iconFilename),
            .value(installedVersion), .value(installedPath),
            .value(parseStatus.rawValue), .value(parseError),
            .value(lastOpenedAt?.timeIntervalSince1970),
            .value(createdAt.timeIntervalSince1970), .value(updatedAt.timeIntervalSince1970)
        ]
    }
}

extension Double {
    var asDate: Date { Date(timeIntervalSince1970: self) }
}
