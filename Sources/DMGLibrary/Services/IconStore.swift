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
    /// 从 .icns 提取时保留的像素尺寸（主图，够大，后续按显示尺寸高质量降采样）。
    private let masterPixelSize = 256

    /// 主图缓存：同一张图的不同显示尺寸共用，避免每个尺寸都读一次磁盘解码一遍 PNG。
    private let masterCache = NSCache<NSString, CGImage>()

    /// 成品缓存：key 是「文件名#像素尺寸」，列表滚动时反复取用。
    private let cache = NSCache<NSString, NSImage>()

    /// filename → 该文件已经生成过的像素尺寸。
    /// NSCache 既不能遍历、也不支持按前缀清理，而成品缓存的 key 里带尺寸，
    /// 删除条目时只按文件名是删不掉的，得靠这份记录逐个 key 清。
    private var generatedSizes: [String: Set<Int>] = [:]
    private let sizesLock = NSLock()

    init() {
        AppPaths.ensureDirectories()
        masterCache.countLimit = 120
        cache.countLimit = 600
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

    /// 同步取缓存图（不解码）。命中立即返回，未命中返回 nil —— 解码交给 `requestImage`
    /// 在后台线程做，这样选中切换 / 列表滚动时不会因为图标解码阻塞主线程，选中高亮才能即时切换。
    ///
    /// 这里按屏幕缩放比生成对应像素尺寸的缩略图（例如 36pt @2x = 72px），size 设成 pointSize，
    /// 渲染时是 1:1 的，不需要再缩放。直接把 256px 主图丢给 SwiftUI 缩到 36pt 时缩放比非整数
    /// （3.56×）且用的是默认插值，图标边缘会发虚、出现毛边。
    func image(named filename: String?, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard let filename, !filename.isEmpty else { return nil }
        return cache.object(forKey: cacheKey(filename: filename, pixelSize: pixelSize(for: pointSize, scale: scale)))
    }

    /// 取图标：命中缓存立即回调；未命中在后台线程解码，完成后回主线程回调。全程不阻塞主线程。
    ///
    /// 这是修复「点选列表项时选中高亮要延迟一下才切换」的关键——详情头部图标原本在主线程
    /// 同步读盘 + 降采样，会把这次 SwiftUI 事务的提交（连同列表高亮）一起拖慢。改成异步后，
    /// 高亮先提交，图标随后补齐。
    func requestImage(
        named filename: String?,
        pointSize: CGFloat,
        scale: CGFloat = 2,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard let filename, !filename.isEmpty else { completion(nil); return }
        let px = pixelSize(for: pointSize, scale: scale)
        let key = cacheKey(filename: filename, pixelSize: px)
        if let cached = cache.object(forKey: key) { completion(cached); return }

        // 后台解码：读盘 + 高质量降采样都挪到全局队列，主线程只负责把成品塞进 NSImage。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let cg = self.thumbnail(named: filename, pixelSize: px) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: pointSize, height: pointSize))
            self.cache.setObject(image, forKey: key)
            self.remember(pixelSize: px, for: filename)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 记下这个尺寸，供 `delete(named:)` 精确清理成品缓存。
    private func remember(pixelSize: Int, for filename: String) {
        sizesLock.lock()
        generatedSizes[filename, default: []].insert(pixelSize)
        sizesLock.unlock()
    }

    private func pixelSize(for pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * scale).rounded()))
    }

    private func cacheKey(filename: String, pixelSize: Int) -> NSString {
        "\(filename)#\(pixelSize)" as NSString
    }

    func url(named filename: String?) -> URL? {
        guard let filename, !filename.isEmpty else { return nil }
        return directory.appendingPathComponent(filename)
    }

    func delete(named filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        // 主图缓存的 key 就是文件名
        masterCache.removeObject(forKey: filename as NSString)
        // 成品缓存的 key 带尺寸，必须按记录逐个删，只按文件名删等于什么都没删
        sizesLock.lock()
        let sizes = generatedSizes.removeValue(forKey: filename) ?? []
        sizesLock.unlock()
        for size in sizes {
            cache.removeObject(forKey: cacheKey(filename: filename, pixelSize: size))
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    // MARK: - 图像处理

    private func thumbnail(named filename: String, pixelSize: Int) -> CGImage? {
        guard let master = masterImage(named: filename) else { return nil }
        // 目标尺寸不小于主图时直接用主图，避免放大导致发虚。
        guard pixelSize < min(master.width, master.height) else { return master }
        return downscale(master, to: pixelSize)
    }

    private func masterImage(named filename: String) -> CGImage? {
        let key = filename as NSString
        if let cached = masterCache.object(forKey: key) { return cached }
        let sourceURL = directory.appendingPathComponent(filename)
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        masterCache.setObject(cg, forKey: key)
        return cg
    }

    /// 高质量降采样。
    ///
    /// 用 premultiplied 的位图上下文重绘：直接缩放带 alpha 的图时，半透明边缘的
    /// RGB 会和透明通道混在一起，缩放后渗出亮边／暗边，也就是看到的「虚边」。
    private func downscale(_ image: CGImage, to pixelSize: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return context.makeImage()
    }

    private func pngData(from iconURL: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: masterPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            Self.indexOfLargestImage(in: source),
            options as CFDictionary
        ) else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// .icns 里像素最多的那一帧的下标。
    ///
    /// ICNS 内嵌多尺寸且帧顺序不保证，固定取 index 0 有可能拿到 16/32px 的小图，
    /// 放大后就是糊的。这里只读属性不解码，挑最大的一帧。
    private static func indexOfLargestImage(in source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return 0 }

        var bestIndex = 0
        var bestPixels = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            let pixels = width * height
            if pixels > bestPixels {
                bestPixels = pixels
                bestIndex = index
            }
        }
        return bestIndex
    }
}
