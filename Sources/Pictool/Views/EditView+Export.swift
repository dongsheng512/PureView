import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension EditView {

    // MARK: 预览 / 叠层

    var pixelRect: CGRect {
        CropMath.pixelRect(normalized: selection, pixelSize: transformedPixelSize)
    }

    /// 导出前的全尺寸裁切像素宽高(基于原图真实像素而非 1500px 预览图)。
    var fullResCropPixelSize: CGSize {
        let baseSize: CGSize
        if sourceFullPixelSize.width > 0, sourceFullPixelSize.height > 0 {
            baseSize = CropTransform.transformedSize(
                width: Int(sourceFullPixelSize.width),
                height: Int(sourceFullPixelSize.height),
                quarterTurns: quarterTurns
            )
        } else {
            baseSize = transformedPixelSize
        }
        return CropMath.pixelRect(normalized: selection, pixelSize: baseSize).size
    }

    /// 画布水印:只有勾选「启用水印」且有内容时才叠到主图上。
    var liveWatermark: WatermarkSettings {
        guard watermarkDraft.enabled, watermarkDraft.hasContent else { return WatermarkSettings() }
        return watermarkDraft
    }

    var lockAspect: CGFloat? {
        let customAspect: CGFloat? = {
            guard let w = Double(customW), let h = Double(customH), w > 0, h > 0 else { return nil }
            return CGFloat(w / h)
        }()
        let imageAspect = transformedPixelSize.width / max(1, transformedPixelSize.height)
        return ratio.aspect(imageAspect: imageAspect, customAspect: customAspect)
    }

    var overwriteFormat: CropFormat? {
        CropFormat.exactSourceExt(file.url.pathExtension)
    }

    var exportReady: Bool {
        !exporting && displayPreview != nil && !previewFailed
    }

    /// 注意:变换必须同时作用于 **annotations 与 selection**。
    /// 选区是归一化矩形,旋转后画幅宽高对调,只映射标注会让框停在原地——
    /// 用户看到内容转了、框没转,导出裁到的是另一块内容。
    func rotate(cw: Bool) {
        cancelDraft()
        pushUndo()
        // 闭包而非方法引用:三元里混 nil/方法引用会让 Swift 6 语言模式的类型推断失败
        let map: (CGPoint) -> CGPoint = { cw ? MarkupGeometry.rotateCW90($0) : MarkupGeometry.rotateCCW90($0) }
        annotations = annotations.map { MarkupGeometry.mapped($0, map) }
        selection = cw ? MarkupGeometry.mappedRectCW90(selection)
                       : MarkupGeometry.mappedRectCCW90(selection)
        quarterTurns += cw ? 1 : -1
        rebuildTransformedPreview()
    }

    func toggleFlipH() {
        cancelDraft()
        pushUndo()
        annotations = annotations.map { MarkupGeometry.mapped($0, MarkupGeometry.flipH) }
        selection = MarkupGeometry.mappedRectFlipH(selection)
        flipH.toggle()
        rebuildTransformedPreview()
    }

    func toggleFlipV() {
        cancelDraft()
        pushUndo()
        annotations = annotations.map { MarkupGeometry.mapped($0, MarkupGeometry.flipV) }
        selection = MarkupGeometry.mappedRectFlipV(selection)
        flipV.toggle()
        rebuildTransformedPreview()
    }

    func mutateSelection(_ newValue: CGRect) {
        guard newValue != selection else { return }
        pushUndo()
        selection = newValue
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !previewFailed else { return }
        if tool == .crop {
            guard transformedPixelSize.width > 0 else { return }
            var r = selection
            r.origin.x = min(max(0, r.origin.x + dx * 0.005), 1 - r.width)
            r.origin.y = min(max(0, r.origin.y + dy * 0.005), 1 - r.height)
            mutateSelection(r)
            return
        }
        // 标注微调:选中对象按 0.002 步长平移(Shift ×4 由调用方传入)
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let delta = CGSize(width: dx * 0.002, height: dy * 0.002)
        switch annotations[index].kind {
        case let .text(anchor, content, sizeFraction, colorIdx, hasBackground):
            let next = MarkupGeometry.moved(anchor: anchor, by: delta)
            guard next != anchor else { return }
            pushUndo()
            annotations[index].kind = .text(anchor: next, content: content,
                                            sizeFraction: sizeFraction, color: colorIdx,
                                            hasBackground: hasBackground)
        case let .step(anchor, number, sizeFraction, colorIdx):
            let next = MarkupGeometry.moved(anchor: anchor, by: delta)
            guard next != anchor else { return }
            pushUndo()
            annotations[index].kind = .step(anchor: next, number: number,
                                            sizeFraction: sizeFraction, color: colorIdx)
        case let .stroke(points, widthLevel, colorIdx, style):
            let next = MarkupGeometry.clampedTranslate(points: points, dx: delta.width, dy: delta.height)
            guard next != points else { return }
            pushUndo()
            annotations[index].kind = .stroke(points: next, widthLevel: widthLevel,
                                              color: colorIdx, style: style)
        case let .mosaic(points, widthLevel, effect):
            let next = MarkupGeometry.clampedTranslate(points: points, dx: delta.width, dy: delta.height)
            guard next != points else { return }
            pushUndo()
            annotations[index].kind = .mosaic(points: next, widthLevel: widthLevel, effect: effect)
        case let .mosaicRect(from, to, widthLevel, effect):
            let next = MarkupGeometry.clampedTranslate(points: [from, to], dx: delta.width, dy: delta.height)
            guard next[0] != from || next[1] != to else { return }
            pushUndo()
            annotations[index].kind = .mosaicRect(from: next[0], to: next[1],
                                                  widthLevel: widthLevel, effect: effect)
        case let .shape(kind, from, to, widthLevel, colorIdx, filled):
            let next = MarkupGeometry.clampedTranslate(points: [from, to], dx: delta.width, dy: delta.height)
            guard next[0] != from || next[1] != to else { return }
            pushUndo()
            annotations[index].kind = .shape(kind: kind, from: next[0], to: next[1],
                                             widthLevel: widthLevel, color: colorIdx, filled: filled)
        }
    }


    func restoreSession() {
        guard annotationStore.hasSession(for: file.url) else {
            quarterTurns = ((initialQuarterTurns % 4) + 4) % 4
            return
        }
        let saved = annotationStore.session(for: file.url)
        annotations = saved.annotations
        selection = saved.selection
        quarterTurns = saved.quarterTurns
        flipH = saved.flipH
        flipV = saved.flipV
        straighten = saved.straighten
        adjustments = saved.adjustments
    }

    func persistSession() {
        annotationStore.setSession(EditSession(
            annotations: annotations,
            selection: selection,
            quarterTurns: quarterTurns,
            flipH: flipH,
            flipV: flipV,
            straighten: straighten,
            adjustments: adjustments
        ), for: file.url)
    }

    func loadPreview() {
        let url = file.url
        format = CropFormat.default(forSourceExt: url.pathExtension)
        Task {
            let decoded: (image: NSImage, facts: ImageLoader.SourceFacts)? =
                await Task.detached(priority: .userInitiated) {
                    try? ImageLoader.decodeWithFacts(url: url, maxPixelSize: 1500)
                }.value
            if let decoded, decoded.facts.pixelWidth > 0, decoded.facts.pixelHeight > 0 {
                sourceFullPixelSize = CGSize(width: decoded.facts.pixelWidth, height: decoded.facts.pixelHeight)
            }
            basePreview = decoded?.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            previewFailed = basePreview == nil
            rebuildTransformedPreview()
        }
    }

    func rebuildTransformedPreview(finishStraightening: Bool = false) {
        guard let base = basePreview else { return }
        previewGeneration += 1
        let gen = previewGeneration
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten, adj = adjustments
        Task {
            let result: (preGeo: CGImage, preAdj: CGImage, geo: CGImage, final: CGImage) =
                await Task.detached(priority: .userInitiated) {
                    let preGeo = CropTransform.apply(
                        to: base, quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: 0
                    )
                    let preAdj = ImageAdjustmentService.apply(adj, to: preGeo)
                    let geo = abs(deg) > 0.0001
                        ? CropTransform.apply(to: preGeo, quarterTurns: 0, flipH: false, flipV: false,
                                              straightenDegrees: deg)
                        : preGeo
                    let final = abs(deg) > 0.0001
                        ? ImageAdjustmentService.apply(adj, to: geo)
                        : preAdj
                    return (preGeo, preAdj, geo, final)
                }.value
            guard gen == previewGeneration else { return }
            unstraightenedCG = result.preGeo
            unstraightenedPreview = NSImage(
                cgImage: result.preAdj,
                size: NSSize(width: result.preAdj.width, height: result.preAdj.height)
            )
            transformedCG = result.geo
            originalPreview = NSImage(
                cgImage: result.geo,
                size: NSSize(width: result.geo.width, height: result.geo.height)
            )
            displayCG = result.final
            displayPreview = NSImage(
                cgImage: result.final,
                size: NSSize(width: result.final.width, height: result.final.height)
            )
            transformedPixelSize = CGSize(width: result.final.width, height: result.final.height)
            if finishStraightening { isStraightening = false }
            rebuildOverlay()
        }
    }

    /// 调色滑块实时预览:仅在已几何变换的预览图上跑 GPU CoreImage 滤镜，无需重算几何。
    func scheduleAdjustedPreview() {
        guard transformedCG != nil else { return }
        adjustRebuildTask?.cancel()
        adjustRebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            rebuildAdjustedPreview()
        }
    }

    func rebuildAdjustedPreview() {
        guard let geo = transformedCG else { return }
        let preGeo = unstraightenedCG
        adjustGeneration += 1
        let gen = adjustGeneration
        let adj = adjustments
        let hasMosaic = annotations.contains {
            if case .mosaic = $0.kind { return true }
            if case .mosaicRect = $0.kind { return true }
            return false
        }
        Task {
            let result: (final: CGImage, preAdj: CGImage?) = await Task.detached(priority: .userInitiated) {
                let final = ImageAdjustmentService.apply(adj, to: geo)
                let preAdj = preGeo.map { ImageAdjustmentService.apply(adj, to: $0) }
                return (final, preAdj)
            }.value
            guard gen == adjustGeneration else { return }
            displayCG = result.final
            displayPreview = NSImage(
                cgImage: result.final,
                size: NSSize(width: result.final.width, height: result.final.height)
            )
            if let preAdj = result.preAdj {
                unstraightenedPreview = NSImage(
                    cgImage: preAdj,
                    size: NSSize(width: preAdj.width, height: preAdj.height)
                )
            }
            if hasMosaic { scheduleOverlayRebuild() }
        }
    }

    func overlayAnnotations() -> [Annotation] {
        var result = annotations
        if let editing = draftEditingID {
            result.removeAll { $0.id == editing }
        }
        if tool == .mosaic, livePoints.count >= 1 {
            result.append(Annotation(kind: .mosaic(
                points: livePoints, widthLevel: sizeLevel, effect: mosaicEffect
            )))
        }
        if tool == .mosaic, mosaicMode == .rect,
           let from = dragStartPoint, let to = liveShapeTo {
            result.append(Annotation(kind: .mosaicRect(
                from: from, to: to, widthLevel: sizeLevel, effect: mosaicEffect
            )))
        }
        return result
    }

    /// 时间门槛节流 + 尾帧补齐:拖拽中的高频标注变化 ≥30ms 才全幅重绘一次,松手后的最终帧必达
    func scheduleOverlayRebuild() {
        let now = Date()
        guard now.timeIntervalSince(lastMosaicRebuild) >= 0.03 else {
            overlayRebuildTask?.cancel()
            overlayRebuildTask = Task {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                lastMosaicRebuild = Date()
                rebuildOverlay()
            }
            return
        }
        lastMosaicRebuild = now
        rebuildOverlay()
    }

    func rebuildOverlay() {
        guard let base = displayCG else { return }
        overlayGeneration += 1
        let gen = overlayGeneration
        let anns = overlayAnnotations()
        let size = CGSize(width: base.width, height: base.height)
        Task {
            let img: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let ctx = CGContext(
                    data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                AnnotationRenderer.draw(anns, in: ctx, canvasSize: size, base: base)
                return ctx.makeImage()
            }.value
            guard gen == overlayGeneration else { return }
            if let img {
                overlayImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            } else {
                overlayImage = nil
            }
        }
    }

    // MARK: 导出体积预估

    func scheduleExportSizeEstimate() {
        exportEstimateTask?.cancel()
        guard let preview = displayCG else {
            estimatedExportSize = nil
            return
        }
        let fmt = format
        let q = quality
        let rect = selection
        let customPx = Int(exportCustomLongestSide.trimmingCharacters(in: .whitespaces)) ?? 0
        let targetSize = exportResize.outputPixelSize(
            sourcePixelSize: fullResCropPixelSize,
            customPixels: customPx
        )
        exportEstimateTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .utility) {
                CropService.estimateEncodedSize(
                    preview: preview, normalizedRect: rect,
                    targetPixelSize: targetSize, format: fmt, quality: q
                )
            }.value
            guard !Task.isCancelled else { return }
            if let bytes {
                estimatedExportSize = ByteCountFormatter.string(
                    fromByteCount: Int64(bytes), countStyle: .file
                )
            } else {
                estimatedExportSize = nil
            }
        }
    }

    // MARK: 导出

    func export(overwrite: Bool) {
        guard !exporting, displayPreview != nil, !previewFailed else { return }
        if draftAnchor != nil { commitDraft() }
        let fmt = overwrite ? (overwriteFormat ?? format) : format
        if overwrite {
            let confirm = NSAlert()
            confirm.messageText = "要覆盖原文件吗?"
            confirm.informativeText = annotations.isEmpty
                ? "“\(file.name)”将被编辑结果替换,原像素不可恢复。"
                : "“\(file.name)”将被裁切与标记结果替换,原像素不可恢复。"
            confirm.alertStyle = .warning
            let overwriteButton = confirm.addButton(withTitle: "覆盖原图")
            overwriteButton.hasDestructiveAction = true
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        var destURL: URL?
        if !overwrite {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(fmt.uti) ?? .png]
            let stem = file.url.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(stem)-编辑.\(fmt.fileExtension)"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            destURL = dest
        }

        exporting = true
        let url = file.url
        let anns = annotations
        let outFormat = overwrite ? fmt : format
        let q = quality
        let gps = includeGPS
        let strip = overwrite ? false : stripMetadata
        let customPx = Int(exportCustomLongestSide.trimmingCharacters(in: .whitespaces)) ?? 0
        let maxSide: Int? = overwrite
            ? nil
            : exportResize.maxLongestSide(sourcePixelSize: fullResCropPixelSize, customPixels: customPx)
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        let adj = adjustments
        let rect = selection
        let mark = watermarkDraft
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                Result {
                    try CropService.encode(
                        sourceURL: url, normalizedRect: rect, format: outFormat, quality: q,
                        quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: deg,
                        adjustments: adj,
                        maxLongestSide: maxSide, includeGPS: gps, stripMetadata: strip,
                        annotations: anns, watermark: mark
                    )
                }
            }.value
            exporting = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let data):
                await MainActor.run { save(data: data, overwrite: overwrite, format: outFormat, dest: destURL) }
            }
        }
    }

    /// 打印「当前编辑结果」。
    ///
    /// 与 ⌘P 的区别:⌘P 走的是 `PrintService.print(image:)` + 磁盘原图,不经过编辑器;
    /// 这里先把当前编辑态(变换 → 烙印标注 → 裁切 → 水印)渲染成位图再交给同一个打印服务,
    /// 因此打印出来的和导出所见一致。管线与导出**完全共用** `CropService.render`,
    /// 只打印不落盘,所以不需要选格式/质量/路径。
    func printEdited() {
        guard !exporting, !printPreparing, displayPreview != nil, !previewFailed else { return }
        if draftAnchor != nil { commitDraft() }

        printPreparing = true
        printGeneration += 1
        let generation = printGeneration
        let url = file.url
        let anns = annotations
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        let adj = adjustments
        let rect = selection
        let mark = watermarkDraft
        let paper = NSPrintInfo.shared.paperSize
        let decodeCap = PrintPageView.decodeMaxPixel(paperSize: paper, normalizedRect: rect)
        let outputCap = Int(PrintPageView.printMaxPixel(paperSize: paper).rounded())
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                Result {
                    try CropService.render(
                        sourceURL: url, normalizedRect: rect,
                        quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: deg,
                        adjustments: adj,
                        maxLongestSide: outputCap,
                        maxDecodePixel: decodeCap,
                        annotations: anns, watermark: mark
                    )
                }
            }.value
            guard generation == printGeneration else { return }
            printPreparing = false
            switch result {
            case .failure(let error):
                printError = error.localizedDescription
            case .success(let cg):
                PrintService.print(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
    }

    @MainActor
    func save(data: Data, overwrite: Bool, format: CropFormat, dest: URL?) {
        if overwrite {
            do {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(format.fileExtension)
                try data.write(to: temp, options: .atomic)
                if try FileManager.default.replaceItemAt(file.url, withItemAt: temp) == nil {
                    errorMessage = "替换原文件失败"
                    return
                }
                // 覆盖原图成功后清除编辑会话与画布/缩略图缓存，避免再次编辑双重叠加或回到浏览态看到旧图
                annotations = []
                selection = CGRect(x: 0, y: 0, width: 1, height: 1)
                quarterTurns = 0
                flipH = false
                flipV = false
                straighten = 0
                adjustments = ImageAdjustments()
                annotationStore.setSession(EditSession(), for: file.url)
                store.didOverwriteImage(file.url)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard let dest else { return }
        do {
            try data.write(to: dest, options: .atomic)
            showExportNotice(dest.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 复制「当前编辑结果」到系统剪贴板(无需落盘,直接粘贴到微信/飞书/文档)。
    func copyEditedToPasteboard() {
        guard !exporting, displayPreview != nil, !previewFailed else { return }
        if draftAnchor != nil { commitDraft() }
        exporting = true
        let url = file.url
        let anns = annotations
        let turns = quarterTurns, fh = flipH, fv = flipV, deg = straighten
        let adj = adjustments
        let rect = selection
        let mark = watermarkDraft
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                Result {
                    try CropService.render(
                        sourceURL: url, normalizedRect: rect,
                        quarterTurns: turns, flipH: fh, flipV: fv, straightenDegrees: deg,
                        adjustments: adj,
                        maxLongestSide: nil,
                        annotations: anns, watermark: mark
                    )
                }
            }.value
            exporting = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let cg):
                let rep = NSBitmapImageRep(cgImage: cg)
                let pngData = rep.representation(using: .png, properties: [:])
                let tiffData = rep.tiffRepresentation
                let pb = NSPasteboard.general
                pb.clearContents()
                var types: [NSPasteboard.PasteboardType] = []
                if pngData != nil { types.append(.png) }
                if tiffData != nil { types.append(.tiff) }
                pb.declareTypes(types, owner: nil)
                if let pngData { pb.setData(pngData, forType: .png) }
                if let tiffData { pb.setData(tiffData, forType: .tiff) }
                showStatusNotice("已复制编辑结果到剪贴板")
            }
        }
    }

    func showExportNotice(_ name: String) {
        showStatusNotice("已存储 \(name)")
    }

    func showStatusNotice(_ message: String) {
        exportNoticeToken += 1
        let token = exportNoticeToken
        exportNotice = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard exportNoticeToken == token else { return }
            exportNotice = nil
        }
    }
}
