import SwiftUI
import AppKit

extension EditView {

    // MARK: 交互回调(归一化坐标)

    func handleDragStart(at point: CGPoint) {
        if draftAnchor != nil { commitDraft(); return }
        erasedInGesture = false
        moveUndoPushed = false
        selectingExisting = false
        grabOffset = .zero
        dragStartPoint = point
        moveStartPoints = []
        switch tool {
        case .crop:
            break
        case .eraser:
            erase(at: point)
        case .text, .step, .brush, .mosaic, .shape:
            if let hit = hitTest(at: point, kinds: [.text, .step, .brush, .mosaic, .shape]) {
                selectedID = hit
                selectingExisting = true
                tapCandidate = false
                switch annotations.first(where: { $0.id == hit })?.kind {
                case let .text(anchor, _, _, _, _):
                    grabOffset = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
                case let .step(anchor, _, _, _):
                    grabOffset = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
                case let .stroke(points, _, _, _):
                    moveStartPoints = points
                case let .mosaic(points, _, _):
                    moveStartPoints = points
                case let .mosaicRect(from, to, _, _):
                    moveStartFrom = from
                    moveStartTo = to
                case let .shape(_, from, to, _, _, _):
                    moveStartFrom = from
                    moveStartTo = to
                default:
                    break
                }
            } else {
                selectNone()
                if tool == .text || tool == .step {
                    tapCandidate = true
                } else if tool == .shape || (tool == .mosaic && mosaicMode == .rect) {
                    liveShapeTo = point
                } else {
                    livePoints = [point]
                }
            }
        }
    }

    /// 起手位移小于阈值视为点击(不触发移动)
    func withinTapThreshold(_ point: CGPoint) -> Bool {
        guard let start = dragStartPoint else { return false }
        return hypot(point.x - start.x, point.y - start.y) < 0.008
    }

    func handleDragChange(at point: CGPoint) {
        switch tool {
        case .crop:
            break
        case .brush, .mosaic:
            if selectingExisting {
                guard !withinTapThreshold(point) else { return }
                moveSelected(to: point)
            } else if tool == .mosaic, mosaicMode == .rect {
                liveShapeTo = point
            } else {
                if let last = livePoints.last,
                   abs(point.x - last.x) < 0.0015, abs(point.y - last.y) < 0.0015 { return }
                livePoints.append(point)
            }
        case .shape:
            if selectingExisting {
                guard !withinTapThreshold(point) else { return }
                moveSelected(to: point)
            } else {
                if let start = dragStartPoint, NSEvent.modifierFlags.contains(.shift) {
                    let imgSize = transformedPixelSize.width > 0 ? transformedPixelSize : (displayPreview?.size ?? CGSize(width: 1000, height: 1000))
                    liveShapeTo = MarkupGeometry.constrainedNewShapeEnd(
                        kind: shapeKind, from: start, to: point, imageSize: imgSize
                    )
                } else {
                    liveShapeTo = point
                }
            }
        case .eraser:
            erase(at: point)
        case .text, .step:
            guard selectedID != nil, !withinTapThreshold(point) else { return }
            moveSelected(to: point)
        }
    }

    func handleDragEnd(at point: CGPoint) {
        let start = dragStartPoint
        let movedFar: Bool = {
            guard let start else { return false }
            return hypot(point.x - start.x, point.y - start.y) >= 0.008
        }()
        switch tool {
        case .crop:
            break
        case .brush, .mosaic:
            if !selectingExisting {
                if tool == .mosaic, mosaicMode == .rect {
                    commitMosaicRect(at: point)
                } else {
                    commitStroke()
                }
            }
        case .shape:
            if !selectingExisting { commitShape(at: liveShapeTo ?? point) }
        case .eraser:
            break
        case .step:
            if tapCandidate, !movedFar {
                commitStep(at: point)
            }
            tapCandidate = false
            moveUndoPushed = false
        case .text:
            if selectingExisting, !movedFar {
                if let hit = selectedID, hit == lastTapID, Date().timeIntervalSince(lastTapTime) < 0.45 {
                    beginEdit(id: hit)
                }
                lastTapID = selectedID
                lastTapTime = Date()
            } else if tapCandidate, !movedFar, draftAnchor == nil {
                beginDraft(at: point)
                lastTapID = nil
                lastTapTime = Date()
            }
            tapCandidate = false
            moveUndoPushed = false
        }
        livePoints = []
        liveShapeTo = nil
        selectingExisting = false
        dragStartPoint = nil
    }

