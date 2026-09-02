import Foundation

/// 数据库结构定义与迁移。
///
/// 迁移按 `user_version` 逐级往上走：建表语句是幂等的（`IF NOT EXISTS`），
/// 但加列不是，所以每个版本的增量必须用 `ALTER TABLE` 单独跑，并且只跑一次。
enum Schema {
    static let currentVersion = 4

    static func migrate(database: Database) throws {
        try createTables(database: database)

        let version = userVersion(database: database)
        if version < 3 { try migrateToV3(database: database) }
        if version < 4 { try migrateToV4(database: database) }

        try setUserVersion(currentVersion, database: database)
    }

    private static func createTables(database: Database) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS dmg_items (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            path                TEXT    NOT NULL UNIQUE,
            filename            TEXT    NOT NULL,
            display_name        TEXT    NOT NULL DEFAULT '',
            display_name_is_custom INTEGER NOT NULL DEFAULT 0,
            -- note / category 是 v4 之前的历史列，真相已迁到 software 表，不再写入。
            -- 保留只是为了迁移时能读到旧数据；运行时一律以 software 表为准并覆盖回填。
            note                TEXT    NOT NULL DEFAULT '',
            category            TEXT    NOT NULL DEFAULT '未分类',
            favorite            INTEGER NOT NULL DEFAULT 0,
            -- 该包所属「软件」的键（= DMGItem.groupingKey）。解析出 bundle_id 之后会变，
            -- 由 ItemRepository.syncSoftwareKey 负责把旧键上的数据搬过去。
            software_key        TEXT    NOT NULL DEFAULT '',

            file_size           INTEGER NOT NULL DEFAULT 0,
            file_created_at     REAL,
            file_modified_at    REAL,
            sha256              TEXT,
            volume_name         TEXT,

            app_name            TEXT,
            bundle_id           TEXT,
            version             TEXT,
            build               TEXT,
            developer           TEXT,
            architecture        TEXT    NOT NULL DEFAULT 'unknown',
            minimum_os          TEXT,
            app_relative_path   TEXT,
            icon_filename       TEXT,

            installed_version   TEXT,
            installed_path      TEXT,

            parse_status        TEXT    NOT NULL DEFAULT 'pending',
            parse_error         TEXT,
            last_opened_at      REAL,
            created_at          REAL    NOT NULL,
            updated_at          REAL    NOT NULL
        );
        """)

        try database.execute("""
        CREATE TABLE IF NOT EXISTS tags (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            name    TEXT NOT NULL UNIQUE,
            color   TEXT NOT NULL DEFAULT 'accent'
        );
        """)

        try database.execute("""
        CREATE TABLE IF NOT EXISTS dmg_tags (
            dmg_id  INTEGER NOT NULL REFERENCES dmg_items(id) ON DELETE CASCADE,
            tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (dmg_id, tag_id)
        );
        """)

        // 用户自建的分类词表。和 tags 一样独立成表，
        // 这样「新建了但还没分配给任何条目」的分类也能保留下来（reload 不会把它冲掉），
        // 未使用的自建分类才可以被删除。
        try database.execute("""
        CREATE TABLE IF NOT EXISTS categories (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            name    TEXT NOT NULL UNIQUE
        );
        """)

        // 一个「软件」= 同一个 groupingKey（Bundle ID / 规范化 App 名）下的全部版本。
        // 备注与分类属于软件，不属于某个具体的 DMG 包——
        // 否则切到旧版本备注就「消失」、删掉某个包连备注一起没了。
        try database.execute("""
        CREATE TABLE IF NOT EXISTS software (
            software_key TEXT PRIMARY KEY,
            note         TEXT NOT NULL DEFAULT '',
            category     TEXT NOT NULL DEFAULT '未分类',
            updated_at   REAL NOT NULL
        );
        """)

        // 标签也挂到软件维度（v4 之前是 dmg_tags，按包存）。
        try database.execute("""
        CREATE TABLE IF NOT EXISTS software_tags (
            software_key TEXT NOT NULL,
            tag_id       INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (software_key, tag_id)
        );
        """)

        try database.execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key     TEXT PRIMARY KEY,
            value   TEXT NOT NULL DEFAULT ''
        );
        """)

        try database.execute("CREATE INDEX IF NOT EXISTS idx_dmg_bundle ON dmg_items(bundle_id);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_dmg_status ON dmg_items(parse_status);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_dmg_favorite ON dmg_items(favorite);")
    }

    // MARK: - 增量迁移

    /// v3：加 `display_name_is_custom`，让重新解析不再覆盖用户手动改的名字。
    ///
    /// 之前 `parseOne` 无条件把 `display_name` 写成 App 名，用户把「Google Chrome」
    /// 改成「工作用 Chrome」后，只要点一次「重新解析」（或启动时自动扫库），名字就被冲掉了。
    private static func migrateToV3(database: Database) throws {
        // 新库在 createTables 里已经带上了这一列，别重复加（ALTER 会报 duplicate column）。
        guard !columnExists("display_name_is_custom", in: "dmg_items", database: database) else { return }
        try database.execute(
            "ALTER TABLE dmg_items ADD COLUMN display_name_is_custom INTEGER NOT NULL DEFAULT 0;"
        )

        // 回填：已经解析过的条目，名字还和 App 名不一致，只能是用户改的。
        //
        // 刻意只回填 parse_status = 'parsed' 的行：pending / failed 的条目
        // `display_name` 还是导入时从文件名猜的（`guessedAppName`），那不是用户起的名，
        // 标成自定义会让它们永远拿不到真正的 App 名。
        try database.execute("""
            UPDATE dmg_items SET display_name_is_custom = 1
            WHERE parse_status = 'parsed'
              AND app_name IS NOT NULL AND app_name <> ''
              AND display_name <> '' AND display_name <> app_name;
            """)
    }

    /// v4：备注 / 标签 / 分类 从「每个 DMG 包」上移到「软件」维度。
    ///
    /// 之前这三项都挂在单个 DMG 上（备注、分类是 dmg_items 的列，标签是 dmg_tags 多对多）。
    /// 有了版本折叠之后这就自相矛盾：同一个软件的多个版本各存一份，切到旧版本备注就「消失」；
    /// 代表项是随当前筛选结果选出来的，同一个软件在不同列表里显示的备注还不一样；
    /// 删掉其中一个 DMG，写在它上面的备注跟着一起没了。
    ///
    /// 现在统一存进 `software` 表（按 groupingKey 聚合成一个软件），dmg_items 只留
    /// `software_key` 指回去。同一软件下各版本数据不一致时，取「版本最新」那条为准。
    private static func migrateToV4(database: Database) throws {
        if !columnExists("software_key", in: "dmg_items", database: database) {
            try database.execute(
                "ALTER TABLE dmg_items ADD COLUMN software_key TEXT NOT NULL DEFAULT '';"
            )
        }

        // 迁移过的库 software_key 都已回填，没必要再来一遍（否则会把数据反复搬）。
        let pending = (try? database.query(
            "SELECT COUNT(*) AS n FROM dmg_items WHERE software_key = '';"
        ))?.first?["n"]?.intValue ?? 0
        guard pending > 0 else { return }

        // groupingKey 是 Swift 侧算的（优先 bundle_id，其次规范化 App 名，再退到文件名），
        // 这里刻意用 Swift 而不是 SQL 拼：SQL 很难精确复刻这段逻辑，键算错就等于数据搬错地方。
        let rows = (try? database.query("SELECT * FROM dmg_items;")) ?? []
        var grouped: [String: [DMGItem]] = [:]
        for row in rows {
            guard let item = DMGItem(row: row) else { continue }
            grouped[item.groupingKey, default: []].append(item)
        }

        // 旧标签还按包存在 dmg_tags 里，先取出来，随迁移搬到 software_tags。
        var tagsByItem: [Int64: [String]] = [:]
        for row in (try? database.query("""
            SELECT dmg_id, name FROM dmg_tags JOIN tags ON tags.id = dmg_tags.tag_id;
            """)) ?? [] {
            guard let dmgID = row["dmg_id"]?.intValue,
                  let name = row["name"]?.stringValue else { continue }
            tagsByItem[dmgID, default: []].append(name)
        }

        let now = Date().timeIntervalSince1970
        try database.transaction {
            for (key, members) in grouped {
                // 同组取「版本最新」那条作为迁移来源。
                guard var source = members.first else { continue }
                for member in members where prefers(member, over: source) {
                    source = member
                }

                try database.run("""
                    INSERT OR REPLACE INTO software(software_key, note, category, updated_at)
                    VALUES(?, ?, ?, ?);
                    """, bindings: [
                        .value(key), .value(source.note), .value(source.category), .value(now)
                    ])

                for tag in tagsByItem[source.id] ?? [] {
                    try database.run("INSERT OR IGNORE INTO tags(name) VALUES(?);", bindings: [.value(tag)])
                    try database.run("""
                        INSERT OR IGNORE INTO software_tags(software_key, tag_id)
                        SELECT ?, id FROM tags WHERE name = ?;
                        """, bindings: [.value(key), .value(tag)])
                }

                for member in members {
                    try database.run(
                        "UPDATE dmg_items SET software_key = ? WHERE id = ?;",
                        bindings: [.value(key), .value(member.id)]
                    )
                }
            }

            // 标签已整体搬到 software_tags，旧的多对多关系表不再使用。
            try database.run("DELETE FROM dmg_tags;")
        }
    }

    /// 迁移时挑「代表版本」：版本号高的优先，版本相同取更晚入库的。
    private static func prefers(_ lhs: DMGItem, over rhs: DMGItem) -> Bool {
        let order = VersionComparator.compare(lhs.version ?? "", rhs.version ?? "")
        if order != .orderedSame { return order == .orderedDescending }
        return lhs.createdAt > rhs.createdAt
    }

    // MARK: - 元信息

    private static func userVersion(database: Database) -> Int {
        Int((try? database.query("PRAGMA user_version;"))?.first?["user_version"]?.intValue ?? 0)
    }

    private static func columnExists(_ column: String, in table: String, database: Database) -> Bool {
        guard let rows = try? database.query("PRAGMA table_info(\(table));") else { return false }
        return rows.contains { $0["name"]?.stringValue == column }
    }

    private static func setUserVersion(_ version: Int, database: Database) throws {
        try database.execute("PRAGMA user_version = \(version);")
    }
}

/// 轻量键值设置（扫描目录、视图偏好等）。
final class SettingsStore {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func string(for key: String) -> String? {
        (try? database.query("SELECT value FROM settings WHERE key = ?;",
                             bindings: [.value(key)]))?.first?["value"]?.stringValue
    }

    func set(_ value: String, for key: String) {
        _ = try? database.run(
            "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.value(key), .value(value)]
        )
    }
}
