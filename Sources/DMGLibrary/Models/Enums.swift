import Foundation

/// CPU 架构。DMG 内的可执行文件可能是单架构或通用二进制。
enum Architecture: String, Codable, CaseIterable, Identifiable {
    case appleSilicon
    case intel
    case universal
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSilicon: return "Apple Silicon"
        case .intel: return "Intel"
        case .universal: return "Universal"
        case .unknown: return "未知"
        }
    }

    /// 列表里的紧凑显示。
    var shortName: String {
        switch self {
        case .appleSilicon: return "ARM64"
        case .intel: return "x86_64"
        case .universal: return "Universal"
        case .unknown: return "—"
        }
    }

    var symbolName: String {
        switch self {
        case .appleSilicon: return "apple.logo"
        case .intel: return "cpu"
        case .universal: return "cpu.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// 由 Mach-O cpu type 集合推导架构。
    static func make(archs: Set<UInt32>) -> Architecture {
        guard !archs.isEmpty else { return .unknown }
        let arm = archs.contains(CPU_TYPE_ARM64)
        let intel = archs.contains(CPU_TYPE_X86_64)
        if arm && intel { return .universal }
        if arm { return .appleSilicon }
        if intel { return .intel }
        return .unknown
    }
}

let CPU_TYPE_X86_64: UInt32 = 0x0100_0007
let CPU_TYPE_ARM64: UInt32 = 0x0100_000C

/// DMG 解析结果。
enum ParseStatus: String, Codable, CaseIterable {
    case pending    // 已入库，排队等待解析
    case parsing    // 正在挂载 / 读取中
    case parsed     // 已解析出 App
    case noApp      // 挂载成功但里面没有 .app（可能是驱动包 / 数据包）
    case failed     // 挂载或读取失败（加密、损坏…）
    case missing    // 原始文件失联

    var displayName: String {
        switch self {
        case .pending: return "等待解析"
        case .parsing: return "解析中"
        case .parsed: return "已解析"
        case .noApp: return "无 App"
        case .failed: return "解析失败"
        case .missing: return "文件失联"
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock"
        case .parsing: return "arrow.triangle.2.circlepath"
        case .parsed: return "checkmark.circle.fill"
        case .noApp: return "doc.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .missing: return "questionmark.folder.fill"
        }
    }

    var isResolved: Bool {
        self == .parsed || self == .noApp || self == .failed || self == .missing
    }
}

/// 与系统已安装版本的比较结果。
enum InstallStatus {
    case installed(version: String)
    case outdated(installedVersion: String)          // DMG 版本更旧
    case newerThanInstalled(installedVersion: String) // DMG 版本更新，可升级
    case notInstalled
    case unknown

    var displayName: String {
        switch self {
        case .installed: return "已安装"
        case .outdated: return "旧版本"
        case .newerThanInstalled: return "有更新"
        case .notInstalled: return "未安装"
        case .unknown: return "未知"
        }
    }

    var symbolName: String {
        switch self {
        case .installed: return "checkmark.circle.fill"
        case .outdated: return "arrow.down.circle.fill"
        case .newerThanInstalled: return "arrow.up.circle.fill"
        case .notInstalled: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// 左侧边栏的智能分组。
enum SmartList: String, CaseIterable, Identifiable {
    case all
    case favorites
    case recent
    case recentlyUsed
    case missing
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .recent: return "最近添加"
        case .recentlyUsed: return "最近使用"
        case .missing: return "文件失联"
        case .duplicates: return "重复文件"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .favorites: return "star"
        case .recent: return "clock.arrow.circlepath"
        case .recentlyUsed: return "clock"
        case .missing: return "exclamationmark.triangle"
        case .duplicates: return "doc.on.doc"
        }
    }
}

/// 预设分类。用户可自由添加自定义分类。
enum CategoryPresets {
    static let uncategorized = "未分类"

    static let builtin: [String] = [
        "浏览器", "开发工具", "网络工具", "多媒体", "游戏", "办公", "系统工具",
        "驱动", "设计", "未分类"
    ]
}

/// 高级筛选里可选的「安装状态」。
enum InstallStatusFilter: String, CaseIterable, Identifiable {
    case installed
    case newer
    case outdated
    case notInstalled
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed: return "已安装"
        case .newer: return "有更新"
        case .outdated: return "旧版本"
        case .notInstalled: return "未安装"
        case .unknown: return "未知"
        }
    }

    var symbolName: String {
        switch self {
        case .installed: return "checkmark.circle.fill"
        case .newer: return "arrow.up.circle.fill"
        case .outdated: return "arrow.down.circle.fill"
        case .notInstalled: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// 列表视图模式。
enum BrowseMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }

    var help: String {
        switch self {
        case .list: return "列表视图"
        case .grid: return "图标视图"
        }
    }
}

/// 排序字段。
enum SortField: String, CaseIterable, Identifiable {
    case name
    case version
    case size
    case addedAt
    case modifiedAt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .version: return "版本"
        case .size: return "大小"
        case .addedAt: return "添加时间"
        case .modifiedAt: return "修改时间"
        }
    }

    var sqlColumn: String {
        switch self {
        case .name: return "display_name"
        case .version: return "version"
        case .size: return "file_size"
        case .addedAt: return "created_at"
        case .modifiedAt: return "file_modified_at"
        }
    }
}
