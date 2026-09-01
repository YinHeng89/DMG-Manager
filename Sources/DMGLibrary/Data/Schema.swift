import Foundation

/// 数据库结构定义与迁移。
enum Schema {
    static let currentVersion = 2

    static func migrate(database: Database) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS dmg_items (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            path                TEXT    NOT NULL UNIQUE,
            filename            TEXT    NOT NULL,
            display_name        TEXT    NOT NULL DEFAULT '',
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

        try setUserVersion(currentVersion, database: database)
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
