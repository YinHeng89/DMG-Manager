import Foundation

struct MountedVolume {
    let mountPoint: URL
    let volumeName: String?
}

/// 用 hdiutil 挂载 / 卸载磁盘镜像。
///
/// 挂载后只读访问，全程不修改原始 DMG —— 这是产品的第一原则。
enum DiskImageService {
    private static let hdiutil = "/usr/bin/hdiutil"

    static func attach(imageURL: URL) throws -> MountedVolume {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = [
            "attach", imageURL.path,
            // 强制只读挂载。产品第一原则是「永不修改原始 DMG」：
            // hdiutil 默认按镜像自身的可写属性挂载，UDRW 这类可写格式会被挂成读写，
            // 挂载过程就可能写回卷元数据、改动文件的时间戳。只读挂载对解析和安装
            // （都是「从挂载点拷出去」）都完全够用。
            "-readonly",
            "-nobrowse",      // 不在 Finder / 桌面显示
            "-noautoopen",    // 不自动弹出窗口
            "-mountrandom",   // 随机挂载点，避免与已有卷冲突
            mountRoot,
            "-plist"
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw DMGServiceError.attachFailed(imageURL.path, detail: error.localizedDescription)
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DMGServiceError.attachFailed(imageURL.path, detail: detail.isEmpty ? Preferences.shared.t("disk.attachReturned", process.terminationStatus) : detail)
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return MountedVolume(
                    mountPoint: URL(fileURLWithPath: mountPoint),
                    volumeName: entity["volume-name"] as? String
                )
            }
        }
        throw DMGServiceError.attachFailed(imageURL.path, detail: Preferences.shared.t("disk.noFilesystem"))
    }

    static func detach(mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static var mountRoot: String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DMGLibraryMounts")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
