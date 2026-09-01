import Foundation

/// 数据库结构定义与迁移。
///
/// 迁移按 `user_version` 逐级往上走：建表语句是幂等的（`IF NOT EXISTS`），
/// 但加列不是，所以每个版本的增量必须用 `ALTER TABLE` 单独跑，并且只跑一次。
enum Schema {
    static let currentVersion = 3

    static func migrate(database: Database) throws {
        try createTables(database: database)

        let version = userVersion(database: database)
        if version < 3 { try migrateToV3(database: database) }

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
            note                TEXT    NOT NULL DEFAULT '',
            category            TEXT    NOT NULL DEFAULT '未分类',
            favorite            INTEGER NOT NULL DEFAULT 0,

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
