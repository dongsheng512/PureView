import AppKit
import CoreText

// MARKUP_PLAN.md — 画布标记图元与几何纯函数。
// 坐标统一为归一化(0...1,原点图片左上),与裁切选区同语义;
// 字号/线宽/马赛克块大小均为相对图宽的千分比,预览与导出按各自画幅换算。

/// 画布标记。按 MARKUP_PLAN 从第一天就是枚举:text(A1)/ stroke(A3)/ mosaic(A4)。
struct Annotation: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    enum Kind: Equatable, Sendable {
        /// 锚点为文字块左上角(归一化);sizeFraction = 字号/画布宽(连续,三档 chip 是预设)
        case text(anchor: CGPoint, content: String, sizeFraction: CGFloat, color: MarkupColor)
        /// 笔迹;style 决定实线或荧光(半透明、更宽)
        case stroke(points: [CGPoint], widthLevel: Int, color: MarkupColor, style: StrokeStyleKind)
        /// 笔迹 = 效果蒙版;effect 决定蒙版下显示像素化还是模糊底图
        case mosaic(points: [CGPoint], widthLevel: Int, effect: MosaicEffect)
        /// 形状(B2):只描边;rect/ellipse 用 from/to 对角点,line/arrow 用两端点(arrow 指向 to)
        case shape(kind: ShapeKind, from: CGPoint, to: CGPoint, widthLevel: Int, color: MarkupColor)
    }
}

/// 笔迹样式:实线 / 荧光笔(半透明、更宽)
enum MarkupColor: Equatable, Sendable, Hashable {
    case palette(Int)
    case custom(r: Double, g: Double, b: Double)

    static let red = MarkupColor.palette(2)
}

enum StrokeStyleKind: String, CaseIterable, Identifiable, Sendable {
    case solid
    case highlighter
    var id: String { rawValue }
    var label: String { self == .solid ? "实线" : "荧光" }
}

enum EditTool: String, CaseIterable, Identifiable, Sendable {
    case crop, text, brush, mosaic, eraser, shape
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "裁切"
        case .text: "文字"
        case .brush: "画笔"
        case .mosaic: "马赛克"
        case .eraser: "橡皮"
        case .shape: "形状"
        }
    }
    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .text: "character.cursor.ibeam"
        case .brush: "paintbrush.pointed"
        case .mosaic: "squareshape.split.3x3"
        case .eraser: "eraser"
        case .shape: "rectangle.dashed"
        }
    }
}

/// 形状标注种类(B2)。from/to 为对角点或端点,归一化坐标。
enum ShapeKind: String, CaseIterable, Identifiable, Sendable {
    case rect, ellipse, line, arrow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rect: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        }
    }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "line.diagonal.arrow"
        case .rect: "rectangle"
        case .ellipse: "circle"
        }
    }

    /// 选择面板排列:与预览.app 同类,先线后封闭形
    static let pickerOrder: [ShapeKind] = [.line, .arrow, .rect, .ellipse]
}

enum ShapeCorner: Equatable, Sendable { case nw, ne, sw, se }
enum ShapeEdge: Equatable, Sendable { case n, s, w, e }
enum ShapeHandle: Equatable, Sendable {
    case corner(ShapeCorner)
    case edge(ShapeEdge)
    /// true = from 端, false = to 端
    case endpoint(Bool)
}

enum MosaicEffect: String, CaseIterable, Identifiable, Sendable {
    case pixelate
    case blur
    var id: String { rawValue }
    var label: String { self == .pixelate ? "打码" : "模糊" }
}

/// 标记工具共享的调色盘与档位(千分比表)。档位取值越界时夹到合法区间。
enum MarkPalette {

    /// 24 种常用色。前 6 个下标保持历史语义(黑/白/红/黄/绿/蓝)。
    static let colors: [NSColor] = [
        .black,
        .white,
        NSColor(srgbRed: 0.90, green: 0.18, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.76, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.64, blue: 0.29, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.42, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.49, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.27, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.91, green: 0.45, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.35, blue: 0.17, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.72, blue: 0.78, alpha: 1),
        NSColor(srgbRed: 0.63, green: 0.09, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.65, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.76, blue: 0.29, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.22, blue: 0.49, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.16, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.48, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.29, green: 0.29, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1),
        NSColor(srgbRed: 0.94, green: 0.38, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.48, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.40, green: 0.68, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.29, green: 0.22, blue: 0.55, alpha: 1),
    ]

    static func color(_ index: Int) -> NSColor {
        colors.indices.contains(index) ? colors[index] : .black
    }

