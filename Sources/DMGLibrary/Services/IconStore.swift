import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// App 图标缓存。图标从 DMG 内部提取一次后落到本地，之后列表直接读 PNG，
/// 不必反复挂载镜像。
///
/// 全程使用 CoreGraphics / ImageIO，不用 NSImage 的 lockFocus，因此可以放心在后台线程调用。
final class IconStore: @unchecked Sendable {
    static let shared = IconStore()

    private let directory = AppPaths.thumbnails
    private let pixelSize = 256

    /// 列表滚动时会反复取图标，这里做一层内存缓存，避免每次都读磁盘解码 PNG。
    private let cache = NSCache<NSString, NSImage>()

    init() {
        AppPaths.ensureDirectories()
        cache.countLimit = 300
    }

    /// 从 .icns 文件提取图标并保存为 PNG，返回文件名。
    @discardableResult
    func save(iconFileAt iconURL: URL, name: String) -> String? {
        guard let png = pngData(from: iconURL) else { return nil }
        let filename = name.hasSuffix(".png") ? name : name + ".png"
        do {
            try png.write(to: directory.appendingPathComponent(filename))
            return filename
        } catch {
            return nil
        }
    }

    func image(named filename: String?) -> NSImage? {
        guard let filename, !filename.isEmpty else { return nil }
        let key = filename as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func url(named filename: String?) -> URL? {
        guard let filename, !filename.isEmpty else { return nil }
        return directory.appendingPathComponent(filename)
    }

    func delete(named filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        cache.removeObject(forKey: filename as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private func pngData(from iconURL: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