    /// 形状提交:起止距离过小视为误触不成形
    func commitShape(at point: CGPoint) {
        guard let start = dragStartPoint else { return }
        guard hypot(point.x - start.x, point.y - start.y) >= 0.01 else { return }
        pushUndo()
        let filled = (shapeKind == .rect || shapeKind == .ellipse) ? shapeFilled : false
        annotations.append(Annotation(kind: .shape(
            kind: shapeKind, from: start, to: point, widthLevel: sizeLevel, color: markupColor,
            filled: filled
        )))
        selectedID = annotations.last?.id
    }

    /// 下一个步骤序号:取当前画布最大序号 + 1
    var nextStepNumber: Int {
        let currentMax = annotations.compactMap { ann -> Int? in
            if case let .step(_, number, _, _) = ann.kind { return number }
            return nil
        }.max() ?? 0
        return currentMax + 1
    }

    /// 放置一个步骤序号气泡
    func commitStep(at point: CGPoint) {
        pushUndo()
        annotations.append(Annotation(kind: .step(
            anchor: point,
            number: nextStepNumber,
            sizeFraction: MarkPalette.fraction(MarkPalette.stepSizes, level: sizeLevel),
            color: markupColor
        )))
        selectedID = annotations.last?.id
    }

    /// Vision 人脸检测并一键生成马赛克框
    func detectAndMosaicFaces() {
        guard !detectingFaces, let cg = displayCG else { return }
        detectingFaces = true
        let level = sizeLevel
        let effect = mosaicEffect
        Task {
            let rects = await Task.detached(priority: .userInitiated) {
                FaceMosaicService.detectFaceRects(in: cg)
            }.value
            detectingFaces = false
            guard !rects.isEmpty else {
                showStatusNotice("未检测到人脸")
                return
            }
            pushUndo()
            for r in rects {
                annotations.append(Annotation(kind: .mosaicRect(
                    from: CGPoint(x: r.minX, y: r.minY),
                    to: CGPoint(x: r.maxX, y: r.maxY),
                    widthLevel: level,
                    effect: effect
                )))
            }
            selectedID = annotations.last?.id
            showStatusNotice("已自动打码 \(rects.count) 张人脸")
        }
    }

    /// 框选马赛克提交:一步拉框整齐遮盖矩形区域
    func commitMosaicRect(at point: CGPoint) {
        guard let start = dragStartPoint else { return }
        let rect = MarkupGeometry.standardizedRect(from: start, to: point)
        guard rect.width >= 0.008, rect.height >= 0.008 else { return }
        pushUndo()
        annotations.append(Annotation(kind: .mosaicRect(
            from: start, to: point, widthLevel: sizeLevel, effect: mosaicEffect
        )))
        selectedID = annotations.last?.id
    }

    /// Esc 的优先级:先收弹层 → 再退草稿 → 再取消选中 → 最后才退出编辑。
    func handleEscape() {
        if showColorPopover || showCropPopover || showExportPopover || showWatermarkSettings || showAdjustPopover {
            showColorPopover = false
            showCropPopover = false
            showExportPopover = false
            showWatermarkSettings = false
            showAdjustPopover = false
        } else if draftAnchor != nil {
            cancelDraft()
        } else if selectedID != nil {
            selectNone()
        } else {
            onClose()
        }
    }

    // MARK: 右键菜单

