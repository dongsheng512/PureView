// 从内置设计直接绘制 macOS 风格 app 图标(圆角主体 + 透明留白)。
// 用法: swift Assets/make_icon.swift <iconset目录> [master.png]
// 尺寸比例来自 Apple Big Sur 图标模板:1024 画布 / 824 主体 / 圆角 185.4。
// 设计:深色渐变底 + 白色几何山 + 橙日(图像查看器意象,矢量绘制任意尺寸锐利)。
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset-dir> [master.png]\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
let masterPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

func drawBody(size: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = size
    let body = s * 824.0 / 1024.0
    let origin = (s - body) / 2
    let rect = CGRect(x: origin, y: origin, width: body, height: body)
    let radius = body * 185.4 / 824.0
    let clip = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(clip)
    ctx.clip()

    // 底:深色对角渐变(呼应深色画布)
    let colors = [
        CGColor(srgbRed: 0.24, green: 0.27, blue: 0.33, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    let u = body / 1024.0   // 设计基准单位

    // 太阳:暖橙圆,上偏右
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.64, blue: 0.10, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: rect.midX + 150 * u - 95 * u,
                               y: rect.minY + 660 * u, width: 190 * u, height: 190 * u))

    // 远山:淡白宽三角
    func mountain(peakX: CGFloat, peakY: CGFloat, halfBase: CGFloat, alpha: CGFloat) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX + peakX * u - halfBase * u, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + peakX * u, y: rect.minY + peakY * u))
        path.addLine(to: CGPoint(x: rect.midX + peakX * u + halfBase * u, y: rect.minY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.fillPath()
    }
    mountain(peakX: -180, peakY: 520, halfBase: 560, alpha: 0.45)
    mountain(peakX: 130, peakY: 380, halfBase: 620, alpha: 0.92)

    return ctx.makeImage()!
}

let finalSpecs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (size, name) in finalSpecs {
    let image = drawBody(size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try? png.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

if let masterPath {
    let master = drawBody(size: 1024)
    let rep = NSBitmapImageRep(cgImage: master)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: masterPath))
    }
}
print("iconset 已生成:\(outDir)")
