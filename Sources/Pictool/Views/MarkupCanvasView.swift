import SwiftUI
import AppKit

// MARK: - 标记画布

struct MarkupCanvas: View {

    let image: NSImage
    let overlay: NSImage?
    let annotations: [Annotation]
    let selectedID: UUID?
    let tool: EditTool
    let markupColor: MarkupColor
    let sizeLevel: Int
    let mosaicEffect: MosaicEffect
    var mosaicMode: MosaicDrawMode = .brush
    let strokeStyle: StrokeStyleKind
    let shapeKind: ShapeKind
    var shapeFilled: Bool = false
    let livePoints: [CGPoint]
    /// 形状或框选马赛克实时预览:起点取自按下的 dragStartPoint,终点随手更新
    var liveShapeFrom: CGPoint?
    var liveShapeTo: CGPoint?
    /// 文字角柄改字号(B4):归一化坐标进出
    var onTextResizeStart: ((CGPoint) -> Void)?
    var onTextResizeChange: ((CGPoint) -> Void)?
    var onTextResizeEnd: (() -> Void)?
    var onShapeHandleStart: ((ShapeHandle, CGPoint) -> Void)?
    var onShapeHandleChange: ((CGPoint, Bool) -> Void)?
    var onShapeHandleEnd: (() -> Void)?
    let draftAnchor: CGPoint?
    @Binding var draftContent: String
    let draftEditingID: UUID?
    /// 双击编辑已有文字时的真实字号比例(nil 时按 sizeLevel 档位算)
    var draftSizeFraction: CGFloat? = nil
    var draftFocused: FocusState<Bool>.Binding
    let onDragStart: (CGPoint) -> Void
    /// 双击文字。返回 true 表示已进入编辑,这次按下不再当成拖动。
    var onTextDoubleClick: ((CGPoint) -> Bool)?
    let onDragChange: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void
    let onDraftSubmit: () -> Void
    let onCancel: () -> Void
    var selection: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var watermark: WatermarkSettings = WatermarkSettings()
    /// 视口缩放/平移(EditView 持有,裁切切换不销毁)
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// 橡皮悬停将删除的对象。只画高亮框,不带动选中手柄。
    var hoverID: UUID?
    /// 悬停命中(归一化坐标进出);nil 表示无悬停手型提示
    var hoverTest: ((CGPoint) -> Bool)?
    /// 指针在图上移动;离开图或画布时为 nil
    var onCanvasHover: ((CGPoint?) -> Void)?
    /// 按工具的常规光标
    var baseCursor: NSCursor = .arrow
    /// 右键菜单(归一化坐标进出);nil 表示无
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// 滚轮/捏合/空格拖(dx, dy, ⌘, 容器尺寸)等,容器尺寸由画布回传
    var onScrollGesture: ((_ dx: CGFloat, _ dy: CGFloat, _ command: Bool, _ container: CGSize) -> Void)?
    var onMagnifyGesture: ((_ factor: CGFloat, _ anchor: CGPoint, _ container: CGSize) -> Void)?
    var onPanGesture: ((_ translation: CGPoint, _ container: CGSize) -> Void)?
    var onPanGestureEnd: (() -> Void)?
    var onContainerChange: ((CGSize) -> Void)?
    /// 图片描边色。画布与顶栏同一底色后,靠这一圈极淡的描边把图片范围交代出来;
    /// 传 `.clear` 即关闭(如将来有别的画布宿主)。
    var imageBorder: Color = .clear

