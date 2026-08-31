import Foundation
import CryptoKit

/// 从文件系统直接读取的客观事实（不涉及 DMG 内部）。
struct FileFacts {
    var size: Int64
    var createdAt: Date?
    var modifiedAt: Date?
}

enum FileFactsReader {
    static func read(url: URL) -> FileFacts {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else {
            return FileFacts(size: 0, createdAt: nil, modifiedAt: nil)
        }
        return FileFacts(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            createdAt: attributes[.creationDate] as? Date,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }
}

/// 大文件分块计算 SHA-256，避免一次性读入内存。
enum SHA256Service {
    static let bufferSize = 1 << 20 // 1 MB

    static func hash(fileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DMGServiceError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            if let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) { }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum DMGServiceError: LocalizedError {
    case unreadable(String)
    case attachFailed(String, detail: String)
    case plistUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "无法读取文件：\(path)"
        case .attachFailed(let path, let detail): return "挂载失败：\((path as NSString).lastPathComponent)\n\(detail)"
        case .plistUnreadable(let path): return "无法读取 Info.plist：\(path)"
        }
    }
}