    static func nsColor(_ color: MarkupColor) -> NSColor {
        switch color {
        case .palette(let index):
            return Self.color(index)
        case .custom(let r, let g, let b):
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    static func isLight(_ color: MarkupColor) -> Bool {
        luminance(of: nsColor(color)) > 0.65
    }

    static func luminance(of ns: NSColor) -> CGFloat {
        let rgb = ns.usingColorSpace(.sRGB) ?? ns
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    static let textSizes: [CGFloat] = [0.030, 0.048, 0.070]
    static let textFractionRange: ClosedRange<CGFloat> = 0.015...0.120
    static let strokeWidths: [CGFloat] = [0.004, 0.008, 0.016]
    /// 荧光笔:更宽,渲染时叠加 45% alpha
    static let highlighterWidths: [CGFloat] = [0.012, 0.020, 0.032]
    static let mosaicWidths: [CGFloat] = [0.035, 0.060, 0.100]
    static let pixelateBlocks: [CGFloat] = [0.012, 0.022, 0.038]
    static let blurRadii: [CGFloat] = [0.006, 0.012, 0.022]

    /// 实线/荧光共用:按样式取线宽表
    static func widthTable(for style: StrokeStyleKind) -> [CGFloat] {
        style == .highlighter ? highlighterWidths : strokeWidths
    }

    static func clampTextFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, textFractionRange.lowerBound), textFractionRange.upperBound)
    }

    /// 连续字号反映到三档 chip 的高亮(取最近档)
    static func nearestTextLevel(_ fraction: CGFloat) -> Int {
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, size) in textSizes.enumerated() {
            let dist = abs(size - fraction)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    static func fraction(_ table: [CGFloat], level: Int) -> CGFloat {
        let idx = min(max(0, level), table.count - 1)
        return table[idx]
    }

    /// 白(1)、黄(3)为浅色,描边用近黑;其余近白。
    static func isLightColor(_ index: Int) -> Bool {
        isLight(.palette(index))
    }
}

/// 标记几何纯函数(单测覆盖)。所有坐标为归一化值。
enum MarkupGeometry {

