import AppKit
import CoreGraphics
import Foundation

// 绘制 RemoteScreen 应用图标：蓝色圆角底 + 白色「投屏」符号（屏幕 + 信号波）
func drawIcon(size: CGFloat) -> CGImage? {
    let scale: CGFloat = 1.0
    let px = Int(size * scale)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = size
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 圆角底：蓝色渐变（与客户端主题色一致）
    let margin = s * 0.055
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let radius = rect.width * 0.225
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.36, green: 0.60, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.09, green: 0.36, blue: 0.79, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // 屏幕边框（白色描边）
    let screenInset = rect.width * 0.20
    let screen = rect.insetBy(dx: screenInset, dy: screenInset * 1.15)
    let screenRadius = rect.width * 0.075
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(rect.width * 0.062)
    ctx.setLineJoin(.round)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.strokePath()

    // 左下角「投屏」信号：实心点 + 两道弧
    let origin = CGPoint(x: screen.minX + rect.width * 0.115, y: screen.minY + rect.width * 0.115)
    let dotRadius = rect.width * 0.052
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(
        x: origin.x - dotRadius, y: origin.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    ))

    ctx.setLineWidth(rect.width * 0.052)
    ctx.setLineCap(.round)
    for index in 1...2 {
        let radius = rect.width * (0.135 + 0.105 * CGFloat(index - 1) + 0.02)
        ctx.addArc(
            center: origin,
            radius: radius,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: false
        )
        ctx.strokePath()
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("写入 \(path)")
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法: make <尺寸> <输出路径>")
    exit(1)
}
let size = CGFloat(Double(args[1]) ?? 1024)
guard let image = drawIcon(size: size) else { exit(1) }
write(image, to: args[2])
