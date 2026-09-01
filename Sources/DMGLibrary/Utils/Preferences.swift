import SwiftUI
import Foundation

/// 界面语言。默认跟随系统，用户可在「设置 → 通用」中手动切换。
enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 菜单里展示用的名称（不随语言切换，方便对照）。
    var label: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 外观模式。系统 / 浅色 / 深色。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// 映射到 SwiftUI 的 colorScheme；system 返回 nil（交给系统）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 全局偏好：语言 + 外观。
///
/// 刻意不标记为 `@MainActor`：字符串查表是纯只读操作，枚举的 `displayName`/`title`
/// 也会在非视图上下文（例如排序比较、后台遍历）里被调用，标了 MainActor 反而到处报错。
/// 所有写操作都来自 SwiftUI 的 Picker（主线程），没有并发风险。
@Observable
final class Preferences {

    /// 全 App 共享单例，通过 `.environment(Preferences.shared)` 注入各视图。
    static let shared = Preferences()

    var language: AppLanguage
    var appearance: AppAppearance

    private let defaults = UserDefaults.standard
    private let langKey = "DMGLibrary.Language"
    private let appearanceKey = "DMGLibrary.Appearance"

    init() {
        if let raw = defaults.string(forKey: langKey), let lang = AppLanguage(rawValue: raw) {
            language = lang
        } else {
            language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
        }

        if let raw = defaults.string(forKey: appearanceKey), let value = AppAppearance(rawValue: raw) {
            appearance = value
        } else {
            appearance = .system
        }
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        defaults.set(lang.rawValue, forKey: langKey)
    }

    func setAppearance(_ value: AppAppearance) {
        appearance = value
        defaults.set(value.rawValue, forKey: appearanceKey)
    }

    /// 取文案。中文是兜底语言：某 key 在目标语言缺失时回落到中文，再缺失则回落到 key 本身。
    /// 支持 `%d` / `%@` 等 `String(format:)` 占位符。
    func t(_ key: String, _ args: CVarArg...) -> String {
        let entry = Self.table[key]
        let template = entry?[language] ?? entry?[.chinese] ?? key
        if args.isEmpty { return template }
        return String(format: template, arguments: args)
    }
}

// MARK: - 文案表