    var body: some View {
        GeometryReader { geo in
            let aspect = image.size.width / max(1, image.size.height)
            let fit = EditCanvasMath.viewRect(container: geo.size, imageAspect: aspect,
                                              zoom: zoom, pan: pan)
            let cropBox = CGRect(
                x: fit.minX + selection.minX * fit.width,
                y: fit.minY + selection.minY * fit.height,
                width: selection.width * fit.width,
                height: selection.height * fit.height
            )
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .allowsHitTesting(false)

                if let overlay {
                    Image(nsImage: overlay)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                        .allowsHitTesting(false)
                }

                // 裁切范围提示:压在底图之上、标注之下。标注是用户正在交互的内容,
                // 画在压暗层之上才不会在拖到框外时变灰看不清。
                cropRangeOverlay(fit: fit, cropBox: cropBox)

                // 图片描边。压在压暗层之上,边缘才是干净的一条,不会跟着压暗变灰;
                // 标注意外的东西一律画在它之后,免得盖住这条边界。
                Rectangle()
                    .strokeBorder(imageBorder, lineWidth: 1)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .allowsHitTesting(false)

                WatermarkStampLayer(settings: watermark, frame: cropBox)

                selectionOutline(fit: fit)
                eraserHoverOutline(fit: fit)

                if !livePoints.isEmpty, tool != .mosaic {
                    liveStrokePath(fit: fit)
                }

                if tool == .shape, let from = liveShapeFrom, let to = liveShapeTo {
                    liveShapePath(kind: shapeKind, from: from, to: to, fit: fit)
                }

                if tool == .mosaic, mosaicMode == .rect, let from = liveShapeFrom, let to = liveShapeTo {
                    liveMosaicRectPath(from: from, to: to, fit: fit)
                }

                CanvasMouseCatcher(
                    onDown: { point, clicks in pointerDown(point, fit: fit, clickCount: clicks) },
                    onDrag: { point in pointerDrag(point, fit: fit) },
                    onUp: { pointerUp(fit: fit) },
                    baseCursor: baseCursor,
                    hoverHitTest: hoverTest.map { test in
                        { screenPoint in
                            fit.contains(screenPoint) && test(normalized(screenPoint, fit))
                        }
                    },
                    onHoverMove: { screenPoint in
                        guard let screenPoint, fit.contains(screenPoint) else {
                            onCanvasHover?(nil)
                            return
                        }
                        onCanvasHover?(normalized(screenPoint, fit))
                    },
                    contextMenuProvider: contextMenuProvider.map { provider in
                        { screenPoint in
                            guard fit.contains(screenPoint) else { return nil }
                            return provider(normalized(screenPoint, fit))
                        }
                    },
                    onScroll: { dx, dy, command in
                        onScrollGesture?(dx, dy, command, geo.size)
                    },
                    onMagnify: { factor, anchor in
                        onMagnifyGesture?(factor, anchor, geo.size)
                    },
                    onPanStart: { },
                    onPanChange: { translation in
                        onPanGesture?(translation, geo.size)
                    },
                    onPanEnd: { onPanGestureEnd?() },
                    spacePanEnabled: !draftFocused.wrappedValue
                )
                .frame(width: geo.size.width, height: geo.size.height)

                // 草稿输入必须叠在捕获层之上,否则 TextField 点不到。
                if let anchor = draftAnchor {
                    draftEditor(anchor: anchor, fit: fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { onContainerChange?(geo.size) }
            .onChange(of: geo.size) { _, newSize in
                onContainerChange?(newSize)
            }
            .onExitCommand { onCancel() }
        }
    }

    private func normalized(_ location: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(0, (location.x - fit.minX) / fit.width), 1),
            y: min(max(0, (location.y - fit.minY) / fit.height), 1)
        )
    }

