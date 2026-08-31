import Foundation
import CoreGraphics
import ImageIO

// 生成 App 图标：深蓝渐变底 + 光盘造型。输出 AppIcon.icns 到指定目录。
// 用法：swift Scripts/make_icon.swift <输出目录>

let sizes: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func drawIcon(size s: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: Int(s),
        height: Int(s),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // 1. 圆角矩形底：macOS 图标轮廓
    let radius = s * 0.2237
    let inset = s * 0.035
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let path = CGPath(
        roundedRect: cardRect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    context.saveGState()
    context.addPath(path)
    context.clip()

    // 2. 渐变填充
    let colors = [
        CGColor(red: 0.16, green: 0.29, blue: 0.52, alpha: 1),  // 深蓝
        CGColor(red: 0.09, green: 0.14, blue: 0.28, alpha: 1)   // 近黑蓝
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )
    }

    // 3. 顶部高光
    let highlightColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray
    if let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0, 1]) {
        context.drawLinearGradient(
            highlight,
            start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.midX, y: cardRect.midY),
            options: []
        )
    }

    // 4. 光盘：外环 + 内孔 + 高光弧
    let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
    let outerRadius = s * 0.27
    let innerRadius = s * 0.085

    let disc = CGPath(
        roundedRect: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ),
        cornerWidth: outerRadius,
        cornerHeight: outerRadius,
        transform: nil
    )
    context.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.95))
    context.addPath(disc)
    context.fillPath()

    // 内孔
    let hole = CGRect(
        x: center.x - innerRadius,
        y: center.y - innerRadius,
        width: innerRadius * 2,
        height: innerRadius * 2
    )
    context.addEllipse(in: hole)
    context.setFillColor(CGColor(red: 0.10, green: 0.15, blue: 0.29, alpha: 1))
    context.fillPath()

    // 光盘中环（透明环带，模拟 CD 反光区）
    context.setStrokeColor(CGColor(red: 0.55, green: 0.68, blue: 0.92, alpha: 0.75))
    context.setLineWidth(s * 0.018)
    context.addEllipse(in: CGRect(
        x: center.x - outerRadius * 0.72,
        y: center.y - outerRadius * 0.72,
        width: outerRadius * 1.44,
        height: outerRadius * 1.44
    ))
    context.strokePath()

    // 斜向高光弧
    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    context.setLineWidth(s * 0.022)
    context.setLineCap(.round)
    context.beginPath()
    context.addArc(
        center: center,
        radius: outerRadius * 0.88,
        startAngle: .pi * 0.62,
        endAngle: .pi * 1.22,
        clockwise: false
    )
    context.strokePath()
    context.restoreGState()

    context.restoreGState()

    // 5. 外描边
    context.addPath(path)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    context.setLineWidth(s * 0.008)
    context.strokePath()

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1
    ? arguments[1]
    : NSTemporaryDirectory() + "DMGLibraryIcon"

let manager = FileManager.default
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? manager.createDirectory(at: iconset, withIntermediateDirectories: true)

for entry in sizes {
    guard let image = drawIcon(size: CGFloat(entry.pixels)) else { continue }
    writePNG(image, to: iconset.appendingPathComponent(entry.name))
}

print(outputDirectory)
