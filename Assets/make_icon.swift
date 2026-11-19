// 从 Assets/AppIconSource.jpg 提取超椭圆主体并生成 macOS 标准 AppIcon.iconset + AppIconMaster.png。
// 用法: swift Assets/make_icon.swift <iconset目录> [master.png]
// 尺寸比例来自 Apple macOS 图标模板: 1024 画布 / 824 主体 / 连续曲率圆角 185.4。
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <iconset-dir> [master.png]\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
let masterPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let sourceURL = URL(fileURLWithPath: "Assets/AppIconSource.jpg")
guard let nsImage = NSImage(contentsOf: sourceURL),
      let sourceCG = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("error: failed to load Assets/AppIconSource.jpg\n".utf8))
    exit(2)
}

// 源图(1024×1024)纯白超椭圆主体边界 left=150, right=873, top=150, bottom=873；
// 内收 6px 剔除灰底过渡边，保证透明画布纯白圆角边缘绝对锐利。
let cropRect = CGRect(x: 156, y: 156, width: 712, height: 712)
guard let croppedSource = sourceCG.cropping(to: cropRect) else {
    FileHandle.standardError.write(Data("error: failed to crop source icon\n".utf8))
    exit(2)
}

/// 构造 Apple 连续曲率圆角路径(NSBezierPath roundedRect 近似超椭圆)
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high

    let s = size
    let body = s * 824.0 / 1024.0
    let origin = (s - body) / 2
    let rect = CGRect(x: origin, y: origin, width: body, height: body)
    let radius = body * 185.4 / 824.0
    let clip = squirclePath(in: rect, radius: radius)

    // macOS 原生柔和外投影（大尺寸生效，极小尺寸适当减弱免糊）
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.012),
            blur: s * 0.024,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.26)
        )
        ctx.addPath(clip)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 主体裁切绘制
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    ctx.draw(croppedSource, in: rect)
    ctx.restoreGState()

    // 极淡深灰内描边（保证纯白底在浅色 Dock / 白色背景上轮廓依然清晰锐利）
    ctx.saveGState()
    let strokeW = max(0.5, s * 0.0016)
    let insetRect = rect.insetBy(dx: strokeW / 2, dy: strokeW / 2)
    ctx.addPath(squirclePath(in: insetRect, radius: radius - strokeW / 2))
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08))
    ctx.setLineWidth(strokeW)
    ctx.strokePath()
    ctx.restoreGState()

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
    let image = renderIcon(size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try? png.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

if let masterPath {
    let master = renderIcon(size: 1024)
    let rep = NSBitmapImageRep(cgImage: master)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: masterPath))
    }
}
print("iconset 已生成:\(outDir)")