    /// 角柄拖拽专用:不夹取,允许在手柄超出 fit 边缘时仍能按真实距离算字号
    private func normalizedUnclamped(_ location: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: (location.x - fit.minX) / fit.width,
                y: (location.y - fit.minY) / fit.height)
    }

    @State private var dragStarted = false
    @State private var lastPointer = CGPoint.zero
    /// 角柄拖拽路由:按下时命中手柄则本次手势全部走 resize 回调
    @State private var resizeRouting = false
    @State private var shapeHandleRouting: ShapeHandle?
    /// 草稿期间发生过任何按键(含 IME 组合):占位文字退场,避免与候选预览重叠
    @State private var draftInteracted = false

    private func pointerDown(_ point: CGPoint, fit: CGRect, clickCount: Int) {
        lastPointer = point
        guard fit.contains(point) else {
            dragStarted = false
            return
        }
        if clickCount >= 2, tool == .text,
           onTextDoubleClick?(normalized(point, fit)) == true {
            dragStarted = false
            return
        }
        dragStarted = true
        if textResizeHandleHit(fit: fit, at: point) {
            resizeRouting = true
            onTextResizeStart?(normalizedUnclamped(point, fit))
            return
        }
        if let handle = shapeHandleHit(fit: fit, at: point) {
            resizeRouting = true
            shapeHandleRouting = handle
            onShapeHandleStart?(handle, normalized(point, fit))
            return
        }
        onDragStart(normalized(point, fit))
    }

    private func pointerDrag(_ point: CGPoint, fit: CGRect) {
        lastPointer = point
        guard dragStarted else { return }
        let normalizedPoint = normalized(point, fit)
        if resizeRouting, shapeHandleRouting != nil {
            onShapeHandleChange?(normalizedPoint, NSEvent.modifierFlags.contains(.shift))
        } else if resizeRouting {
            onTextResizeChange?(normalizedUnclamped(point, fit))
        } else {
            onDragChange(normalizedPoint)
        }
    }

    private func pointerUp(fit: CGRect) {
        if dragStarted {
            let normalizedPoint = normalized(lastPointer, fit)
            if resizeRouting, shapeHandleRouting != nil {
                onShapeHandleChange?(normalizedPoint, NSEvent.modifierFlags.contains(.shift))
                onShapeHandleEnd?()
                shapeHandleRouting = nil
                resizeRouting = false
            } else if resizeRouting {
                onTextResizeChange?(normalizedUnclamped(lastPointer, fit))
                onTextResizeEnd?()
                resizeRouting = false
            } else {
                onDragEnd(normalizedPoint)
            }
        }
        dragStarted = false
    }

    /// 选中文字时右下角手柄(容器坐标 ~9pt,不随缩放);命中半径 12pt
    private func textResizeHandleHit(fit: CGRect, at point: CGPoint) -> Bool {
        guard selectedIsText, let bounds = selectionBounds(fit: fit) else { return false }
        let center = CGPoint(x: bounds.maxX + 4.5, y: bounds.maxY + 4.5)
        return hypot(point.x - center.x, point.y - center.y) <= 12
    }

    private func shapeHandleHit(fit: CGRect, at point: CGPoint) -> ShapeHandle? {
        guard let id = selectedID,
              case let .shape(kind, from, to, _, _, _) = annotations.first(where: { $0.id == id })?.kind
        else { return nil }
        var best: ShapeHandle?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (handle, p) in MarkupGeometry.shapeHandles(kind: kind, from: from, to: to) {
            let screen = CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
            let d = hypot(point.x - screen.x, point.y - screen.y)
            if d <= 12, d < bestDist {
                bestDist = d
                best = handle
            }
        }
        return best
    }

    private func handleKnob(at point: CGPoint, fit: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5)
            )
            .shadow(radius: 1)
            .position(x: fit.minX + point.x * fit.width, y: fit.minY + point.y * fit.height)
            .allowsHitTesting(false)
    }

    private var selectedIsText: Bool {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return false }
        if case .text = annotation.kind { return true }
        return false
    }

    /// 形状只亮手柄,不套包围虚线框。
    private var selectedHidesBoundsBox: Bool {
        guard let id = selectedID,
              case .shape = annotations.first(where: { $0.id == id })?.kind
        else { return false }
        return true
    }

    /// 形状实时预览(SwiftUI Path,不进 overlay 重绘管线)
    private func liveShapePath(kind: ShapeKind, from: CGPoint, to: CGPoint, fit: CGRect) -> some View {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
        }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                   width: r.width * fit.width, height: r.height * fit.height)
        }
        let widthFraction = MarkPalette.fraction(MarkPalette.strokeWidths, level: sizeLevel)
        let width = max(1, widthFraction * fit.width)
        let color = Color(nsColor: MarkPalette.nsColor(markupColor))
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        let canvas = CGSize(width: fit.width, height: fit.height)
        return Group {
            switch kind {
            case .rect:
                let r = rect(MarkupGeometry.standardizedRect(from: from, to: to))
                ZStack {
                    if shapeFilled {
                        Path(r).fill(color.opacity(0.24))
                    }
                    Path(r).stroke(color, style: style)
                }
            case .ellipse:
                let r = rect(MarkupGeometry.standardizedRect(from: from, to: to))
                ZStack {
                    if shapeFilled {
                        Path(ellipseIn: r).fill(color.opacity(0.24))
                    }
                    Path(ellipseIn: r).stroke(color, style: style)
                }
            case .line, .arrow:
                Path { path in
                    path.move(to: point(from))
                    path.addLine(to: point(to))
                }
                .stroke(color, style: style)
                .overlay {
                    if kind == .arrow,
                       let head = MarkupGeometry.arrowHead(from: from, to: to,
                                                           widthFraction: widthFraction,
                                                           canvasSize: canvas) {
                        // 头部实心,与提交后的渲染一致
                        Path { path in
                            path.move(to: point(head.tip))
                            path.addLine(to: point(head.baseA))
                            path.addLine(to: point(head.baseB))
                            path.closeSubpath()
                        }
                        .fill(color)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 框选马赛克实时虚线预览框
    private func liveMosaicRectPath(from: CGPoint, to: CGPoint, fit: CGRect) -> some View {
        let norm = MarkupGeometry.standardizedRect(from: from, to: to)
        let rect = CGRect(
            x: fit.minX + norm.minX * fit.width,
            y: fit.minY + norm.minY * fit.height,
            width: max(1, norm.width * fit.width),
            height: max(1, norm.height * fit.height)
        )
        return ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.14))
            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private func liveStrokePath(fit: CGRect) -> some View {
        let points = livePoints.map { p in
            CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
        }
        // 画笔样式:荧光 = 宽表 + 45% alpha,中点二次贝塞尔插值与导出渲染 100% 一致
        let style = strokeStyle
        let widthFraction = MarkPalette.fraction(MarkPalette.widthTable(for: style), level: sizeLevel)
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            if points.count == 2 {
                path.addLine(to: points[1])
            } else if points.count > 2 {
                for i in 1..<(points.count - 1) {
                    let mid = CGPoint(
                        x: (points[i].x + points[i + 1].x) / 2,
                        y: (points[i].y + points[i + 1].y) / 2
                    )
                    path.addQuadCurve(to: mid, control: points[i])
                }
                path.addLine(to: points[points.count - 1])
            }
        }
        .stroke(
            Color(nsColor: MarkPalette.nsColor(markupColor))
                .opacity(style == .highlighter ? 0.45 : 1),
            style: StrokeStyle(lineWidth: max(1, widthFraction * fit.width),
                               lineCap: .round, lineJoin: .round)
        )
        .allowsHitTesting(false)
    }

    private func selectionBounds(fit: CGRect) -> CGRect? {
        bounds(of: selectedID, fit: fit)
    }

    private func bounds(of id: UUID?, fit: CGRect) -> CGRect? {
        guard let id,
              let annotation = annotations.first(where: { $0.id == id }) else { return nil }
        let imageSize = image.size
        let normalizedBounds: CGRect?
        switch annotation.kind {
        case let .text(anchor, content, sizeFraction, _, _):
            normalizedBounds = MarkupGeometry.textHitRect(
                anchor: anchor, content: content, sizeFraction: sizeFraction, imageSize: imageSize
            )
        case let .step(anchor, _, sizeFraction, _):
            normalizedBounds = MarkupGeometry.stepHitRect(
                anchor: anchor, sizeFraction: sizeFraction, imageSize: imageSize
            )
        case let .stroke(points, widthLevel, _, style):
            normalizedBounds = MarkupGeometry.strokeBounds(
                points, widthFraction: MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel)
            )
        case let .mosaic(points, widthLevel, _):
            normalizedBounds = MarkupGeometry.strokeBounds(
                points, widthFraction: MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel)
            )
        case let .mosaicRect(from, to, _, _):
            normalizedBounds = MarkupGeometry.standardizedRect(from: from, to: to)
        case let .shape(kind, from, to, widthLevel, _, _):
            normalizedBounds = MarkupGeometry.shapeBounds(
                kind: kind, from: from, to: to,
                widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                canvasSize: imageSize
            )
        }
        guard let b = normalizedBounds else { return nil }
        return CGRect(x: fit.minX + b.minX * fit.width,
                      y: fit.minY + b.minY * fit.height,
                      width: b.width * fit.width,
                      height: b.height * fit.height)
    }

    /// 是否已经裁掉了一部分画面。用容差比较:拖到边缘时归一化坐标常留下 0.999… 的残差,
    /// 直接 != 全图会让选框一直亮着,变成视觉噪音。
    private var hasCropRange: Bool {
        let eps: CGFloat = 0.001
        return selection.minX > eps
            || selection.minY > eps
            || selection.maxX < 1 - eps
            || selection.maxY < 1 - eps
    }

    /// 标记工具下的裁切范围提示:框外压暗 + 双层虚线框,与 CropCanvas 的选框同一套视觉。
    /// 标记工具不承担裁剪交互(那是 CropCanvas 的活),这里只是「让你看见导出边界会切在哪」,
    /// 所以整体 allowsHitTesting(false),不抢 CanvasMouseCatcher 的事件。
    /// 没裁切时完全不画,避免无谓的视觉噪音。
    @ViewBuilder
    private func cropRangeOverlay(fit: CGRect, cropBox: CGRect) -> some View {
        if hasCropRange {
            Path { path in
                path.addRect(fit)
                path.addRect(cropBox)
            }
            .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2.2)
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(width: cropBox.width, height: cropBox.height)
            .offset(x: cropBox.minX, y: cropBox.minY)
            .allowsHitTesting(false)
        }
    }

    /// 橡皮悬停:红虚线框出将整笔删掉的对象,不显示手柄。
    @ViewBuilder
    private func eraserHoverOutline(fit: CGRect) -> some View {
        if tool == .eraser, let bounds = bounds(of: hoverID, fit: fit) {
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 2.2)
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
            }
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func selectionOutline(fit: CGRect) -> some View {
        if let bounds = selectionBounds(fit: fit), !selectedHidesBoundsBox {
            // 双层:白底衬深色虚线,浅色背景上也看得清
            ZStack {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2.2)
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
            .overlay(alignment: .bottomTrailing) {
                // 文字角柄:拖拽改字号(容器坐标恒定尺寸)
                if selectedIsText {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.55), lineWidth: 0.5)
                        )
                        .shadow(radius: 1)
                        .offset(x: 4.5, y: 4.5)
                }
            }
            .allowsHitTesting(false)
        }
        if let id = selectedID,
           case let .shape(kind, from, to, _, _, _) = annotations.first(where: { $0.id == id })?.kind {
            ForEach(Array(MarkupGeometry.shapeHandles(kind: kind, from: from, to: to).enumerated()),
                    id: \.offset) { _, item in
                handleKnob(at: item.1, fit: fit)
            }
        }
    }

    private func draftEditor(anchor: CGPoint, fit: CGRect) -> some View {
        let fraction = draftSizeFraction ?? MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel)
        let fontSize = max(10, fit.width * fraction)
        let font = Font.system(size: fontSize, weight: .medium)
        // 占位提示自己叠 Text:macOS 上 TextField(prompt:) 的颜色在 plain 样式下不生效
        return ZStack(alignment: .leading) {
            if draftContent.isEmpty && !draftInteracted {
                Text("输入文字,回车确认")
                    .font(font)
                    // 占位是次级信息:60% 白,轻透但压得住底图
                    .foregroundStyle(.white.opacity(0.6))
                    .allowsHitTesting(false)
            }
            TextField("", text: $draftContent)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Color(nsColor: MarkPalette.nsColor(markupColor)))
                .focused(draftFocused)
                .onSubmit { onDraftSubmit() }
            // NSViewRepresentable 无固有尺寸,不给 frame 会撑满画布把草稿框撑爆
            DraftKeyProbe { draftInteracted = true }
                .frame(width: 0, height: 0)
        }
        .frame(width: max(120, fit.width * 0.4), alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)
                // 强制深色磨砂:最轻一档,通透但有质感,深色底保证文字可读
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
        }
        .position(
            x: fit.minX + anchor.x * fit.width + max(60, fit.width * 0.2),
            y: fit.minY + anchor.y * fit.height + fontSize * 0.9
        )
        .onChange(of: anchor) { _, _ in draftInteracted = false }
    }
}

/// 草稿输入期间监听第一次按键:输入法组合文字不更新 binding,占位文字若不退场会与候选预览重叠。
/// 视图挂在草稿框里,随草稿创建/销毁,监听器生命周期与其一致。
struct DraftKeyProbe: NSViewRepresentable {
    var onFirstKey: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFirstKey = onFirstKey
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onFirstKey = onFirstKey
    }

    final class ProbeView: NSView {
        var onFirstKey: (() -> Void)?
        /// deinit 是 nonisolated 的,Swift 6 不允许它调用 MainActor 隔离的 `teardown()`。
        /// `NSEvent.removeMonitor` 本身线程安全,这里显式标注豁免,并在 deinit 里直接摘除。
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    self?.fireOnce()
                    return event
                }
            } else if window == nil {
                teardown()
            }
        }

        private func fireOnce() {
            guard let handler = onFirstKey else { return }
            teardown()
            onFirstKey = nil
            handler()
        }

        private func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