    /// 点到线段的最短距离
    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let apx = p.x - a.x, apy = p.y - a.y
        let lengthSq = abx * abx + aby * aby
        if lengthSq == 0 { return hypot(apx, apy) }
        let t = min(max(0, (apx * abx + apy * aby) / lengthSq), 1)
        let cx = a.x + t * abx, cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    /// 笔迹(折线)是否覆盖某点:**像素空间**算距离(归一化空间非等比,横竖容差会不一致)。
    /// 容差 = 线宽一半,另留固定小量便于点选细线。
    static func stroke(_ points: [CGPoint], contains point: CGPoint,
                       widthFraction: CGFloat, canvasSize: CGSize) -> Bool {
        guard let w = canvasSize.width > 0 ? canvasSize.width : nil, canvasSize.height > 0 else { return false }
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * canvasSize.height) }
        let target = px(point)
        let tolerance = max(widthFraction / 2, 0.004) * w + 0.006 * w
        if points.count == 1, let only = points.first {
            return distance(target, segment: px(only), px(only)) <= tolerance
        }
        for i in 1..<points.count {
            if distance(target, segment: px(points[i - 1]), px(points[i])) <= tolerance { return true }
        }
        return false
    }

    /// 拖动后锚点夹取到 0...1
    static func moved(anchor: CGPoint, by delta: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, anchor.x + delta.width), 1),
                y: min(max(0, anchor.y + delta.height), 1))
    }

    static func translated(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 整笔平移并夹回画布:任一点越界时收紧位移量,笔不拆散、不出界。
    static func clampedTranslate(points: [CGPoint], dx: CGFloat, dy: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let shiftX = min(max(dx, -minX), 1 - maxX)
        let shiftY = min(max(dy, -minY), 1 - maxY)
        return points.map { CGPoint(x: $0.x + shiftX, y: $0.y + shiftY) }
    }

    /// 粘贴副本时的默认位移(归一化)
    static let pasteNudge: CGFloat = 0.03

    /// 平移整枚图元并夹回单位矩形;载荷(色/宽/样式)不变。
    static func offset(_ kind: Annotation.Kind, dx: CGFloat, dy: CGFloat) -> Annotation.Kind {
        switch kind {
        case let .text(anchor, content, sizeFraction, color):
            return .text(
                anchor: moved(anchor: anchor, by: CGSize(width: dx, height: dy)),
                content: content, sizeFraction: sizeFraction, color: color
            )
        case let .stroke(points, widthLevel, color, style):
            return .stroke(
                points: clampedTranslate(points: points, dx: dx, dy: dy),
                widthLevel: widthLevel, color: color, style: style
            )
        case let .mosaic(points, widthLevel, effect):
            return .mosaic(
                points: clampedTranslate(points: points, dx: dx, dy: dy),
                widthLevel: widthLevel, effect: effect
            )
        case let .shape(kind, from, to, widthLevel, color):
            let pts = clampedTranslate(points: [from, to], dx: dx, dy: dy)
            return .shape(kind: kind, from: pts[0], to: pts[1],
                          widthLevel: widthLevel, color: color)
        }
    }

    // MARK: 形状(B2)

    /// from/to 对角点转正矩形(负宽高翻转)
    static func standardizedRect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    /// 箭头头部几何:tip 在 to 端。**在像素空间计算**(归一化空间非等比,横竖箭头会失真),
    /// 头长(像素)= max(3×线宽像素, 画幅短边 2%);返回值已换回归一化坐标。
    static func arrowHead(from: CGPoint, to: CGPoint, widthFraction: CGFloat,
                          canvasSize: CGSize) -> (tip: CGPoint, baseA: CGPoint, baseB: CGPoint)? {
        let w = canvasSize.width, h = canvasSize.height
        guard w > 0, h > 0 else { return nil }
        let a = CGPoint(x: from.x * w, y: from.y * h)
        let b = CGPoint(x: to.x * w, y: to.y * h)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let headPx = max(3 * widthFraction * w, 0.02 * min(w, h))
        let ux = dx / length, uy = dy / length
        let backX = b.x - ux * headPx
        let backY = b.y - uy * headPx
        let half = headPx / 2
        let px = -uy * half, py = ux * half
        return (to,
                CGPoint(x: (backX + px) / w, y: (backY + py) / h),
                CGPoint(x: (backX - px) / w, y: (backY - py) / h))
    }

    /// 形状包围盒(含线宽外扩;箭头含头部)
    static func shapeBounds(kind: ShapeKind, from: CGPoint, to: CGPoint,
                            widthFraction: CGFloat, canvasSize: CGSize) -> CGRect? {
        let pad = widthFraction / 2
        var minX = min(from.x, to.x), maxX = max(from.x, to.x)
        var minY = min(from.y, to.y), maxY = max(from.y, to.y)
        if kind == .arrow, let head = arrowHead(from: from, to: to, widthFraction: widthFraction,
                                                canvasSize: canvasSize) {
            for p in [head.tip, head.baseA, head.baseB] {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    static let shapeMinSize: CGFloat = 0.01

    static func clampUnit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), 1), y: min(max(0, p.y), 1))
    }

    static func shapeHandles(kind: ShapeKind, from: CGPoint, to: CGPoint) -> [(ShapeHandle, CGPoint)] {
        switch kind {
        case .line, .arrow:
            return [(.endpoint(true), from), (.endpoint(false), to)]
        case .ellipse:
            // 轴对齐椭圆与包围盒四边中点相切,手柄落在椭圆上,不落在角上。
            let r = standardizedRect(from: from, to: to)
            return [
                (.edge(.n), CGPoint(x: r.midX, y: r.minY)),
                (.edge(.e), CGPoint(x: r.maxX, y: r.midY)),
                (.edge(.s), CGPoint(x: r.midX, y: r.maxY)),
                (.edge(.w), CGPoint(x: r.minX, y: r.midY)),
            ]
        case .rect:
            let r = standardizedRect(from: from, to: to)
            return [
                (.corner(.nw), CGPoint(x: r.minX, y: r.minY)),
                (.corner(.ne), CGPoint(x: r.maxX, y: r.minY)),
                (.corner(.se), CGPoint(x: r.maxX, y: r.maxY)),
                (.corner(.sw), CGPoint(x: r.minX, y: r.maxY)),
                (.edge(.n), CGPoint(x: r.midX, y: r.minY)),
                (.edge(.e), CGPoint(x: r.maxX, y: r.midY)),
                (.edge(.s), CGPoint(x: r.midX, y: r.maxY)),
                (.edge(.w), CGPoint(x: r.minX, y: r.midY)),
            ]
        }
    }

    static func hitShapeHandle(kind: ShapeKind, from: CGPoint, to: CGPoint,
                               at point: CGPoint, tolerance: CGFloat) -> ShapeHandle? {
        var best: ShapeHandle?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (handle, p) in shapeHandles(kind: kind, from: from, to: to) {
            let d = hypot(point.x - p.x, point.y - p.y)
            if d <= tolerance, d < bestDist {
                bestDist = d
                best = handle
            }
        }
        return best
    }

    static func reshaped(kind: ShapeKind, from: CGPoint, to: CGPoint,
                         handle: ShapeHandle, to point: CGPoint,
                         lockAspect: Bool) -> (from: CGPoint, to: CGPoint) {
        let p = clampUnit(point)
        switch kind {
        case .line, .arrow:
            switch handle {
            case .endpoint(true):
                return minLengthLine(from: p, to: to)
            case .endpoint(false):
                return minLengthLine(from: from, to: p)
            default:
                return (from, to)
            }
        case .rect, .ellipse:
            return reshapedRect(from: from, to: to, handle: handle, point: p, lockAspect: lockAspect)
        }
    }

    private static func minLengthLine(from a: CGPoint, to b: CGPoint) -> (from: CGPoint, to: CGPoint) {
        let a = clampUnit(a), b = clampUnit(b)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len >= shapeMinSize { return (a, b) }
        if len < 1e-8 {
            let next = clampUnit(CGPoint(x: a.x + shapeMinSize, y: a.y))
            if next.x - a.x < shapeMinSize / 2 {
                return (clampUnit(CGPoint(x: a.x - shapeMinSize, y: a.y)), a)
            }
            return (a, next)
        }
        let scale = shapeMinSize / len
        return (a, clampUnit(CGPoint(x: a.x + dx * scale, y: a.y + dy * scale)))
    }

    private static func reshapedRect(from: CGPoint, to: CGPoint, handle: ShapeHandle,
                                     point p: CGPoint, lockAspect: Bool) -> (from: CGPoint, to: CGPoint) {
        let r0 = standardizedRect(from: from, to: to)
        let ratio = r0.height > 1e-8 ? r0.width / r0.height : 1
        var minX = r0.minX, maxX = r0.maxX, minY = r0.minY, maxY = r0.maxY
        switch handle {
        case .corner(.nw): minX = p.x; minY = p.y
        case .corner(.ne): maxX = p.x; minY = p.y
        case .corner(.se): maxX = p.x; maxY = p.y
        case .corner(.sw): minX = p.x; maxY = p.y
        case .edge(.n): minY = p.y
        case .edge(.s): maxY = p.y
        case .edge(.w): minX = p.x
        case .edge(.e): maxX = p.x
        default:
            return (from, to)
        }
        if lockAspect, case .corner = handle {
            var w = maxX - minX
            var h = maxY - minY
            let signW: CGFloat = w < 0 ? -1 : 1
            let signH: CGFloat = h < 0 ? -1 : 1
            w = abs(w); h = abs(h)
            if w / max(h, 1e-8) > ratio {
                h = w / ratio
            } else {
                w = h * ratio
            }
            switch handle {
            case .corner(.nw):
                minX = maxX - signW * w
                minY = maxY - signH * h
            case .corner(.ne):
                maxX = minX + signW * w
                minY = maxY - signH * h
            case .corner(.se):
                maxX = minX + signW * w
                maxY = minY + signH * h
            case .corner(.sw):
                minX = maxX - signW * w
                maxY = minY + signH * h
            default: break
            }
        }
        if maxX < minX { swap(&minX, &maxX) }
        if maxY < minY { swap(&minY, &maxY) }
        if maxX - minX < shapeMinSize {
            let mid = (minX + maxX) / 2
            minX = mid - shapeMinSize / 2
            maxX = mid + shapeMinSize / 2
        }
        if maxY - minY < shapeMinSize {
            let mid = (minY + maxY) / 2
            minY = mid - shapeMinSize / 2
            maxY = mid + shapeMinSize / 2
        }
        minX = min(max(0, minX), 1 - shapeMinSize)
        minY = min(max(0, minY), 1 - shapeMinSize)
        maxX = min(max(minX + shapeMinSize, maxX), 1)
        maxY = min(max(minY + shapeMinSize, maxY), 1)
        return (CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    /// 形状命中:rect/ellipse 按 bounds 内含(便于移动);line/arrow 按线段距离,箭头另含头部三角
    static func hitShape(kind: ShapeKind, from: CGPoint, to: CGPoint, widthFraction: CGFloat,
                         canvasSize: CGSize, at point: CGPoint) -> Bool {
        switch kind {
        case .rect, .ellipse:
            return standardizedRect(from: from, to: to)
                .insetBy(dx: -0.006, dy: -0.006).contains(point)
        case .line, .arrow:
            guard canvasSize.width > 0, canvasSize.height > 0 else { return false }
            let tolerance = (max(widthFraction / 2, 0.004) + 0.006) * canvasSize.width
            let a = CGPoint(x: from.x * canvasSize.width, y: from.y * canvasSize.height)
            let b = CGPoint(x: to.x * canvasSize.width, y: to.y * canvasSize.height)
            let target = CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
            if distance(target, segment: a, b) <= tolerance { return true }
            guard kind == .arrow,
                  let head = arrowHead(from: from, to: to, widthFraction: widthFraction,
                                       canvasSize: canvasSize) else { return false }
            return triangleContains(point, a: head.tip, b: head.baseA, c: head.baseB)
        }
    }

    /// 点是否在三角形内(符号法,含退化边)
    private static func triangleContains(_ p: CGPoint, a: CGPoint, b: CGPoint, c: CGPoint) -> Bool {
        let signs = [cross(b, a, p), cross(c, b, p), cross(a, c, p)]
        let hasPositive = signs.contains { $0 > 0 }
        let hasNegative = signs.contains { $0 < 0 }
        return !(hasPositive && hasNegative)
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
        (a.x - p.x) * (b.y - p.y) - (a.y - p.y) * (b.x - p.x)
    }

    /// Ramer–Douglas–Peucker 抽稀。首尾点恒保留;直线被压缩到两端,拐点保留。
    static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, epsilon > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maxDist: CGFloat = 0
            var maxIdx = start
            for i in (start + 1)..<end {
                let d = distance(points[i], segment: points[start], points[end])
                if d > maxDist { maxDist = d; maxIdx = i }
            }
            if maxDist > epsilon {
                keep[maxIdx] = true
                stack.append((start, maxIdx))
                stack.append((maxIdx, end))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// 笔迹的归一化包围盒(含线宽外扩),无点返回 nil
    static func strokeBounds(_ points: [CGPoint], widthFraction: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = widthFraction / 2
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    }

    /// 文字命中盒,归一化坐标。`anchor` 为块左上角;度量与 `AnnotationRenderer.textSize` 同一路径。
    /// 最短边至少 0.02,避免小字点不中。
    static func textHitRect(anchor: CGPoint, content: String, sizeFraction: CGFloat,
                            imageSize: CGSize) -> CGRect {
        let fraction = MarkPalette.clampTextFraction(sizeFraction)
        let pixel = AnnotationRenderer.textSize(
            content: content, sizeFraction: fraction, canvasWidth: max(1, imageSize.width)
        )
        let width = imageSize.width > 0 ? pixel.width / imageSize.width : 0
        let height = imageSize.height > 0 ? pixel.height / imageSize.height : 0
        let minHit: CGFloat = 0.02
        return CGRect(
            x: min(max(0, anchor.x), 1),
            y: min(max(0, anchor.y), 1),
            width: max(width, minHit),
            height: max(height, minHit)
        )
    }

    /// 内容相对:图顺时针 90° 后面上的点。
    static func rotateCW90(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.y, y: p.x) }
    static func rotateCCW90(_ p: CGPoint) -> CGPoint { CGPoint(x: p.y, y: 1 - p.x) }
    static func flipH(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.x, y: p.y) }
    static func flipV(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    // MARK: 选区的同套映射
    //
    // 裁切选区与标注在同一套归一化空间,变换时必须一起映射:否则内容跟着转、
    // 选区不动,导出会裁到完全不是用户框的那一块。
    // 闭式公式由「四角点各自套上面的点变换后取包围盒」推导,并逐位校验过。

    /// 顺时针 90°:归一化矩形 (x, y, w, h) → (1−y−h, x, h, w)
    static func mappedRectCW90(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
    }

    /// 逆时针 90°
    static func mappedRectCCW90(_ r: CGRect) -> CGRect {
        CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
    }

    static func mappedRectFlipH(_ r: CGRect) -> CGRect {
        CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    static func mappedRectFlipV(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    static func mapped(_ annotation: Annotation, _ transform: (CGPoint) -> CGPoint) -> Annotation {
        var next = annotation
        switch annotation.kind {
        case let .text(anchor, content, sizeFraction, color):
            next.kind = .text(anchor: transform(anchor), content: content,
                              sizeFraction: sizeFraction, color: color)
        case let .stroke(points, widthLevel, color, style):
            next.kind = .stroke(points: points.map(transform), widthLevel: widthLevel,
                                color: color, style: style)
        case let .mosaic(points, widthLevel, effect):
            next.kind = .mosaic(points: points.map(transform), widthLevel: widthLevel, effect: effect)
        case let .shape(kind, from, to, widthLevel, color):
            next.kind = .shape(kind: kind, from: transform(from), to: transform(to),
                               widthLevel: widthLevel, color: color)
        }
        return next
    }
}

struct EditSnapshot: Equatable {
    var selection: CGRect
    var quarterTurns: Int
    var flipH: Bool
    var flipV: Bool
    var straighten: Double
    var annotations: [Annotation]
}
