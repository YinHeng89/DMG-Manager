import Foundation
import XCTest

/// 造一个真实的 DMG：包含 .app（Info.plist + 可执行 + 图标），用 hdiutil 打包。
///
/// 目的是验证「挂载 → 找 App → 读 plist → 读 Mach-O」这条完整链路，而不是靠 mock。
enum TestDMGFactory {
    struct Bundle {
        let dmgURL: URL
        let appName: String
        let executable: URL
    }

    static func makeDMG(
        in directory: URL,
        name: String,
        appName: String = "TestApp",
        version: String = "1.2.3",
        build: String = "456",
        bundleID: String = "com.example.testapp",
        executableSource: URL = URL(fileURLWithPath: "/usr/bin/true"),
        minimumOS: String = "12.0"
    ) throws -> Bundle {
        let root = directory.appendingPathComponent("source-\(UUID().uuidString)")
        let appURL = root.appendingPathComponent("\(appName).app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleName": appName,
            "CFBundleDisplayName": appName,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": appName,
            "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": minimumOS
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = contents.appendingPathComponent("MacOS").appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: executable.path) {
            try FileManager.default.removeItem(at: executable)
        }
        try FileManager.default.copyItem(at: executableSource, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // 用系统自带的通用应用图标，验证 icns → PNG 提取
        let systemIcon = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
        if FileManager.default.fileExists(atPath: systemIcon.path) {
            try? FileManager.default.copyItem(
                at: systemIcon,
                to: contents.appendingPathComponent("Resources").appendingPathComponent("AppIcon.icns")
            )
        }

        let dmgURL = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-srcfolder", root.path, "-format", "UDZO", "-quiet", "-ov", dmgURL.path]
        let error = Pipe()
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "TestDMGFactory", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "hdiutil create 失败: \(message)"])
        }

        return Bundle(dmgURL: dmgURL, appName: appName, executable: executable)
    }
}
