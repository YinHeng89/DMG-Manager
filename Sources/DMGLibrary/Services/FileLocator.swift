import Foundation

struct LocateCandidate {
    enum Confidence: Int {
        case sizeOnly = 1   // 仅大小匹配
        case nameAndSize = 2 // 文件名 + 大小匹配
        case hash = 3       // SHA-256 完全一致
    }

    let url: URL
    let confidence: Confidence
}

/// 文件失联后的重新定位。
///
/// 用户把 DMG 挪走之后，数据库里的路径就失效了。这里按
/// 「文件名 → 大小 → SHA-256」的顺序逐级确认，能精确匹配就直接自动重连。
enum FileLocator {
    static let maxFilesScanned = 20_000

    static func locate(item: DMGItem, searchRoots: [URL] = []) -> LocateCandidate? {
        if item.exists {
            return LocateCandidate(url: item.fileURL, confidence: .hash)
        }

        let roots = candidateRoots(for: item, searchRoots: searchRoots)

        // 第一轮：同名文件
        var fallback: LocateCandidate?
        for root in roots {
            for url in dmgFiles(in: root) where url.lastPathComponent == item.filename {
                let size = FileFactsReader.read(url: url).size
                if size == item.fileSize {
                    if let sha = item.sha256, !sha.isEmpty,
                       (try? SHA256Service.hash(fileAt: url)) == sha {
                        return LocateCandidate(url: url, confidence: .hash)
                    }
                    let candidate = LocateCandidate(url: url, confidence: .nameAndSize)
                    if item.sha256 == nil || item.sha256?.isEmpty == true {
                        return candidate // 没有基准哈希，文件名 + 大小已足够可信
                    }
                    fallback = candidate
                } else if let sha = item.sha256, !sha.isEmpty, size > 0,
                          (try? SHA256Service.hash(fileAt: url)) == sha {
                    return LocateCandidate(url: url, confidence: .hash)
                }
            }
        }

        // 第二轮：丢弃文件名假设，靠哈希全量比对
        if let sha = item.sha256, !sha.isEmpty {
            for root in roots {
                for url in dmgFiles(in: root) {
                    let size = FileFactsReader.read(url: url).size
                    guard size == item.fileSize else { continue }
                    if (try? SHA256Service.hash(fileAt: url)) == sha {
                        return LocateCandidate(url: url, confidence: .hash)
                    }
                }
            }
        }

        return fallback
    }

    /// 候选搜索根目录：原目录 + 用户配置的扫描目录 + 常见下载位置。
    static func candidateRoots(for item: DMGItem, searchRoots: [URL]) -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var roots: [URL] = [item.directoryURL]
        roots.append(contentsOf: searchRoots)
        roots.append(contentsOf: [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Software")
        ])

        var seen = Set<String>()
        return roots.filter { root in
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            let key = root.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private static func dmgFiles(in root: URL) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "dmg" else { continue }
            results.append(url)
            if results.count >= maxFilesScanned { break }
        }
        return results
    }
}
