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
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DMGServiceError.unreadable(url.path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        // 读取错误必须真的抛出去。之前用 `try?` 把错误吞掉，失败时和「读到末尾」走同一条
        // 分支，于是「读到一半出错」被当成「读完了」，返回一个截断文件的哈希并写进数据库，
        // 直接污染重复检测与失联重连（SHA 是置信度最高的匹配依据）。
        //
        // 注意 nil / 空 Data 表示读到末尾（正常结束），只有 throw 才是真错误，两者要分开处理。
        while true {
            let chunk: Data?
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: bufferSize) }
            } catch {
                throw DMGServiceError.unreadable(url.path)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
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
