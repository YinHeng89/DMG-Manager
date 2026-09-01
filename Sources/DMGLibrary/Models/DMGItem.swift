import Foundation

/// 一条 DMG 记录。
///
/// 关键设计：**元数据与文件彻底分离**。这里存的任何字段都不会写回原始 DMG，
/// 原始文件的名称 / 内容 / 位置永远由用户自己掌控，我们只负责管理「认知」。
struct DMGItem: Identifiable, Hashable {
    var id: Int64
    var path: String
    var filename: String

    // 用户维护的元数据
    var displayName: String
    /// 用户是否手动改过名字。为 true 时重新解析不会用 App 名覆盖 `displayName`。
    var displayNameIsCustom: Bool
    var note: String
    var category: String
    var favorite: Bool
    var tags: [String]

    // 文件系统事实
    var fileSize: Int64
    var fileCreatedAt: Date?
    var fileModifiedAt: Date?
    var sha256: String?
    var volumeName: String?

    // DMG 内 App 解析结果
    var appName: String?
    var bundleID: String?
    var version: String?
    var build: String?
    var developer: String?
    var architecture: Architecture
    var minimumOS: String?
    var appRelativePath: String?
    var iconFilename: String?

    // 安装状态
    var installedVersion: String?
    var installedPath: String?

    // 库内状态
    var parseStatus: ParseStatus
    var parseError: String?
    var lastOpenedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: Int64 = 0,
        path: String = "",
        filename: String = "",
        displayName: String = "",
        displayNameIsCustom: Bool = false,
        note: String = "",
        category: String = CategoryPresets.uncategorized,
        favorite: Bool = false,
        tags: [String] = [],
        fileSize: Int64 = 0,
        fileCreatedAt: Date? = nil,
        fileModifiedAt: Date? = nil,
        sha256: String? = nil,
        volumeName: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil,
        version: String? = nil,
        build: String? = nil,
        developer: String? = nil,
        architecture: Architecture = .unknown,
        minimumOS: String? = nil,
        appRelativePath: String? = nil,
        iconFilename: String? = nil,
        installedVersion: String? = nil,
        installedPath: String? = nil,
        parseStatus: ParseStatus = .pending,
        parseError: String? = nil,
        lastOpenedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.filename = filename
        self.displayName = displayName
        self.displayNameIsCustom = displayNameIsCustom
        self.note = note
        self.category = category
        self.favorite = favorite
        self.tags = tags
        self.fileSize = fileSize
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.sha256 = sha256
        self.volumeName = volumeName
        self.appName = appName
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.developer = developer
        self.architecture = architecture
        self.minimumOS = minimumOS
        self.appRelativePath = appRelativePath
        self.iconFilename = iconFilename
        self.installedVersion = installedVersion
        self.installedPath = installedPath
        self.parseStatus = parseStatus
        self.parseError = parseError
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 列表 / 详情展示用的名称：自定义名称优先，其次 App 名，最后回落到文件名。
    var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let appName, !appName.isEmpty { return appName }
        return filename.deletingDMGExtension
    }

    var fileURL: URL { URL(fileURLWithPath: path) }
    var directoryURL: URL { fileURL.deletingLastPathComponent() }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// 安装状态：把 DMG 版本与系统已安装版本做比较。
    var installStatus: InstallStatus {
        switch (version, installedVersion) {
        case (nil, nil): return .unknown
        case (_, nil): return .notInstalled
        case (nil, let installed?): return .installed(version: installed)
        case (let dmgVersion?, let installed?):
            switch VersionComparator.compare(dmgVersion, installed) {
            case .orderedSame: return .installed(version: installed)
            case .orderedAscending: return .outdated(installedVersion: installed)
            case .orderedDescending: return .newerThanInstalled(installedVersion: installed)
            }
        }
    }

    /// 用于分组「版本库」的稳定键：优先 Bundle ID，其次规范化后的 App 名。
    var groupingKey: String {
        if let bundleID, !bundleID.isEmpty { return "id:" + bundleID }
        let name = (appName ?? filename.deletingDMGExtension).lowercased()
        return "name:" + name
    }
}

// MARK: - 预览与测试样本

extension DMGItem {
    static func sample(
        id: Int64 = 1,
        path: String = "/Users/me/Downloads/GoogleChrome-139.0.7258-arm64.dmg",
        displayName: String = "Google Chrome",
        version: String = "139.0.7258.76",
        architecture: Architecture = .appleSilicon,
        installedVersion: String? = "139.0.7258.76",
        favorite: Bool = false,
        tags: [String] = ["浏览器", "ARM64"]
    ) -> DMGItem {
        DMGItem(
            id: id,
            path: path,
            filename: (path as NSString).lastPathComponent,
            displayName: displayName,
            note: "工作电脑主力浏览器，暂不升级。",
            category: "浏览器",
            favorite: favorite,
            tags: tags,
            fileSize: 191_365_120,
            fileCreatedAt: Date().addingTimeInterval(-86_400 * 12),
            fileModifiedAt: Date().addingTimeInterval(-86_400 * 12),
            sha256: "5f4dcc3b5aa765d61d8327deb882cf99",
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            version: version,
            build: "7258.76",
            developer: "Google LLC",
            architecture: architecture,
            minimumOS: "11.0",
            appRelativePath: "Google Chrome.app",
            installedVersion: installedVersion,
            parseStatus: .parsed,
            createdAt: Date().addingTimeInterval(-86_400 * 10),
            updatedAt: Date().addingTimeInterval(-86_400)
        )
    }
}
