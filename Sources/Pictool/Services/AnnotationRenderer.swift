import AppKit
import CoreImage
import CoreText

// MARKUP_PLAN.md 生存级约束:预览(降采样)与导出(全尺寸)必须走同一套绘制函数。
// 本渲染器内部先把坐标系翻成"显示坐标(y 向下)",文字与图片绘制再在局部翻转回来,
// 因此调用方只管提供画幅大小,不用关心 CG 上下文方向。

enum AnnotationRenderer {

    /// 把标记画进任意 CG 上下文。`ctx` 为常规方向(y 向上);`base` 仅在含马赛克时需要,
    /// 用于生成像素化/模糊效果底图。
    ///
    /// - Parameter cacheEffects: 是否把效果底图写入跨调用的 `effectCache`。
    ///   画布拖动时每帧一次 `draw`,靠这个缓存才不卡;而导出只调用一次、
    ///   且 `base` 是全尺寸位图(24MP 单条 ≈192MB),缓存纯属留垃圾,传 `false`。
    static func draw(_ annotations: [Annotation], in ctx: CGContext,
                     canvasSize: CGSize, base: CGImage?, cacheEffects: Bool = true) {
        guard !annotations.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return }
        ctx.saveGState()
        // 进入显示坐标(y 向下),后续所有归一化坐标直接乘画幅
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        var pixelateCache: [CGFloat: CGImage] = [:]
        var blurCache: [CGFloat: CGImage] = [:]
        for annotation in annotations {
            switch annotation.kind {
            case let .text(anchor, content, sizeFraction, color, hasBackground):
                drawText(content, sizeFraction: MarkPalette.clampTextFraction(sizeFraction),
                         color: color, topLeft: anchor, hasBackground: hasBackground,
                         in: ctx, canvasSize: canvasSize)
            case let .stroke(points, widthLevel, color, style):
                let width = MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel) * canvasSize.width
                guard let path = strokePath(points, canvasSize: canvasSize) else { continue }
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setStrokeColor(MarkPalette.nsColor(color).cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                // 荧光笔半透明,同色叠笔自然加深(与预览.app 行为一致)
                ctx.setAlpha(style == .highlighter ? 0.45 : 1)
                ctx.strokePath()
                ctx.restoreGState()
            case let .mosaic(points, widthLevel, effect):
                let widthFraction = MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel)
                guard let path = strokePath(points, canvasSize: canvasSize) else { continue }
                let effectImage = resolveEffectImage(
                    effect: effect, widthLevel: widthLevel, base: base,
                    cacheEffects: cacheEffects,
                    pixelateCache: &pixelateCache, blurCache: &blurCache
                )
                guard let effectImage else { continue }
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(widthFraction * canvasSize.width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                // 把折线换成"描边区域",只在这一笔的范围内显示效果底图
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                drawEffectImage(effectImage, in: ctx, canvasSize: canvasSize)
                ctx.restoreGState()
            case let .mosaicRect(from, to, widthLevel, effect):
                let norm = MarkupGeometry.standardizedRect(from: from, to: to)
                let pixelRect = CGRect(
                    x: norm.minX * canvasSize.width,
                    y: norm.minY * canvasSize.height,
                    width: norm.width * canvasSize.width,
                    height: norm.height * canvasSize.height
                )
                guard pixelRect.width > 1, pixelRect.height > 1 else { continue }
                let effectImage = resolveEffectImage(
                    effect: effect, widthLevel: widthLevel, base: base,
                    cacheEffects: cacheEffects,
                    pixelateCache: &pixelateCache, blurCache: &blurCache
                )
                guard let effectImage else { continue }
                ctx.saveGState()
                ctx.clip(to: pixelRect)
                drawEffectImage(effectImage, in: ctx, canvasSize: canvasSize)
                ctx.restoreGState()
            case let .step(anchor, number, sizeFraction, color):
                drawStep(anchor: anchor, number: number, sizeFraction: sizeFraction,
                         color: color, in: ctx, canvasSize: canvasSize)
            case let .shape(kind, from, to, widthLevel, color, filled):
                drawShape(kind, from: from, to: to,
                          widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                          color: color, filled: filled, in: ctx, canvasSize: canvasSize)
            }
        }
        ctx.restoreGState()
    }

    /// 步骤序号气泡(① ② ③):实心圆 + 白色描边环 + 居中粗体数字(浅色底自动切黑字)。
    private static func drawStep(anchor: CGPoint, number: Int, sizeFraction: CGFloat,
                                 color: MarkupColor, in ctx: CGContext, canvasSize: CGSize) {
        let diameter = max(20, sizeFraction * canvasSize.width)
        let radius = diameter / 2
        let center = CGPoint(x: anchor.x * canvasSize.width, y: anchor.y * canvasSize.height)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)

        ctx.saveGState()
        // 轻微阴影让气泡从复杂截图里浮出来
        ctx.setShadow(offset: CGSize(width: 0, height: max(1, diameter * 0.04)),
                      blur: max(2, diameter * 0.12),
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.setFillColor(MarkPalette.nsColor(color).cgColor)
        ctx.fillEllipse(in: circleRect)
        ctx.restoreGState()

        // 外白环
        ctx.saveGState()
        let ringWidth = max(1.5, diameter * 0.075)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(ringWidth)
        ctx.strokeEllipse(in: circleRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ctx.restoreGState()

        // 居中数字(多位数略缩字号避免撑出圆外)
        let label = "\(number)"
        let fontRatio: CGFloat = label.count >= 2 ? 0.46 : 0.56
        let font = NSFont.systemFont(ofSize: diameter * fontRatio, weight: .bold)
        let textColor: NSColor = MarkPalette.isLight(color) ? .black : .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let textSize = attributed.size()
        let textOrigin = CGPoint(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attributed.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 形状:支持描边与可选半透明填充(矩形/椭圆);箭头为线段 + 实心三角头。显示坐标(y 向下)上下文。
    private static func drawShape(_ kind: ShapeKind, from: CGPoint, to: CGPoint,
                                  widthFraction: CGFloat, color: MarkupColor,
                                  filled: Bool,
                                  in ctx: CGContext, canvasSize: CGSize) {
        let width = max(1, widthFraction * canvasSize.width)
        let nsColor = MarkPalette.nsColor(color)
        let cgColor = nsColor.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height)
        }
        switch kind {
        case .rect, .ellipse:
            let norm = MarkupGeometry.standardizedRect(from: from, to: to)
            let pixelRect = CGRect(x: norm.minX * canvasSize.width,
                                   y: norm.minY * canvasSize.height,
                                   width: norm.width * canvasSize.width,
                                   height: norm.height * canvasSize.height)
            if kind == .rect {
                if filled {
                    ctx.setFillColor(nsColor.withAlphaComponent(0.24).cgColor)
                    ctx.fill(pixelRect)
                }
                ctx.stroke(pixelRect)
            } else {
                let ellipse = CGPath(ellipseIn: pixelRect, transform: nil)
                if filled {
                    ctx.setFillColor(nsColor.withAlphaComponent(0.24).cgColor)
                    ctx.addPath(ellipse)
                    ctx.fillPath()
                }
                ctx.addPath(ellipse)
                ctx.strokePath()
            }
        case .line, .arrow:
            let a = point(from), b = point(to)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
            if kind == .arrow,
               let head = MarkupGeometry.arrowHead(from: from, to: to,
                                                   widthFraction: widthFraction,
                                                   canvasSize: canvasSize) {
                let path = CGMutablePath()
                path.move(to: point(head.tip))
                path.addLine(to: point(head.baseA))
                path.addLine(to: point(head.baseB))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    /// 透明底标记层(预览叠层用)
    static func renderOverlay(annotations: [Annotation], canvasSize: CGSize,
                              base: CGImage?) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: max(1, Int(canvasSize.width)), height: max(1, Int(canvasSize.height)),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(annotations, in: ctx, canvasSize: canvasSize, base: base)
        return ctx.makeImage()
    }

    // MARK: 文字(CoreText;预览与导出同一度量与绘制路径)

    static func textSize(content: String, sizeFraction: CGFloat, canvasWidth: CGFloat) -> CGSize {
        let fontSize = sizeFraction * canvasWidth
        guard fontSize > 0 else { return .zero }
        let font = makeFont(size: fontSize)
        let lineHeight = fontSize * 1.35
        var maxWidth: CGFloat = 0
        var lineCount = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            lineCount += 1
            guard let astr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
            ] as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(astr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)))
        }
        return CGSize(width: maxWidth, height: CGFloat(max(lineCount, 1)) * lineHeight)
    }

    /// 在显示坐标(y 向下)上下文里画文字块。
    /// `topLeft` 是**归一化**左上角(0...1),不要传入像素坐标。
    /// 上下文必须是已被外层翻转过的;文字在局部再翻回,保证字形直立的同一份代码两端通用。
    static func drawText(_ content: String, sizeFraction: CGFloat, color: MarkupColor,
                         topLeft: CGPoint, hasBackground: Bool = false,
                         in ctx: CGContext, canvasSize: CGSize) {
        let fontSize = sizeFraction * canvasSize.width
        guard fontSize > 0 else { return }
        let font = makeFont(size: fontSize)
        let color = MarkPalette.nsColor(color).usingColorSpace(.deviceRGB) ?? .black
        let lineHeight = fontSize * 1.35
        let ascent = CTFontGetAscent(font)
        let x = topLeft.x * canvasSize.width
        let yTop = topLeft.y * canvasSize.height
        if hasBackground {
            let blockSize = textSize(content: content, sizeFraction: sizeFraction, canvasWidth: canvasSize.width)
            if blockSize.width > 0, blockSize.height > 0 {
                let padX = max(4, fontSize * 0.32)
                let padY = max(2, fontSize * 0.16)
                let bgRect = CGRect(
                    x: x - padX,
                    y: yTop - padY,
                    width: blockSize.width + padX * 2,
                    height: blockSize.height + padY * 2
                )
                let radius = max(3, fontSize * 0.24)
                let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                let bgColor = luminance < 0.42
                    ? NSColor(white: 1.0, alpha: 0.82).cgColor
                    : NSColor(white: 0.08, alpha: 0.68).cgColor
                ctx.saveGState()
                ctx.setFillColor(bgColor)
                ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
        for (i, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let baselineY = yTop + CGFloat(i) * lineHeight + ascent
            ctx.saveGState()
            ctx.translateBy(x: x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            if let astr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color.cgColor,
            ] as CFDictionary) {
                let ctLine = CTLineCreateWithAttributedString(astr)
                ctx.textPosition = .zero
                CTLineDraw(ctLine, ctx)
            }
            ctx.restoreGState()
        }
    }

    // MARK: 效果底图(M4 马赛克/模糊)

    /// 效果缓存条目:强持有 base。若只存结果图,base 释放后同尺寸新图的
    /// ObjectIdentifier 可能复用同址,导致马赛克/模糊烙上另一张图的像素。
    private final class EffectCacheEntry {
        let base: CGImage
        let image: CGImage
        init(base: CGImage, image: CGImage) {
            self.base = base
            self.image = image
        }
    }

    /// NSCache 本身线程安全,这里显式豁免 Swift 6 的「全局可变状态」检查
    nonisolated(unsafe) private static let effectCache: NSCache<NSString, EffectCacheEntry> = {
        let cache = NSCache<NSString, EffectCacheEntry>()
        cache.countLimit = 8
        // 每条 = base + 效果图 ≈ 2× 位图字节数。64MB 足够覆盖预览(1500px 级),
        // 又能保证全尺寸位图进不来——只有 countLimit 时,8 条 24MP 可驻留约 1.5GB。
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// 统一走 CoreImage CIPixellate(与高斯模糊共享同一个 Metal CIContext 硬件加速)
    static func pixelated(_ base: CGImage, blockFraction: CGFloat, cache: Bool = true) -> CGImage? {
        let cacheKey = "p-\(ObjectIdentifier(base))-\(blockFraction)" as NSString
        if cache, let entry = effectCache.object(forKey: cacheKey), entry.base === base { return entry.image }
        let blockPx = max(2, blockFraction * CGFloat(base.width))
        let input = CIImage(cgImage: base)
        let clamped = input.clampedToExtent()
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(blockPx, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = ciContext.createCGImage(output, from: input.extent) else { return nil }
        if cache {
            effectCache.setObject(EffectCacheEntry(base: base, image: result), forKey: cacheKey,
                                  cost: base.bytesPerRow * base.height * 2)
        }
        return result
    }

    private static let ciContext = CIContext(options: nil)

    static func gaussianBlurred(_ base: CGImage, radiusFraction: CGFloat, cache: Bool = true) -> CGImage? {
        let cacheKey = "b-\(ObjectIdentifier(base))-\(radiusFraction)" as NSString
        if cache, let entry = effectCache.object(forKey: cacheKey), entry.base === base { return entry.image }
        let input = CIImage(cgImage: base)
        // 先边缘延展再模糊,避免高斯在四边吃出透明带;最后裁回原幅
        let clamped = input.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radiusFraction * CGFloat(base.width), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        guard let result = ciContext.createCGImage(output, from: input.extent) else { return nil }
        if cache {
            effectCache.setObject(EffectCacheEntry(base: base, image: result), forKey: cacheKey,
                                  cost: base.bytesPerRow * base.height * 2)
        }
        return result
    }

    // MARK: 私有

    private static func resolveEffectImage(
        effect: MosaicEffect,
        widthLevel: Int,
        base: CGImage?,
        cacheEffects: Bool,
        pixelateCache: inout [CGFloat: CGImage],
        blurCache: inout [CGFloat: CGImage]
    ) -> CGImage? {
        switch effect {
        case .pixelate:
            let block = MarkPalette.fraction(MarkPalette.pixelateBlocks, level: widthLevel)
            if let hit = pixelateCache[block] { return hit }
            let img = base.flatMap { pixelated($0, blockFraction: block, cache: cacheEffects) }
            pixelateCache[block] = img
            return img
        case .blur:
            let radius = MarkPalette.fraction(MarkPalette.blurRadii, level: widthLevel)
            if let hit = blurCache[radius] { return hit }
            let img = base.flatMap { gaussianBlurred($0, radiusFraction: radius, cache: cacheEffects) }
            blurCache[radius] = img
            return img
        }
    }

    private static func drawEffectImage(_ effectImage: CGImage, in ctx: CGContext, canvasSize: CGSize) {
        // 效果底图是常规方向图片,局部翻转回来再铺
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(effectImage, in: CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
    }

    private static func makeFont(size: CGFloat) -> CTFont {
        let nsFont = NSFont.systemFont(ofSize: size, weight: .medium)
        return CTFontCreateWithFontDescriptor(nsFont.fontDescriptor, size, nil)
    }

    /// 中点二次贝塞尔曲线插值:3 点及以上自动平滑过渡,消除快速手写折线棱角。
    private static func strokePath(_ points: [CGPoint], canvasSize: CGSize) -> CGPath? {
        guard !points.isEmpty else { return nil }
        let scaled = points.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
        let path = CGMutablePath()
        if scaled.count == 1 {
            // 单点轻点:用一小段重合线段表现圆点
            path.move(to: scaled[0])
            path.addLine(to: CGPoint(x: scaled[0].x + 0.01, y: scaled[0].y))
        } else if scaled.count == 2 {
            path.move(to: scaled[0])
            path.addLine(to: scaled[1])
        } else {
            path.move(to: scaled[0])
            for i in 1..<(scaled.count - 1) {
                let mid = CGPoint(
                    x: (scaled[i].x + scaled[i + 1].x) / 2,
                    y: (scaled[i].y + scaled[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: scaled[i])
            }
            path.addLine(to: scaled[scaled.count - 1])
        }
        return path
    }
}
