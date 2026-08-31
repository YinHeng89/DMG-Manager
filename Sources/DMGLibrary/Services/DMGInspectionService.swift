import Foundation

/// 一次 DMG 解析的完整结果。
struct InspectionResult {
    var status: ParseStatus
    var volumeName: String?
    var appInfo: AppInfo?
    var iconFilename: String?
    var errorMessage: String?
}

/// 解析单个 DMG：挂载 → 找 App → 读 Info.plist / 架构 / 图标 → 卸载。
///
/// 只读访问，全程不修改原始文件。
enum DMGInspectionService {
    static func inspect(fileURL: URL, iconName: String = UUID().uuidString) -> InspectionResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return InspectionResult(status: .missing, errorMessage: "原始文件已不存在")
        }

        let volume: MountedVolume
        do {
            volume = try DiskImageService.attach(imageURL: fileURL)
        } catch {
            let message = error.localizedDescription
            return InspectionResult(status: .failed, errorMessage: message)
        }
        defer { DiskImageService.detach(mountPoint: volume.mountPoint) }

        guard let appURL = AppBundleInspector.findApps(in: volume.mountPoint).first else {
            return InspectionResult(status: .noApp, volumeName: volume.volumeName, errorMessage: "镜像内没有找到 .app")
        }

        let appInfo = AppBundleInspector.inspect(appURL: appURL, mountPoint: volume.mountPoint)
        var iconFilename: String?
        if let iconURL = appInfo.iconFileURL {
            iconFilename = IconStore.shared.save(iconFileAt: iconURL, name: iconName)
        }

        return InspectionResult(
            status: .parsed,
            volumeName: volume.volumeName,
            appInfo: appInfo,
            iconFilename: iconFilename
        )
    }

    /// 把解析结果合并到条目上。用户手写的名称 / 备注 / 标签不会被覆盖。
    static func apply(_ result: InspectionResult, to item: inout DMGItem) {
        item.parseStatus = result.status
        item.parseError = result.errorMessage
        item.volumeName = result.volumeName ?? item.volumeName

        guard let appInfo = result.appInfo else { return }

        item.appRelativePath = appInfo.relativePath
        item.appName = appInfo.name
        item.version = appInfo.version
        item.build = appInfo.build
        item.bundleID = appInfo.bundleID
        item.minimumOS = appInfo.minimumOS
        item.architecture = appInfo.architecture
        if let developer = appInfo.developer, !developer.isEmpty {
            item.developer = developer
        }

        // 首次解析时才用 App 名回填显示名，避免覆盖用户改名
        if item.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.displayName = appInfo.name
        }
    }
}