extension Preferences {
    /// key → (语言 → 文案)。新增语言只需在此扩展每一行。
    private static let table: [String: [AppLanguage: String]] = [

        // MARK: 枚举展示名（Enums.swift）

        "arch.unknown": [.chinese: "未知", .english: "Unknown"],

        "parse.pending": [.chinese: "等待解析", .english: "Pending"],
        "parse.parsing": [.chinese: "解析中", .english: "Parsing"],
        "parse.parsed": [.chinese: "已解析", .english: "Parsed"],
        "parse.noApp": [.chinese: "无 App", .english: "No App"],
        "parse.failed": [.chinese: "解析失败", .english: "Failed"],
        "parse.missing": [.chinese: "文件失联", .english: "Missing"],

        "install.installed": [.chinese: "已安装", .english: "Installed"],
        "install.outdated": [.chinese: "旧版本", .english: "Outdated"],
        "install.newer": [.chinese: "有更新", .english: "Update available"],
        "install.notInstalled": [.chinese: "未安装", .english: "Not installed"],
        "install.unknown": [.chinese: "未知", .english: "Unknown"],
        "status.outdated.installed": [.chinese: "旧版本 · 已装 %@", .english: "Outdated · installed %@"],
        "status.upgrade.installed": [.chinese: "可升级 · 已装 %@", .english: "Upgrade available · installed %@"],

        "smart.all": [.chinese: "全部", .english: "All"],
        "smart.favorites": [.chinese: "收藏", .english: "Favorites"],
        "smart.recent": [.chinese: "最近添加", .english: "Recently added"],
        "smart.recentlyUsed": [.chinese: "最近使用", .english: "Recently used"],
        "smart.missing": [.chinese: "文件失联", .english: "Missing files"],
        "smart.duplicates": [.chinese: "重复文件", .english: "Duplicates"],

        "statusfilter.installed": [.chinese: "已安装", .english: "Installed"],
        "statusfilter.newer": [.chinese: "有更新", .english: "Update available"],
        "statusfilter.outdated": [.chinese: "旧版本", .english: "Outdated"],
        "statusfilter.notInstalled": [.chinese: "未安装", .english: "Not installed"],
        "statusfilter.unknown": [.chinese: "未知", .english: "Unknown"],

        "browse.list": [.chinese: "列表视图", .english: "List view"],
        "browse.grid": [.chinese: "图标视图", .english: "Icon view"],

        "sort.name": [.chinese: "名称", .english: "Name"],
        "sort.version": [.chinese: "版本", .english: "Version"],
        "sort.size": [.chinese: "大小", .english: "Size"],
        "sort.addedAt": [.chinese: "添加时间", .english: "Date added"],
        "sort.modifiedAt": [.chinese: "修改时间", .english: "Date modified"],

        // MARK: 主窗口（ContentView.swift）

        "search.prompt": [.chinese: "搜索名称 / 备注 / 标签 / Bundle ID",
                          .english: "Search name / note / tag / Bundle ID"],
        "remove.fromLibrary.title": [.chinese: "从资料库中移除", .english: "Remove from library"],
        "remove.onlyMeta": [.chinese: "仅从资料库移除", .english: "Remove from library only"],
        "remove.toTrash": [.chinese: "移到废纸篓", .english: "Move to Trash"],
        "remove.cancel": [.chinese: "取消", .english: "Cancel"],
        "remove.message": [.chinese: "元数据会被删除，但原始 DMG 文件不会被修改。选择「移到废纸篓」会同时删除磁盘上的文件。",
                           .english: "Metadata is deleted, but the original DMG file is left untouched. Choosing “Move to Trash” also deletes the file on disk."],
        "alert.error": [.chinese: "出错了", .english: "Something went wrong"],
        "alert.ok": [.chinese: "好", .english: "OK"],
        "panel.add.message": [.chinese: "选择要加入资料库的 DMG 文件", .english: "Choose DMG files to add to the library"],
        "panel.add.prompt": [.chinese: "添加", .english: "Add"],
        "panel.scan.message": [.chinese: "选择要扫描的文件夹", .english: "Choose a folder to scan"],
        "panel.scan.prompt": [.chinese: "扫描", .english: "Scan"],
        "tb.add": [.chinese: "添加", .english: "Add"],
        "tb.add.help": [.chinese: "添加 DMG 到资料库", .english: "Add DMG to library"],
        "tb.scanFolder": [.chinese: "扫描文件夹…", .english: "Scan folder…"],
        "tb.scanAll": [.chinese: "扫描所有目录", .english: "Scan all directories"],
        "tb.reparseList": [.chinese: "重新解析当前列表", .english: "Re-parse current list"],
        "tb.refreshInstall": [.chinese: "刷新安装状态", .english: "Refresh install status"],
        "tb.fillHashes": [.chinese: "补齐校验和", .english: "Fill in checksums"],
        "tb.more": [.chinese: "操作", .english: "Actions"],
        "tb.filter": [.chinese: "筛选", .english: "Filter"],
        "tb.filter.help": [.chinese: "高级筛选", .english: "Advanced filters"],
        "tb.view": [.chinese: "视图", .english: "View"],
        "tb.view.help": [.chinese: "切换列表 / 图标视图", .english: "Switch list / icon view"],
        "drop.release": [.chinese: "松手即可加入资料库", .english: "Drop to add to library"],
        "drop.hint": [.chinese: "原始文件不会被移动或修改", .english: "Original files are never moved or modified"],
        "drop.onlyDmg": [.chinese: "只支持 .dmg 文件", .english: "Only .dmg files are supported"],
        "browser.collapsed": [.chinese: "已折叠 %d 个旧版本", .english: "Collapsed %d old versions"],
        "browser.itemCount": [.chinese: "%d 项", .english: "%d items"],
        "import.adding": [.chinese: "正在添加", .english: "Adding"],
        "import.parsing": [.chinese: "正在解析", .english: "Parsing"],
        "scan.doneAdded": [.chinese: "启动扫描完成 · 新增 %d 个 DMG（共扫描 %d 个文件）",
                           .english: "Startup scan complete · %d new DMG added (scanned %d files)"],
        "scan.doneLatest": [.chinese: "启动扫描完成 · 资料库已是最新（扫描 %d 个文件）",
                            .english: "Startup scan complete · library is up to date (scanned %d files)"],
        "empty.noMatch": [.chinese: "没有匹配结果", .english: "No matching results"],
        "empty.noFavorites": [.chinese: "还没有收藏", .english: "No favorites yet"],
        "empty.noMissing": [.chinese: "没有失联文件", .english: "No missing files"],
        "empty.noDuplicates": [.chinese: "没有重复文件", .english: "No duplicates"],
        "empty.noRecent": [.chinese: "还没有打开记录", .english: "No open history yet"],
        "empty.empty": [.chinese: "资料库是空的", .english: "The library is empty"],
        "empty.noMatch.hint": [.chinese: "试试其他关键词，或清空搜索框。",
                               .english: "Try another keyword, or clear the search box."],
        "empty.addHint": [.chinese: "把 DMG 拖进窗口，或扫描整个下载文件夹。",
                          .english: "Drag a DMG into the window, or scan your Downloads folder."],
        "statusbar.totalSize": [.chinese: "总大小 %@", .english: "Total size %@"],

        // MARK: 详情（DetailView.swift）

        "detail.none.title": [.chinese: "未选择安装包", .english: "No package selected"],
        "detail.none.desc": [.chinese: "从中间列表里选一个 DMG，这里会显示它的全部信息。",
                             .english: "Pick a DMG from the list to see its full information."],
        "detail.name.placeholder": [.chinese: "显示名称", .english: "Display name"],
        "detail.fav.on": [.chinese: "取消收藏", .english: "Unfavorite"],
        "detail.fav.off": [.chinese: "收藏", .english: "Favorite"],
        "missing.title": [.chinese: "文件位置已改变", .english: "File location changed"],
        "missing.path": [.chinese: "原始路径：", .english: "Original path:"],
        "missing.relocate": [.chinese: "重新定位…", .english: "Relocate…"],
        "missing.auto": [.chinese: "自动查找…", .english: "Auto locate…"],
        "missing.remove": [.chinese: "从资料库移除", .english: "Remove from library"],
        "parse.error": [.chinese: "解析失败", .english: "Parse failed"],
        "parse.fileGone": [.chinese: "原始文件已不存在", .english: "Original file no longer exists"],
        "parse.noAppInside": [.chinese: "镜像内没有找到 .app", .english: "No .app found inside the image"],
        "disk.attachReturned": [.chinese: "hdiutil 返回 %d", .english: "hdiutil returned %d"],
        "disk.noFilesystem": [.chinese: "镜像内没有可挂载的文件系统", .english: "No mountable filesystem inside the image"],
        "action.open": [.chinese: "打开", .english: "Open"],
        "action.finder": [.chinese: "Finder", .english: "Finder"],
        "action.unmount": [.chinese: "卸载", .english: "Unmount"],
        "action.showVolume": [.chinese: "显示卷", .english: "Show volume"],
        "action.mount": [.chinese: "挂载", .english: "Mount"],
        "action.copyPath": [.chinese: "复制路径", .english: "Copy path"],
        "action.install": [.chinese: "安装", .english: "Install"],
        "meta.title": [.chinese: "安装包信息", .english: "Package info"],
        "meta.file": [.chinese: "原始文件", .english: "Original file"],
        "meta.size": [.chinese: "大小", .english: "Size"],
        "meta.appName": [.chinese: "App 名称", .english: "App name"],
        "meta.developer": [.chinese: "开发者", .english: "Developer"],
        "meta.bundleID": [.chinese: "Bundle ID", .english: "Bundle ID"],
        "meta.minOS": [.chinese: "最低系统", .english: "Minimum OS"],
        "meta.installed": [.chinese: "已安装", .english: "Installed"],
        "meta.modified": [.chinese: "修改时间", .english: "Modified"],
        "meta.sha": [.chinese: "SHA-256", .english: "SHA-256"],
        "meta.path": [.chinese: "路径", .english: "Path"],
        "note.title": [.chinese: "备注", .english: "Note"],
        "note.saved": [.chinese: "已保存", .english: "Saved"],
        "note.saving": [.chinese: "保存中…", .english: "Saving…"],
        "note.preview": [.chinese: "预览", .english: "Preview"],
        "note.edit": [.chinese: "编辑", .english: "Edit"],
        "note.mode": [.chinese: "模式", .english: "Mode"],
        "detail.version": [.chinese: "版本", .english: "Version"],
        "note.empty": [.chinese: "暂无备注", .english: "No note yet"],
        "tag.title": [.chinese: "标签", .english: "Tags"],
        "tag.add": [.chinese: "添加标签", .english: "Add tag"],
        "tag.suggested": [.chinese: "常用标签", .english: "Suggested tags"],
        "category.title": [.chinese: "分类", .english: "Category"],
        "category.new": [.chinese: "新建分类", .english: "New category"],
        "category.blocked": [.chinese: "有条目正在使用这个分类，不能删除",
                             .english: "This category is in use and cannot be deleted"],
        "version.title": [.chinese: "版本库 · %d 个版本", .english: "Version history · %d versions"],
        "version.hint": [.chinese: "列表默认显示最新版本，切换后上方信息随之更新。",
                         .english: "The list shows the latest version by default; switching updates the info above."],
        "version.latest": [.chinese: "最新", .english: "Latest"],
        "unknown.version": [.chinese: "未知版本", .english: "Unknown version"],
        "footer.reparse": [.chinese: "重新解析", .english: "Re-parse"],
        "footer.delete": [.chinese: "删除", .english: "Delete"],
        "install.title": [.chinese: "安装到 /Applications", .english: "Install to /Applications"],
        "install.confirm": [.chinese: "安装", .english: "Install"],
        "install.cancel": [.chinese: "取消", .english: "Cancel"],
        "install.message": [.chinese: "会把 DMG 内的 %@ 复制到 /Applications。已存在的同名 App 会先移到废纸篓。",
                            .english: "Copies %@ from the DMG to /Applications. An existing app with the same name is moved to Trash first."],
        "delete.title": [.chinese: "删除", .english: "Delete"],
        "delete.onlyMeta": [.chinese: "仅从资料库移除", .english: "Remove from library only"],
        "delete.toTrash": [.chinese: "移到废纸篓", .english: "Move to Trash"],
        "delete.cancel": [.chinese: "取消", .english: "Cancel"],
        "delete.message": [.chinese: "删除后这条记录的名称、备注、标签都会消失。原始 DMG 只有在「移到废纸篓」时才会被删除。",
                           .english: "Deleting removes this record’s name, note, and tags. The original DMG is only deleted when you choose “Move to Trash”."],
        "remove.title": [.chinese: "从资料库移除", .english: "Remove from library"],
        "remove.confirm": [.chinese: "移除这条记录", .english: "Remove this record"],
        "flash.relocated": [.chinese: "已重新定位到 %@", .english: "Relocated to %@"],
        "flash.pathCopied": [.chinese: "路径已复制", .english: "Path copied"],
        "flash.copied": [.chinese: "已复制到 /Applications", .english: "Copied to /Applications"],
        "flash.installFailed": [.chinese: "安装失败：%@", .english: "Install failed: %@"],
        "flash.removed": [.chinese: "已从资料库移除", .english: "Removed from library"],
        "flash.reconnected": [.chinese: "已自动重新连接", .english: "Automatically reconnected"],
        "flash.notFound": [.chinese: "没有找到匹配的文件", .english: "No matching file found"],

        // MARK: 设置（SettingsView.swift）

        "settings.general": [.chinese: "通用", .english: "General"],
        "settings.library": [.chinese: "资料库", .english: "Library"],
        "settings.data": [.chinese: "数据", .english: "Data"],
        "settings.about": [.chinese: "关于", .english: "About"],
        "settings.defaultView": [.chinese: "默认视图", .english: "Default view"],
        "settings.list": [.chinese: "列表", .english: "List"],
        "settings.grid": [.chinese: "图标", .english: "Icons"],
        "settings.sort": [.chinese: "排序", .english: "Sort by"],
        "settings.ascending": [.chinese: "升序排列", .english: "Ascending"],
        "settings.noDirs": [.chinese: "还没有添加目录", .english: "No directories added yet"],
        "settings.addDir": [.chinese: "添加目录…", .english: "Add directory…"],
        "settings.scanDirs": [.chinese: "扫描目录", .english: "Scan directories"],
        "settings.scanDirs.footer": [.chinese: "目录用于扫描导入 DMG，以及文件失联时找回原文件。移除目录只是不再扫描它，已入库的条目会保留。导入与解析请在主窗口的「操作」菜单里进行。",
                                     .english: "Directories are used to scan and import DMGs, and to locate missing files. Removing a directory only stops scanning it; imported items stay. Import and parsing happen from the main window’s “Actions” menu."],
        "settings.removeDir.help": [.chinese: "移除目录（不会删除已入库的条目）",
                                    .english: "Remove directory (imported items are kept)"],
        "settings.dirMissing": [.chinese: "目录已不存在，可能已被删除或移动",
                                .english: "Directory no longer exists; it may have been deleted or moved"],
        "settings.dataLocation": [.chinese: "数据位置", .english: "Data location"],
        "settings.showInFinder": [.chinese: "在 Finder 中显示", .english: "Show in Finder"],
        "settings.openIconCache": [.chinese: "打开图标缓存", .english: "Open icon cache"],
        "settings.backupNow": [.chinese: "立即备份", .english: "Back up now"],
        "settings.backedUp": [.chinese: "已备份", .english: "Backed up"],
        "settings.openBackupDir": [.chinese: "打开备份目录", .english: "Open backup folder"],
        "settings.backup": [.chinese: "备份", .english: "Backups"],
        "settings.backup.footer": [.chinese: "启动时自动快照，最多保留 %d 份。数据库使用 WAL 模式，崩溃也不会丢备注。",
                                   .english: "Automatic snapshots at launch, keeping up to %d copies. The database uses WAL mode, so notes survive crashes."],
        "settings.stats": [.chinese: "统计", .english: "Statistics"],
        "settings.stat.packages": [.chinese: "安装包", .english: "Packages"],
        "settings.stat.tags": [.chinese: "标签", .english: "Tags"],
        "settings.stat.categories": [.chinese: "分类", .english: "Categories"],
        "settings.stat.totalSize": [.chinese: "总大小", .english: "Total size"],
        "about.subtitle": [.chinese: "一个不改变原始文件的 Mac 安装包资料库",
                           .english: "A Mac DMG library that never touches your original files"],
        "about.tagline": [.chinese: "Keep the file. Organize the meaning.\n文件不动，信息由你定义。",
                          .english: "Keep the file. Organize the meaning."],
        "about.noAccount": [.chinese: "无账号、无服务器、无云端、无遥测",
                            .english: "No account, no server, no cloud, no telemetry"],
        "about.localOnly": [.chinese: "所有数据只存在你的 Mac 上", .english: "All data lives only on your Mac"],
        "about.untouched": [.chinese: "原始 DMG 永不被重命名、移动或修改",
                            .english: "Original DMGs are never renamed, moved, or modified"],

        // MARK: 侧边栏（SidebarView.swift）

        "sidebar.library": [.chinese: "资料库", .english: "Library"],
        "sidebar.categories": [.chinese: "分类", .english: "Categories"],
        "sidebar.tags": [.chinese: "标签", .english: "Tags"],

        // MARK: 筛选面板（FilterPanelView.swift）

        "filter.title": [.chinese: "高级筛选", .english: "Advanced filters"],
        "filter.clear": [.chinese: "清除全部", .english: "Clear all"],
        "filter.done": [.chinese: "完成", .english: "Done"],
        "filter.arch": [.chinese: "架构", .english: "Architecture"],
        "filter.install": [.chinese: "安装状态", .english: "Install status"],
        "filter.parse": [.chinese: "解析状态", .english: "Parse status"],
        "filter.category": [.chinese: "分类", .english: "Category"],
        "filter.tag": [.chinese: "标签", .english: "Tags"],

        // MARK: 菜单栏（MenuBarView.swift）

        "menu.search": [.chinese: "搜索 DMG", .english: "Search DMG"],
        "menu.add": [.chinese: "添加 DMG…", .english: "Add DMG…"],
        "menu.scan": [.chinese: "扫描文件夹…", .english: "Scan folder…"],
        "menu.favorites": [.chinese: "收藏 · %d", .english: "Favorites · %d"],
        "menu.recent": [.chinese: "最近添加 · %d", .english: "Recently added · %d"],
        "menu.noFavorites": [.chinese: "还没有收藏", .english: "No favorites yet"],
        "menu.noRecent": [.chinese: "最近没有新增", .english: "Nothing added recently"],
        "menu.openWindow": [.chinese: "打开主窗口", .english: "Open main window"],
        "menu.settings": [.chinese: "设置…", .english: "Settings…"],

        // MARK: 应用级（DMGLibraryApp.swift）

        "app.add": [.chinese: "添加 DMG…", .english: "Add DMG…"],
        "app.scan": [.chinese: "扫描文件夹…", .english: "Scan folder…"],
        "app.quickSearch": [.chinese: "快速搜索", .english: "Quick search"],
        "app.dbNotReady": [.chinese: "数据库未就绪", .english: "Database not ready"],
        "app.cannotOpen": [.chinese: "无法打开数据库", .english: "Cannot open database"],
        "app.dbWritable": [.chinese: "请检查 ~/Library/Application Support/DMGLibrary 是否可写。",
                           .english: "Check that ~/Library/Application Support/DMGLibrary is writable."],

        // MARK: 外观

        "appearance.system": [.chinese: "跟随系统", .english: "System"],
        "appearance.light": [.chinese: "浅色", .english: "Light"],
        "appearance.dark": [.chinese: "深色", .english: "Dark"],
        "settings.language": [.chinese: "语言", .english: "Language"],
        "settings.appearance": [.chinese: "外观", .english: "Appearance"],
    ]
}
