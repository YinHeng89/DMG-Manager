import Foundation

extension String {
    /// `Chrome_139_arm64.dmg` → `Chrome_139_arm64`
    var deletingDMGExtension: String {
        let base = (self as NSString).deletingPathExtension
        return base.isEmpty ? self : base
    }

    /// 从文件名猜测软件名：`Install_MarsEdit_5.8.3.dmg` → `MarsEdit`
    var guessedAppName: String {
        var base = deletingDMGExtension
        // 去掉常见前后缀词
        let noiseWords = ["install", "installer", "setup", "macos", "mac", "darwin", "dmg", "pkg", "latest", "stable"]
        let archWords = ["arm64", "aarch64", "x64", "x86_64", "intel", "universal", "apple", "silicon", "m1", "m2", "m3"]

        var parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
        parts = parts.filter { part in
            let lower = part.lowercased()
            if noiseWords.contains(lower) { return false }
            if archWords.contains(lower) { return false }
            // 纯版本号段（5.8.3 / 139 / 1.5）
            if lower.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
            return true
        }
        if parts.isEmpty { return base }
        return parts.joined(separator: " ")
    }
}

enum ByteFormatter {
    static func string(fromBytes bytes: Int64) -> String {
        guard bytes >= 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

enum DateFormatterHelper {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func relativeString(from date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }
}
