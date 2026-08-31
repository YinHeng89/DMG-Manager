import Foundation
import AppKit

struct InstalledApp {
    var name: String
    var bundleID: String?
    var version: String?
    var url: URL
}

/// 扫描系统里已安装的 App，用于「安装状态 / 版本比较」。
///
/// 索引惰性构建并缓存；需要精确结果时可调用 `rebuild()`。
final class InstalledAppService: @unchecked Sendable {
    static let shared = InstalledAppService()

    private var byBundleID: [String: InstalledApp] = [:]
    private var byName: [String: InstalledApp] = [:]
    private var isIndexed = false
    private let lock = NSLock()

    private init() {}

    func rebuild() {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Developer/Applications")
        ]

        var bundleMap: [String: InstalledApp] = [:]
        var nameMap: [String: InstalledApp] = [:]

        for root in roots where manager.fileExists(atPath: root.path) {
            for app in scan(root: root, maxDepth: 2) {
                if let bundleID = app.bundleID {
                    bundleMap[bundleID.lowercased()] = app
                }
                nameMap[app.name.lowercased()] = app
            }
        }

        lock.lock()
        byBundleID = bundleMap
        byName = nameMap
        isIndexed = true
        lock.unlock()
    }

    func app(bundleID: String) -> InstalledApp? {
        ensureIndexed()
        let key = bundleID.lowercased()
        lock.lock()
        let cached = byBundleID[key]
        lock.unlock()
        if let cached { return cached }

        // 标准目录没扫到时，再问一次 LaunchServices
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let app = readApp(at: url)
            lock.lock()
            byBundleID[key] = app
            lock.unlock()
            return app
        }
        return nil
    }

    func app(named name: String) -> InstalledApp? {
        ensureIndexed()
        lock.lock()
        defer { lock.unlock() }
        return byName[name.lowercased()]
    }

    /// 刷新某条记录的安装状态（返回更新后的 installedVersion / path）。
    func resolve(bundleID: String?, appName: String?) -> (version: String?, path: String?) {
        if let bundleID, let app = app(bundleID: bundleID) {
            return (app.version, app.url.path)
        }
        if let appName, let app = app(named: appName) {
            return (app.version, app.url.path)
        }
        return (nil, nil)
    }

    // MARK: - 内部

    private func ensureIndexed() {
        lock.lock()
        let indexed = isIndexed
        lock.unlock()
        if !indexed { rebuild() }
    }

    private func scan(root: URL, maxDepth: Int) -> [InstalledApp] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [InstalledApp] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth >= maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "app" else { continue }
            enumerator.skipDescendants()
            results.append(readApp(at: url))
        }
        return results
    }

    private func readApp(at url: URL) -> InstalledApp {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var info: [String: Any]?
        if let data = try? Data(contentsOf: plistURL) {
            info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(
            name: name,
            bundleID: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String,
            url: url
        )
    }
}
