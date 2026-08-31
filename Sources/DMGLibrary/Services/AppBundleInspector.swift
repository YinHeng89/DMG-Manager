import Foundation
import AppKit

/// 从挂载卷里读出来的 .app 信息。
struct AppInfo {
    var relativePath: String
    var name: String
    var version: String?
    var build: String?
    var bundleID: String?
    var minimumOS: String?
    var architecture: Architecture
    var developer: String?
    var iconFileURL: URL?

    var iconImage: NSImage? {
        guard let iconFileURL else { return nil }
        return NSImage(contentsOf: iconFileURL)
    }
}

enum AppBundleInspector {
    /// 在挂载点里寻找 .app。优先顶层，其次一层子目录（很多 DMG 会把 App 放在子文件夹里）。
    static func findApps(in mountPoint: URL) -> [URL] {
        let manager = FileManager.default
        var results: [URL] = []

        if let entries = try? manager.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension.lowercased() == "app" {
                results.append(entry)
            }
            // 一层子目录
            if results.isEmpty {
                for entry in entries {
                    guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                          values.isDirectory == true,
                          entry.pathExtension.lowercased() != "app" else { continue }
                    if let nested = try? manager.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        results.append(contentsOf: nested.filter { $0.pathExtension.lowercased() == "app" })
                    }
                }
            }
        }
        return results
    }

    /// 读取一个 .app 的完整信息。
    static func inspect(appURL: URL, mountPoint: URL) -> AppInfo {
        let info = readInfoPlist(appURL: appURL)

        let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        let iconFileName = (info?["CFBundleIconFile"] as? String) ?? (info?["CFBundleIconName"] as? String)
        let iconURL = iconURL(for: iconFileName, appURL: appURL)

        let executableName = (info?["CFBundleExecutable"] as? String)
            ?? (appURL.deletingPathExtension().lastPathComponent)
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)

        let architecture: Architecture
        if FileManager.default.fileExists(atPath: executableURL.path) {
            architecture = ArchitectureDetector.architecture(at: executableURL)
        } else {
            architecture = .unknown
        }

        let relativePath = appURL.path.replacingOccurrences(of: mountPoint.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return AppInfo(
            relativePath: relativePath,
            name: displayName,
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            bundleID: info?["CFBundleIdentifier"] as? String,
            minimumOS: info?["LSMinimumSystemVersion"] as? String,
            architecture: architecture,
            developer: SigningInfoReader.developer(appURL: appURL),
            iconFileURL: iconURL
        )
    }

    private static func readInfoPlist(appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// CFBundleIconFile 可能不带扩展名，这里做兼容。
    private static func iconURL(for iconFileName: String?, appURL: URL) -> URL? {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        guard let iconFileName, !iconFileName.isEmpty else {
            return firstIcon(in: resources)
        }
        var candidate = resources.appendingPathComponent(iconFileName)
        if candidate.pathExtension.isEmpty {
            candidate.appendPathExtension("icns")
        }
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return firstIcon(in: resources)
    }

    private static func firstIcon(in resources: URL) -> URL? {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates.first { $0.pathExtension.lowercased() == "icns" }
    }
}

/// 读取代码签名信息，用于显示开发者。
enum SigningInfoReader {
    static func developer(appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        )
        guard infoStatus == errSecSuccess, let info = information as? [String: Any] else { return nil }

        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let certificate = certificates.first {
            if let summary = SecCertificateCopySubjectSummary(certificate) as String? {
                return cleanDeveloper(summary)
            }
        }
        if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
            return teamID
        }
        return nil
    }

    /// `Developer ID Application: Google LLC (EQHXZ8M8AV)` → `Google LLC`
    private static func cleanDeveloper(_ raw: String) -> String {
        var text = raw
        if let colon = text.firstIndex(of: ":") {
            text = String(text[text.index(after: colon)...])
        }
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }
}
