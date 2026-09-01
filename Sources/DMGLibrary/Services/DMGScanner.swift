import Foundation

/// 一次目录扫描的结果。
struct DMGScanResult: Sendable {
    /// 扫描到的 .dmg 文件。
    let urls: [URL]
    /// 是否因为达到上限而提前停止。为 true 说明目录里还有没扫到的 .dmg。
    let truncated: Bool
}

enum DMGScanner {
    /// 递归扫描文件夹里的所有 .dmg（跳过隐藏文件与包内容）。
    ///
    /// 这是同步阻塞式遍历，调用方必须放到后台线程（例如 `Task.detached`），
    /// 否则大目录会一路卡住主线程、界面直接冻住。
    static func scan(url: URL, limit: Int = 500) -> DMGScanResult {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return DMGScanResult(urls: [], truncated: false) }

        var results: [URL] = []
        var truncated = false
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "dmg" else { continue }
            // 先判断再追加，这样恰好装下 limit 个时不会被误报为截断。
            if results.count >= limit {
                truncated = true
                break
            }
            results.append(fileURL)
        }
        return DMGScanResult(urls: results, truncated: truncated)
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