    func contextMenu(at point: CGPoint) -> NSMenu? {
        if draftAnchor != nil { commitDraft() }
        guard let hit = hitTest(at: point, kinds: [.text, .brush, .mosaic, .shape]) else { return nil }
        if selectedID != hit { selectedID = hit }
        let menu = NSMenu()
        contextBoxes.removeAll()
        if case .text = annotations.first(where: { $0.id == hit })?.kind {
            menu.addItem(menuItem("编辑文字") { beginEdit(id: hit) })
        }
        menu.addItem(menuItem("删除") { deleteSelected() })
        return menu
    }

    /// NSMenuItem.target 不持有 target,box 挂在 @State 数组上保活
    func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let box = ContextActionBox(handler: handler)
        contextBoxes.append(box)
        let item = NSMenuItem(
            title: title, action: #selector(ContextActionBox.perform(_:)), keyEquivalent: ""
        )
        item.target = box
        return item
    }

    /// 全选 / 重置选框在画布右键,不放进裁切弹层。
    func cropContextMenu() -> NSMenu? {
        guard !previewFailed else { return nil }
        let menu = NSMenu()
        contextBoxes.removeAll()
        menu.addItem(menuItem("全选") {
            mutateSelection(CGRect(x: 0, y: 0, width: 1, height: 1))
        })
        menu.addItem(menuItem("重置选框") {
            mutateSelection(CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84))
        })
        return menu
    }

    // MARK: 命中与编辑

    func hitTest(at point: CGPoint, kinds: [EditTool]) -> UUID? {
        guard let base = displayCG ?? basePreview else { return nil }
        let canvasSize = CGSize(width: base.width, height: base.height)
        for annotation in annotations.reversed() {
            guard let kind = kindOf(annotation), kinds.contains(kind) else { continue }
            switch annotation.kind {
            case let .text(anchor, content, sizeFraction, _, _):
                let bounds = MarkupGeometry.textHitRect(
                    anchor: anchor, content: content, sizeFraction: sizeFraction, imageSize: canvasSize
                )
                if bounds.insetBy(dx: -0.006, dy: -0.006).contains(point) { return annotation.id }
            case let .step(anchor, _, sizeFraction, _):
                if MarkupGeometry.stepHit(point: point, anchor: anchor,
                                          sizeFraction: sizeFraction, imageSize: canvasSize) {
                    return annotation.id
                }
            case let .stroke(points, widthLevel, _, style):
                if MarkupGeometry.stroke(points, contains: point,
                                         widthFraction: MarkPalette.fraction(MarkPalette.widthTable(for: style), level: widthLevel),
                                         canvasSize: canvasSize) {
                    return annotation.id
                }
            case let .mosaic(points, widthLevel, _):
                if MarkupGeometry.stroke(points, contains: point,
                                         widthFraction: MarkPalette.fraction(MarkPalette.mosaicWidths, level: widthLevel),
                                         canvasSize: canvasSize) {
                    return annotation.id
                }
            case let .mosaicRect(from, to, _, _):
                let bounds = MarkupGeometry.standardizedRect(from: from, to: to)
                if bounds.insetBy(dx: -0.005, dy: -0.005).contains(point) { return annotation.id }
            case let .shape(kind, from, to, widthLevel, _, _):
                if MarkupGeometry.hitShape(kind: kind, from: from, to: to,
                                           widthFraction: MarkPalette.fraction(MarkPalette.strokeWidths, level: widthLevel),
                                           canvasSize: canvasSize, at: point) {
                    return annotation.id
                }
            }
        }
        return nil
    }

    func kindOf(_ annotation: Annotation) -> EditTool? {
        switch annotation.kind {
        case .text: .text
        case .step: .step
        case .stroke: .brush
        case .mosaic, .mosaicRect: .mosaic
        case .shape: .shape
        }
    }

    func moveSelected(to point: CGPoint) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, colorIdx, hasBackground):
            // 文字从抓取偏移绝对定位(grabOffset 在手势起点固定),无逐帧漂移
            let target = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
            let next = MarkupGeometry.moved(anchor: target, by: .zero)
            guard next != anchor else { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .text(
                anchor: next, content: content, sizeFraction: sizeFraction,
                color: colorIdx, hasBackground: hasBackground
            )
        case let .step(anchor, number, sizeFraction, colorIdx):
            let target = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
            let next = MarkupGeometry.moved(anchor: target, by: .zero)
            guard next != anchor else { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .step(
                anchor: next, number: number, sizeFraction: sizeFraction, color: colorIdx
            )
        case let .stroke(_, widthLevel, colorIdx, style):
            guard let start = dragStartPoint else { return }
            let moved = MarkupGeometry.clampedTranslate(
                points: moveStartPoints,
                dx: point.x - start.x, dy: point.y - start.y
            )
            if case let .stroke(current, _, _, _) = annotations[index].kind, moved == current { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .stroke(points: moved, widthLevel: widthLevel,
                                              color: colorIdx, style: style)
        case let .mosaic(_, widthLevel, effect):
            guard let start = dragStartPoint else { return }
            let moved = MarkupGeometry.clampedTranslate(
                points: moveStartPoints,
                dx: point.x - start.x, dy: point.y - start.y
            )
            if case let .mosaic(current, _, _) = annotations[index].kind, moved == current { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .mosaic(points: moved, widthLevel: widthLevel, effect: effect)
        case let .mosaicRect(_, _, widthLevel, effect):
            guard let start = dragStartPoint else { return }
            let dx = point.x - start.x, dy = point.y - start.y
            let moved = MarkupGeometry.clampedTranslate(
                points: [moveStartFrom, moveStartTo], dx: dx, dy: dy
            )
            if case let .mosaicRect(from, to, _, _) = annotations[index].kind,
               moved[0] == from, moved[1] == to { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .mosaicRect(from: moved[0], to: moved[1],
                                                  widthLevel: widthLevel, effect: effect)
        case let .shape(kind, _, _, widthLevel, colorIdx, filled):
            guard let start = dragStartPoint else { return }
            let dx = point.x - start.x, dy = point.y - start.y
            let moved = MarkupGeometry.clampedTranslate(
                points: [moveStartFrom, moveStartTo], dx: dx, dy: dy
            )
            if case let .shape(_, from, to, _, _, _) = annotations[index].kind,
               moved[0] == from, moved[1] == to { return }
            pushUndoForMoveIfFirst()
            annotations[index].kind = .shape(kind: kind, from: moved[0], to: moved[1],
                                             widthLevel: widthLevel, color: colorIdx, filled: filled)
        }
    }

    func pushUndoForMoveIfFirst() {
        guard !moveUndoPushed else { return }
        moveUndoPushed = true
        pushUndo()
    }

    func beginEdit(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }),
              case let .text(anchor, content, sizeFraction, _, _) = annotation.kind else { return }
        selectedID = id
        draftEditingID = id
        draftSizeFraction = sizeFraction
        draftAnchor = anchor
        draftContent = content
        draftFocused = true
    }

    func beginDraft(at point: CGPoint) {
        draftEditingID = nil
        draftSizeFraction = nil
        draftAnchor = point
        draftContent = ""
        draftFocused = true
    }

    func commitDraft() {
        guard let anchor = draftAnchor else { return }
        let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            draftAnchor = nil
            draftContent = ""
            draftEditingID = nil
            draftSizeFraction = nil
            draftFocused = false
        }
        guard !content.isEmpty else { return }
        pushUndo()
        if let id = draftEditingID,
           let index = annotations.firstIndex(where: { $0.id == id }),
           case let .text(_, _, sizeFraction, colorIdx, hasBackground) = annotations[index].kind {
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: sizeFraction, color: colorIdx,
                                            hasBackground: hasBackground)
        } else {
            annotations.append(Annotation(kind: .text(
                anchor: anchor, content: content,
                sizeFraction: MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel),
                color: markupColor,
                hasBackground: textHasBackground
            )))
            selectedID = annotations.last?.id
        }
    }

    func cancelDraft() {
        draftAnchor = nil
        draftContent = ""
        draftEditingID = nil
        draftSizeFraction = nil
        draftFocused = false
    }

    // MARK: 笔迹 / 橡皮

    func commitStroke() {
        guard !livePoints.isEmpty else { return }
        let simplified = MarkupGeometry.rdp(livePoints, epsilon: 0.002)
        guard !simplified.isEmpty else { return }
        pushUndo()
        switch tool {
        case .mosaic:
            annotations.append(Annotation(kind: .mosaic(
                points: simplified, widthLevel: sizeLevel, effect: mosaicEffect
            )))
        default:
            annotations.append(Annotation(kind: .stroke(
                points: simplified, widthLevel: sizeLevel, color: markupColor,
                style: strokeStyle
            )))
        }
        selectedID = annotations.last?.id
    }

    func erase(at point: CGPoint) {
        if let hit = hitTest(at: point, kinds: [.text, .step, .brush, .mosaic, .shape]) {
            if !erasedInGesture {
                pushUndo()
                erasedInGesture = true
            }
            annotations.removeAll { $0.id == hit }
            if selectedID == hit { selectNone() }
        }
    }

    // MARK: 撤销 / 选中 / 删除

    func syncControlsFromSelection() {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return }
        syncingControls = true
        switch annotation.kind {
        case let .text(_, _, sizeFraction, color, hasBackground):
            self.sizeLevel = MarkPalette.nearestTextLevel(sizeFraction)
            self.markupColor = color
            self.textHasBackground = hasBackground
        case let .step(_, _, sizeFraction, color):
            var best = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (i, s) in MarkPalette.stepSizes.enumerated() where abs(s - sizeFraction) < bestDist {
                bestDist = abs(s - sizeFraction); best = i
            }
            self.sizeLevel = best
            self.markupColor = color
        case let .stroke(_, widthLevel, color, style):
            self.sizeLevel = widthLevel
            self.markupColor = color
            self.strokeStyle = style
        case let .mosaic(_, widthLevel, effect):
            self.sizeLevel = widthLevel
            self.mosaicEffect = effect
        case let .mosaicRect(_, _, widthLevel, effect):
            self.sizeLevel = widthLevel
            self.mosaicEffect = effect
        case let .shape(_, _, _, widthLevel, color, filled):
            self.sizeLevel = widthLevel
            self.markupColor = color
            self.shapeFilled = filled
        }
        syncingControls = false
    }

    func applySizeLevelToSelection() {
        guard !syncingControls,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, old, color, hasBackground):
            let target = MarkPalette.fraction(MarkPalette.textSizes, level: sizeLevel)
            guard old != target else { return }
            pushUndo()
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: target, color: color,
                                            hasBackground: hasBackground)
        case let .step(anchor, number, old, color):
            let target = MarkPalette.fraction(MarkPalette.stepSizes, level: sizeLevel)
            guard old != target else { return }
            pushUndo()
            annotations[index].kind = .step(anchor: anchor, number: number,
                                            sizeFraction: target, color: color)
        case let .stroke(points, old, color, style):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .stroke(points: points, widthLevel: sizeLevel,
                                              color: color, style: style)
        case let .mosaic(points, old, effect):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .mosaic(points: points, widthLevel: sizeLevel, effect: effect)
        case let .mosaicRect(from, to, old, effect):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .mosaicRect(from: from, to: to, widthLevel: sizeLevel, effect: effect)
        case let .shape(kind, from, to, old, color, filled):
            guard old != sizeLevel else { return }
            pushUndo()
            annotations[index].kind = .shape(kind: kind, from: from, to: to,
                                             widthLevel: sizeLevel, color: color, filled: filled)
        }
    }

    func applyStrokeStyleToSelection(_ style: StrokeStyleKind) {
        strokeStyle = style
        guard !syncingControls,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case let .stroke(points, widthLevel, color, old) = annotations[index].kind,
              old != style else { return }
        pushUndo()
        annotations[index].kind = .stroke(points: points, widthLevel: widthLevel,
                                          color: color, style: style)
    }

    func stepSizeLevel(_ delta: Int) {
        let next = min(max(0, sizeLevel + delta), MarkPalette.textSizes.count - 1)
        guard next != sizeLevel else { return }
        sizeLevel = next
        applySizeLevelToSelection()
    }

    func copySelectedAnnotation() {
        guard let id = selectedID,
              let annotation = annotations.first(where: { $0.id == id }) else { return }
        annotationStore.copyToClipboard(annotation)
    }

    func pasteAnnotation() {
        guard let source = annotationStore.clipboard else { return }
        pushUndo()
        let pasted = Annotation(kind: MarkupGeometry.offset(
            source.kind, dx: MarkupGeometry.pasteNudge, dy: MarkupGeometry.pasteNudge
        ))
        annotations.append(pasted)
        selectedID = pasted.id
    }

    func applyColorToSelection(_ newColor: MarkupColor, recordUndo: Bool = true) {
        markupColor = newColor
        guard !syncingControls,
              let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, old, hasBackground):
            guard old != newColor else { return }
            if recordUndo { pushUndo() }
            annotations[index].kind = .text(anchor: anchor, content: content,
                                            sizeFraction: sizeFraction, color: newColor,
                                            hasBackground: hasBackground)
        case let .step(anchor, number, sizeFraction, old):
            guard old != newColor else { return }
            if recordUndo { pushUndo() }
            annotations[index].kind = .step(anchor: anchor, number: number,
                                            sizeFraction: sizeFraction, color: newColor)
        case let .stroke(points, widthLevel, old, style):
            guard old != newColor else { return }
            if recordUndo { pushUndo() }
            annotations[index].kind = .stroke(points: points, widthLevel: widthLevel,
                                              color: newColor, style: style)
        case let .shape(kind, from, to, widthLevel, old, filled):
            guard old != newColor else { return }
            if recordUndo { pushUndo() }
            annotations[index].kind = .shape(kind: kind, from: from, to: to,
                                             widthLevel: widthLevel, color: newColor, filled: filled)
        case .mosaic, .mosaicRect:
            break
        }
    }

    func currentSnapshot() -> EditSnapshot {
        EditSnapshot(selection: selection, ratio: ratio, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV,
                     straighten: straighten, adjustments: adjustments, annotations: annotations, selectedID: selectedID)
    }

    static let maxUndoSteps = 50

    func applySnapshot(_ snap: EditSnapshot) {
        let transformChanged = snap.quarterTurns != quarterTurns || snap.flipH != flipH
            || snap.flipV != flipV || snap.straighten != straighten
        let adjustmentsChanged = snap.adjustments != adjustments
        let annotationsChanged = snap.annotations != annotations
        selection = snap.selection
        ratio = snap.ratio
        quarterTurns = snap.quarterTurns
        flipH = snap.flipH
        flipV = snap.flipV
        straighten = snap.straighten
        adjustments = snap.adjustments
        annotations = snap.annotations
        selectedID = snap.selectedID.flatMap { id in
            annotations.contains(where: { $0.id == id }) ? id : nil
        }
        if transformChanged {
            rebuildTransformedPreview()
        } else if !annotationsChanged && !adjustmentsChanged {
            // annotations / adjustments 变化时会由各自的 onChange 触发重绘，
            // 避免 Undo/Redo 双重重绘整个叠层。
            rebuildOverlay()
        }
    }

    func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > Self.maxUndoSteps {
            undoStack.removeFirst(undoStack.count - Self.maxUndoSteps)
        }
        redoStack.removeAll()
    }

    func beginUndoGroup() { pushUndo() }

    func undo() {
        cancelDraft()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(last)
    }

    func redo() {
        cancelDraft()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(next)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectNone()
    }

    func selectNone() {
        selectedID = nil
        moveUndoPushed = false
        selectingExisting = false
    }


    // MARK: 画布视口(缩放/平移)

    var canvasImageAspect: CGFloat {
        transformedPixelSize.height > 0 ? transformedPixelSize.width / transformedPixelSize.height : 1
    }

    /// 滚轮:⌘ = 缩放(锚点视口中心由 MarkupCanvas 传容器后取中心),否则平移(方向随手指)。
    func handleCanvasScroll(dx: CGFloat, dy: CGFloat, command: Bool, container: CGSize) {
        guard tool != .crop, displayPreview != nil, container.width > 0 else { return }
        if command {
            let factor = exp(-max(-60, min(60, dy)) * 0.01)
            applyCanvasZoom(factor: factor, anchor: CGPoint(x: container.width / 2, y: container.height / 2),
                            container: container)
        } else {
            editPan = EditCanvasMath.panned(pan: editPan, delta: CGSize(width: dx, height: dy),
                                            container: container, imageAspect: canvasImageAspect,
                                            zoom: editZoom)
        }
    }

    func handleCanvasMagnify(factor: CGFloat, anchor: CGPoint, container: CGSize) {
        guard tool != .crop, displayPreview != nil else { return }
        applyCanvasZoom(factor: factor, anchor: anchor, container: container)
    }

    func handleCanvasPan(translation: CGPoint, container: CGSize) {
        guard tool != .crop, displayPreview != nil else { return }
        let delta = CGSize(width: translation.x - lastPanTranslation.x,
                           height: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        editPan = EditCanvasMath.panned(pan: editPan, delta: delta,
                                        container: container, imageAspect: canvasImageAspect,
                                        zoom: editZoom)
    }

    func applyCanvasZoom(factor: CGFloat, anchor: CGPoint, container: CGSize) {
        let result = EditCanvasMath.zoomed(zoom: editZoom, pan: editPan, factor: factor,
                                           anchor: anchor, container: container,
                                           imageAspect: canvasImageAspect)
        editZoom = result.zoom
        editPan = result.pan
    }

    /// 窗口 resize:原视口中心处的内容点仍保持在新容器中心
    func handleCanvasResize(_ newSize: CGSize) {
        let old = canvasContainerSize
        canvasContainerSize = newSize
        guard tool != .crop, displayPreview != nil, old.width > 0, old.height > 0,
              newSize.width > 0, newSize.height > 0, old != newSize else { return }
        let oldRect = EditCanvasMath.viewRect(container: old, imageAspect: canvasImageAspect,
                                              zoom: editZoom, pan: editPan)
        guard oldRect.width > 0, oldRect.height > 0 else { return }
        let u = (old.width / 2 - oldRect.minX) / oldRect.width
        let v = (old.height / 2 - oldRect.minY) / oldRect.height
        editPan = EditCanvasMath.panForCenteredContent(u: u, v: v, zoom: editZoom,
                                                       container: newSize,
                                                       imageAspect: canvasImageAspect)
    }

    func resetCanvasViewport() {
        guard tool != .crop else { return }
        editZoom = 1
        editPan = .zero
    }

    /// 状态栏下拉的动作:适配窗口 / 倍率预设(相对适应窗口,居中)
    func applyEditZoomAction(_ action: ZoomAction) {
        guard tool != .crop, displayPreview != nil else { return }
        switch action {
        case .fit, .actualSize:
            resetCanvasViewport()
        case .scale(let factor):
            editZoom = EditCanvasMath.clampedZoom(factor)
            editPan = .zero
        case .zoomIn:
            stepCanvasZoom(1.25)
        case .zoomOut:
            stepCanvasZoom(1 / 1.25)
        }
    }

    // MARK: 文字角柄改字号

    func handleTextResizeStart(at point: CGPoint) {
        guard let id = selectedID,
              case let .text(anchor, _, fraction, _, _) = annotations.first(where: { $0.id == id })?.kind
        else { return }
        textResizing = true
        resizeStartFraction = MarkPalette.clampTextFraction(fraction)
        resizeStartDistance = max(0.02, hypot(point.x - anchor.x, point.y - anchor.y))
        moveUndoPushed = false
    }

    func handleTextResizeChange(at point: CGPoint) {
        guard textResizing, let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case let .text(anchor, content, _, colorIdx, hasBackground) = annotations[index].kind else { return }
        let dist = max(0.02, hypot(point.x - anchor.x, point.y - anchor.y))
        let fraction = MarkPalette.clampTextFraction(resizeStartFraction * dist / resizeStartDistance)
        if case let .text(_, _, current, _, _) = annotations[index].kind, current == fraction { return }
        pushUndoForMoveIfFirst()
        annotations[index].kind = .text(anchor: anchor, content: content,
                                        sizeFraction: fraction, color: colorIdx,
                                        hasBackground: hasBackground)
    }

    func handleTextResizeEnd() {
        textResizing = false
    }

    func handleShapeResizeStart(_ handle: ShapeHandle, at point: CGPoint) {
        guard let id = selectedID,
              case let .shape(_, from, to, _, _, _) = annotations.first(where: { $0.id == id })?.kind
        else { return }
        shapeResizing = handle
        reshapeStartFrom = from
        reshapeStartTo = to
        selectingExisting = true
        moveUndoPushed = false
    }

    func handleShapeResizeChange(at point: CGPoint, lockAspect: Bool) {
        guard let handle = shapeResizing, let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case let .shape(kind, from, to, widthLevel, colorIdx, filled) = annotations[index].kind
        else { return }
        let next = MarkupGeometry.reshaped(
            kind: kind, from: reshapeStartFrom, to: reshapeStartTo,
            handle: handle, to: point, lockAspect: lockAspect
        )
        if next.from == from, next.to == to { return }
        pushUndoForMoveIfFirst()
        annotations[index].kind = .shape(kind: kind, from: next.from, to: next.to,
                                         widthLevel: widthLevel, color: colorIdx, filled: filled)
    }

    func handleShapeResizeEnd() {
        shapeResizing = nil
    }

    /// 裁切画布(CropCanvas)不接 zoom/pan,它的 fit 只按容器算。
    /// 这里不设门禁的话,⌘= / ⌘− 会改掉 editZoom 与状态栏百分比,画布却纹丝不动,
    /// 等你切回标记工具才「突然」缩放——同批其它入口都有这个 guard。
    func stepCanvasZoom(_ factor: CGFloat) {
        guard tool != .crop, canvasContainerSize.width > 0 else { return }
        applyCanvasZoom(factor: factor,
                        anchor: CGPoint(x: canvasContainerSize.width / 2,
                                        y: canvasContainerSize.height / 2),
                        container: canvasContainerSize)
    }

    func snapToRatio() {
        guard let aspect = lockAspect, transformedPixelSize.width > 0 else { return }
        // 与拖动同一处换算:比例预设是像素空间的,选区是归一化坐标
        let imageAspect = transformedPixelSize.width / max(1, transformedPixelSize.height)
        let ratio = CropMath.normalizedAspect(aspect, imageAspect: imageAspect)

        // 以「固定合适大小」为准,而不是在当前选区内接新比例 —— 旧逻辑以选区为基准,
        // 选区形状是上一个比例的,每切一次就被新比例裁小一圈,越切越小。
        // 这里固定取画布 84%(与右键「重置选框」同一尺度),比例适配后居中放置。
        let scale: CGFloat = 0.84
        var width = scale
        var height = width / ratio
        if height > scale {
            height = scale
            width = height * ratio
        }
        let x = 0.5 - width / 2
        let y = 0.5 - height / 2
        mutateSelection(CropMath.clampedNormalized(CGRect(x: x, y: y, width: width, height: height), minSize: 0.05))
    }

    /// 有会话就整段恢复(标记 + 裁切 + 旋转);没有则只用浏览模式带进来的旋转。
}
