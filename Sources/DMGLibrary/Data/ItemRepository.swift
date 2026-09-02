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

        // 备注 / 分类 / 标签的真相在 software 维度，这里按 groupingKey 回填到每个包上。
        // 上层（列表过滤、搜索、侧边栏计数、详情面板）拿到的 item 就已经是软件级的值，
        // 所以从「版本库」切到旧版本看到的也是同一份备注——这正是上移到软件维度的目的。
        var software: [String: (note: String, category: String)] = [:]
        for row in (try? database.query(
            "SELECT software_key, note, category FROM software;"
        )) ?? [] {
            guard let key = row["software_key"]?.stringValue else { continue }
            software[key] = (
                note: row["note"]?.stringValue ?? "",
                category: row["category"]?.stringValue ?? CategoryPresets.uncategorized
            )
        }

        var tagsByKey: [String: [String]] = [:]
        for row in (try? database.query("""
            SELECT software_key, name FROM software_tags
            JOIN tags ON tags.id = software_tags.tag_id
            ORDER BY tags.name COLLATE NOCASE;
            """)) ?? [] {
            guard let key = row["software_key"]?.stringValue,
                  let name = row["name"]?.stringValue else { continue }
            tagsByKey[key, default: []].append(name)
        }

        return rows.compactMap { row in
            guard var item = DMGItem(row: row) else { return nil }
            let key = item.groupingKey
            if let record = software[key] {
                item.note = record.note
                item.category = record.category
            }
            item.tags = tagsByKey[key] ?? []
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
    /// 注意：note / category 不在这里——它们已经上移到 software 表，
    /// 写回来只会留下一份永远不被读取的陈旧副本。
    private static let writableColumns = [
        "path", "filename", "display_name", "display_name_is_custom", "favorite",
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
        // 新包还没有 bundle_id，groupingKey 只能按文件名算；先占一个软件记录。
        // 解析完成后 syncSoftwareKey 会把这条数据搬到真正的软件键上。
        try ensureSoftware(key: item.groupingKey, note: item.note, category: item.category)
        try database.run(
            "UPDATE dmg_items SET software_key = ? WHERE id = ?;",
            bindings: [.value(item.groupingKey), .value(id)]
        )
        // 只有真的带了标签才写。新包通常没标签，此时若无条件 setTags，
        // 万一键撞上已存在的软件（同名的两个包），会把那个软件的标签清空。
        if !item.tags.isEmpty {
            try setTags(softwareKey: item.groupingKey, tags: item.tags)
        }
        return id
    }

    func update(_ item: DMGItem) throws {
        let assignments = Self.writableColumns.map { "\($0) = ?" }.joined(separator: ", ")
        let sql = "UPDATE dmg_items SET \(assignments) WHERE id = ?;"
        try database.run(sql, bindings: item.insertBindings() + [.value(item.id)])
        // 解析出 bundle_id 之后 groupingKey 会变，必须先搬迁数据再改指向。
        //
        // 刻意不在这里回写 note / category / tags：item 上这些值是从软件维度回填进来的，
        // 新版本解析完成后键会并到已有软件上，此时回写等于用「本包的旧副本」覆盖整个软件
        // 共享的那份数据（典型场景：新版本还没打标签，一解析就把老版本的标签清空了）。
        // 这些字段的唯一写入口是 updateMetadata（用户主动编辑）。
        try syncSoftwareKey(for: item)
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

    /// 只更新用户可编辑的元数据，不覆盖扫描 / 解析结果。
    ///
    /// 名称与收藏仍然属于这个包（同一个软件的不同版本可以各自收藏），
    /// 而备注 / 分类 / 标签属于整个软件，写到 software 表。
    func updateMetadata(_ item: DMGItem) throws {
        try database.run("""
            UPDATE dmg_items SET display_name = ?, display_name_is_custom = ?, favorite = ?, updated_at = ?
            WHERE id = ?;
            """, bindings: [
                .value(item.displayName),
                .value(item.displayNameIsCustom),
                .value(item.favorite),
                .value(Date().timeIntervalSince1970),
                .value(item.id)
            ])
        let key = item.groupingKey
        try ensureSoftware(key: key)
        try database.run("""
            UPDATE software SET note = ?, category = ?, updated_at = ? WHERE software_key = ?;
            """, bindings: [
                .value(item.note),
                .value(item.category),
                .value(Date().timeIntervalSince1970),
                .value(key)
            ])
        try setTags(softwareKey: key, tags: item.tags)
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

    func setTags(softwareKey: String, tags: [String]) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM software_tags WHERE software_key = ?;", bindings: [.value(softwareKey)]
            )
            for rawTag in tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                try database.run("INSERT OR IGNORE INTO tags(name) VALUES(?);", bindings: [.value(tag)])
                try database.run("""
                    INSERT OR IGNORE INTO software_tags(software_key, tag_id)
                    SELECT ?, id FROM tags WHERE name = ?;
                    """, bindings: [.value(softwareKey), .value(tag)])
            }
            // 清理孤儿标签：从最后一个引用它的软件移除后，自动从词表删除，
            // 这样「常用标签 / 侧栏 / 筛选器」里就不会再出现没人用的标签。
            try database.run("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM software_tags);")
        }
    }

    /// 全部标签及每个标签下的**软件**数（同一软件的多个版本只算一次）。
    /// 只返回仍被至少一个软件引用的标签，孤儿标签不会出现（已随 setTags 自动清理）。
    func tagCounts() throws -> [(name: String, count: Int)] {
        let rows = try database.query("""
            SELECT tags.name AS name, COUNT(software_tags.software_key) AS count
            FROM tags
            JOIN software_tags ON software_tags.tag_id = tags.id
            GROUP BY tags.id
            ORDER BY count DESC, tags.name COLLATE NOCASE;
            """)
        return rows.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return (name, Int(row["count"]?.intValue ?? 0))
        }
    }

    /// 删除没有任何软件引用的孤儿标签，保持标签词表只保留「还有人用」的标签。
    func pruneOrphanTags() {
        _ = try? database.run("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM software_tags);")
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

    /// 各分类下的**软件**数（同一软件的多个版本只算一次）。
    func categoryCounts() throws -> [(name: String, count: Int)] {
        let rows = try database.query("""
            SELECT category AS name, COUNT(*) AS count
            FROM software
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
            "UPDATE software SET category = ?, updated_at = ? WHERE category = ?;",
            bindings: [.value(new), .value(Date().timeIntervalSince1970), .value(old)]
        )
    }

    // MARK: - 软件维度

    /// 确保软件记录存在。首次见到某个软件时用它自带的备注 / 分类建一条。
    func ensureSoftware(key: String, note: String? = nil, category: String? = nil) throws {
        try database.run("""
            INSERT OR IGNORE INTO software(software_key, note, category, updated_at)
            VALUES(?, ?, ?, ?);
            """, bindings: [
                .value(key),
                .value(note ?? ""),
                .value(category ?? CategoryPresets.uncategorized),
                .value(Date().timeIntervalSince1970)
            ])
    }

    /// 取一个软件的备注 / 分类 / 标签。
    ///
    /// 用于「包的 groupingKey 并到已有软件上之后，把内存里那份旧副本刷新成共享值」——
    /// 不刷的话选中这个包看到的还是它自己那份旧数据，和同组其它版本对不上。
    func softwareMetadata(forKey key: String) -> (note: String, category: String, tags: [String])? {
        guard let row = (try? database.query(
            "SELECT note, category FROM software WHERE software_key = ?;", bindings: [.value(key)]
        ))?.first else { return nil }

        let tags = ((try? database.query("""
            SELECT name FROM software_tags
            JOIN tags ON tags.id = software_tags.tag_id
            WHERE software_key = ?
            ORDER BY tags.name COLLATE NOCASE;
            """, bindings: [.value(key)])) ?? []).compactMap { $0["name"]?.stringValue }

        return (
            note: row["note"]?.stringValue ?? "",
            category: row["category"]?.stringValue ?? CategoryPresets.uncategorized,
            tags: tags
        )
    }

    /// 写入自动推测的分类，但**只在软件还没分类时**生效。
    ///
    /// 解析出 App 名后会推测一个分类，可用户可能早就把这个软件归到别的分类了；
    /// 无条件写入会覆盖用户的分类，所以这里带 `category = 未分类` 的条件。
    func applyAutoCategory(_ category: String, forSoftwareKey key: String) throws {
        try ensureSoftware(key: key)
        try database.run("""
            UPDATE software SET category = ?, updated_at = ?
            WHERE software_key = ? AND category = ?;
            """, bindings: [
                .value(category),
                .value(Date().timeIntervalSince1970),
                .value(key),
                .value(CategoryPresets.uncategorized)
            ])
    }

    /// 把包的 software_key 同步到它当前的 groupingKey。
    ///
    /// 关键场景：导入时还没有 bundle_id，groupingKey 是按文件名算的（每个文件各成一个
    /// 「软件」）；解析完成后拿到 bundle_id，键变成 `id:com.xxx`。这时必须把旧键上已经
    /// 写下的备注 / 分类 / 标签搬到新键，否则用户刚写的备注会随着解析完成凭空消失。
    func syncSoftwareKey(for item: DMGItem) throws {
        let newKey = item.groupingKey
        let oldKey = (try? database.query(
            "SELECT software_key FROM dmg_items WHERE id = ?;", bindings: [.value(item.id)]
        ))?.first?["software_key"]?.stringValue ?? ""

        // 先改指向，再搬数据：这样「还有没有别的包引用旧键」的统计才准确。
        try database.run(
            "UPDATE dmg_items SET software_key = ? WHERE id = ?;",
            bindings: [.value(newKey), .value(item.id)]
        )

        if oldKey.isEmpty {
            try ensureSoftware(key: newKey)
        } else if oldKey != newKey {
            try migrateSoftware(from: oldKey, to: newKey)
        }
    }

    /// 软件键变更时搬迁数据：目标键还没有记录就整条搬过去，已有记录则只并标签。
    private func migrateSoftware(from oldKey: String, to newKey: String) throws {
        try database.transaction {
            try database.run("""
                INSERT OR IGNORE INTO software(software_key, note, category, updated_at)
                SELECT ?, note, category, ? FROM software WHERE software_key = ?;
                """, bindings: [.value(newKey), .value(Date().timeIntervalSince1970), .value(oldKey)])

            try database.run("""
                INSERT OR IGNORE INTO software_tags(software_key, tag_id)
                SELECT ?, tag_id FROM software_tags WHERE software_key = ?;
                """, bindings: [.value(newKey), .value(oldKey)])

            // 没有别的包还指向旧键了，旧记录就可以删掉。
            let remaining = (try? database.query(
                "SELECT COUNT(*) AS n FROM dmg_items WHERE software_key = ?;",
                bindings: [.value(oldKey)]
            ))?.first?["n"]?.intValue ?? 0
            if remaining == 0 {
                try database.run(
                    "DELETE FROM software WHERE software_key = ?;", bindings: [.value(oldKey)]
                )
                try database.run(
                    "DELETE FROM software_tags WHERE software_key = ?;", bindings: [.value(oldKey)]
                )
            }
        }
    }

    /// 清理一个包都不剩的软件记录（最后一个版本被删掉时）。
    ///
    /// 注意只清理「一个包都不剩」的软件：只删掉其中一个版本时软件记录必须留着，
    /// 备注才不会跟着消失——这正是上移到软件维度要解决的问题。
    func pruneOrphanSoftware() {
        _ = try? database.run("""
            DELETE FROM software
            WHERE software_key NOT IN (SELECT DISTINCT software_key FROM dmg_items);
            """)
        _ = try? database.run("""
            DELETE FROM software_tags
            WHERE software_key NOT IN (SELECT DISTINCT software_key FROM dmg_items);
            """)
        _ = try? database.run("DELETE FROM tags WHERE id NOT IN (SELECT DISTINCT tag_id FROM software_tags);")
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
            .value(path), .value(filename), .value(displayName), .value(displayNameIsCustom),
            .value(favorite),
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
