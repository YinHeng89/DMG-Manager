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
        try? FileManager.default.copyItem(at: database, to: target)
        prune()
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
