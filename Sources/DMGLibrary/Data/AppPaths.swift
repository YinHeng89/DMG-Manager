import Foundation

enum AppPaths {
    /// 支持用 DMGLIBRARY_ROOT 覆盖数据目录（测试与调试用）。
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["DMGLIBRARY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DMGLibrary", isDirectory: true)
    }

    static var database: URL { root.appendingPathComponent("database.sqlite") }
    static var thumbnails: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }
    static var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }

    static func ensureDirectories() {
        let manager = FileManager.default
        for url in [root, thumbnails, backups] {
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

/// 数据库自动备份：每次启动保留一份快照，最多保留 recent limit 份。
enum BackupService {
    static let keepCount = 5

    static func snapshot(database: URL) {
        AppPaths.ensureDirectories()
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "database-\(formatter.string(from: Date())).sqlite"
        let target = AppPaths.backups.appendingPathComponent(name)
        // 目标文件同名时先清掉：VACUUM INTO 要求目标不存在，否则会直接报错。
        try? FileManager.default.removeItem(at: target)

        if !vacuumInto(source: database, target: target) {
            // VACUUM INTO 不可用时（库损坏 / 版本过旧）退回整文件拷贝，至少留一份东西。
            try? FileManager.default.copyItem(at: database, to: target)
        }
        prune()
    }

    /// SQLite 官方的在线备份方式：连上库执行 VACUUM INTO。
    ///
    /// 不能直接 `FileManager.copyItem` 主库文件——WAL 模式下尚未 checkpoint 的事务只存在
    /// 于 `-wal` 里，只拷主库会丢掉这部分数据，复制出来的库还可能处于不一致状态。
    /// 而「上一次异常退出、WAL 里还压着事务」恰恰是最需要备份生效的场景。
    private static func vacuumInto(source: URL, target: URL) -> Bool {
        guard let database = try? Database(fileURL: source) else { return false }
        // 路径理论上可能含单引号，按 SQL 字面量规则转义。
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        return (try? database.execute("VACUUM INTO '\(escaped)';")) != nil
    }

    static func prune() {
        let manager = FileManager.default
        let files = ((try? manager.contentsOfDirectory(
            at: AppPaths.backups,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == "sqlite" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
        for file in files.dropFirst(keepCount) {
            try? manager.removeItem(at: file)
        }
    }
}
