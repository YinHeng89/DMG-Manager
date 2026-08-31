import Foundation

enum DMGScanner {
    /// 递归扫描文件夹里的所有 .dmg（跳过隐藏文件与包内容）。
    static func scan(url: URL, limit: Int = 500) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "dmg" else { continue }
            results.append(fileURL)
            if results.count >= limit { break }
        }
        return results
    }
}

/// 基于关键词的规则分类。第一版不需要 AI，规则匹配已经够用。
enum SmartCategorizer {
    private static let rules: [(category: String, keywords: [String])] = [
        ("浏览器", ["chrome", "chromium", "firefox", "safari", "edge", "arc", "brave", "opera",
                    "vivaldi", "browser", "浏览器"]),
        ("开发工具", ["xcode", "cursor", "vscode", "visual studio", "sublime", "intellij", "pycharm",
                      "webstorm", "goland", "rider", "android studio", "docker", "orbstack", "podman",
                      "node", "python", "java", "git", "iterm", "warp", "terminal", "code", "dev",
                      "开发"]),
        ("网络工具", ["clash", "vpn", "proxy", "shadowsocks", "v2ray", "surge", "wireshark",
                      "charles", "postman", "tailscale", "zerotier", "network", "网络", "代理"]),
        ("多媒体", ["iina", "vlc", "spotify", "ffmpeg", "obs", "quicktime", "handbrake", "music",
                     "player", "playerx", "音乐", "播放器", "视频"]),
        ("游戏", ["steam", "epic", "game", "whisky", "crossover", "unity", "unreal", "游戏"]),
        ("办公", ["office", "word", "excel", "powerpoint", "wps", "notion", "obsidian", "typora",
                   "keynote", "numbers", "pages", "dingtalk", "feishu", "wecom", "wechat", "微信",
                   "钉钉", "飞书", "办公", "文档"]),
        ("设计", ["figma", "sketch", "photoshop", "illustrator", "affinity", "pixelmator", "blender",
                   "canva", "design", "设计"]),
        ("系统工具", ["cleanmymac", "istat", "stats", "monitor", "unarchiver", "keka", "raycast",
                       "alfred", "hammerspoon", "rectangle", "utility", "清理", "系统", "工具"]),
        ("驱动", ["driver", "驱动", "printer", "打印机", "firmware"])
    ]

    static func category(for text: String) -> String {
        let lowercased = text.lowercased()
        for rule in rules {
            if rule.keywords.contains(where: { lowercased.contains($0) }) {
                return rule.category
            }
        }
        return CategoryPresets.uncategorized
    }
}
