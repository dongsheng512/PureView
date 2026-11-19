import AppKit
import QuartzCore

extension ImageViewCanvas.Coordinator {

    // MARK: 布局与缩放

    var imageSize: CGSize {
        imageView.image?.size ?? .zero
    }

    func handleLayout() {
        guard !mutatingCanvas, imageView.image != nil else { return }
        // 捏合手势进行中(bounds 尺寸被 magnification 改变),不干预布局
        guard abs(scrollView.magnification - 1) < 0.001 else { return }
        let newFit = fitScaleValue()
        guard abs(newFit - fitScale) > 0.001 else { return }
        debugLog("handleLayout fitChange \(fitScale) -> \(newFit) wasFit=\(wasFit)")
        fitScale = newFit
        if wasFit {
            applyFit()
            // 窗口拉大或进全屏后,原来那张降采样位图会发虚,停稳后再升到够用的像素
            scheduleEscalateCheck()
        } else if scale < minScale {
            applyScale(minScale, anchor: visibleCenter())
        }
    }

    /// 换屏 / 改缩放。适配模式按新视口重铺并升像素;已缩放则保持同一「实际大小」百分比。
    func handleDisplayChange() {
        guard imageView.image != nil, abs(scrollView.magnification - 1) < 0.001 else { return }
        let backing = scrollView.window?.backingScaleFactor ?? 2
        if !wasFit, lastBacking > 0, abs(backing - lastBacking) > 0.01, truePixelSize.width > 0 {
            let kept = imageView.frame.width * lastBacking * scrollView.magnification / truePixelSize.width
            lastBacking = backing
            applyEffectiveScale(kept, backing: backing, animated: false)
        } else {
            lastBacking = backing
            if wasFit { applyFit() }
        }
        scheduleEscalateCheck()
    }

    func fitScaleValue() -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let clip = clipView.bounds.size
        guard clip.width > 0, clip.height > 0 else { return 1 }
        return min(clip.width / imageSize.width, clip.height / imageSize.height)
    }

    func applyFit() {
        // 防御:任何残留的手势缩放都会叠加在适配结果上,先归一
        if abs(scrollView.magnification - 1) > 0.0005 { scrollView.magnification = 1 }
        fitScale = fitScaleValue()
        scale = fitScale
        wasFit = true
        updateFrameCentered()
        notifyScale()
    }

    /// 切图时按偏好套用默认缩放(瞬时,不走平滑动画)
    func applyOpenZoom() {
        switch parent.openZoomMode {
        case .fit:
            applyFit()
        case .actualSize:
            applyActualSizeImmediate()
        }
    }

    func applyActualSizeImmediate() {
        if abs(scrollView.magnification - 1) > 0.0005 { scrollView.magnification = 1 }
        fitScale = fitScaleValue()
        let backing = scrollView.window?.backingScaleFactor ?? 2
        applyEffectiveScale(1, backing: backing, animated: false)
        notifyScale()
        scheduleEscalateCheck()
    }

    /// 按「源像素 : 屏幕物理像素」的倍数缩放(1.0 = 实际大小),与状态栏读数同语义。
    /// 必须换算回当前位图的坐标系:浏览位图是降采样过的,直接拿 1/backing 当 scale
    /// 会让 100% 只到 (降采样上限 / 原图尺寸)——4000px 的图在 2x 屏上只有 70%。
    func applyEffectiveScale(_ factor: CGFloat, backing: CGFloat, animated: Bool) {
        guard imageSize.width > 0, truePixelSize.width > 0 else { return }
        let target = max(factor * truePixelSize.width / backing / imageSize.width, minScale)
        wasFit = false
        if animated {
            startSmoothZoom(to: target, anchor: visibleCenter(), duration: 0.22)
        } else {
            // 走 updateFrameCentered 而不是 applyScale:后者在 target == scale 时会提前返回,
            // 换图后若新旧缩放比恰好相同就会漏掉这次 frame 更新。
            scale = target
            updateFrameCentered()
        }
    }

    func updateFrameCentered() {
        guard imageSize.width > 0 else { return }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = ZoomMath.constrainedOrigin(
            proposed: .zero,
            docSize: size,
            clipSize: clipView.bounds.size
        )
        commitCanvasChange {
            applyDocument(size: size, origin: origin, snap: true)
        }
    }

    func performZoom(_ action: ZoomAction) {
        debugLog("performZoom \(action) begin")
        guard imageView.image != nil else { return }
        defer { lateCheck("afterZoom\(action == .fit ? "Fit" : action == .actualSize ? "Actual" : action == .zoomIn ? "In" : "Out")") }
        switch action {
        case .fit:
            absorbMagnification()
            startSmoothZoom(to: fitScaleValue(), anchor: visibleCenter(),
                            duration: 0.22, completesAsFit: true)
        case .actualSize:
            absorbMagnification()
            if isFullResolution {
                setAbsoluteActualSize()
            } else {
                escalate { [weak self] in
                    self?.setAbsoluteActualSize()
                }
            }
        case .zoomIn:
            absorbMagnification()
            smoothZoom(multiplyingBy: 1.25, anchor: visibleCenter(), duration: 0.22)
        case .zoomOut:
            absorbMagnification()
            smoothZoom(multiplyingBy: 0.8, anchor: visibleCenter(), duration: 0.22)
        case .scale(let factor):
            absorbMagnification()
            let backing = scrollView.window?.backingScaleFactor ?? 2
            applyEffectiveScale(factor, backing: backing, animated: true)
        }
    }

    /// 可视区域中心(clip 视图本地坐标)
    func visibleCenter() -> CGPoint {
        CGPoint(x: clipView.bounds.width / 2, y: clipView.bounds.height / 2)
    }

    /// 缩放下限:允许缩小到适配档的 1/10(小图在"适配"时是放大态,也允许继续缩小)
    var minScale: CGFloat {
        min(fitScale, 1) * 0.1
    }

    /// 实际大小:1 图像像素 = 1 屏幕物理像素
    func setAbsoluteActualSize() {
        let backing = scrollView.window?.backingScaleFactor ?? 2
        startSmoothZoom(to: 1 / backing, anchor: visibleCenter(), duration: 0.22)
    }

    func toggleZoom(at location: CGPoint) {
        guard imageView.image != nil else { return }
        let backing = scrollView.window?.backingScaleFactor ?? 2
        let effective = effectiveScale(backing: backing)
        if wasFit || effective < 0.35 {
            performZoom(.actualSize)
        } else {
            applyFit()
        }
    }

    // MARK: 平滑缩放(显示链路按时长缓出)

    /// 滚轮 / 按钮 / 捏合:目标倍率累积,按剩余时长缓出,连点是一次连贯运动。
    func smoothZoom(multiplyingBy factor: CGFloat, anchor: CGPoint?, duration: CFTimeInterval) {
        guard imageView.image != nil else { return }
        wasFit = false
        let b = clipView.bounds
        var pt = anchor ?? visibleCenter()
        // 锚点是 clip 本地坐标(0..size)。夹取必须按尺寸,不能用 bounds.minX/maxX——
        // 那是文档坐标(含滚动 origin),深缩放时 origin 超过锚点后会把锚点
        // 强行抬到 origin 上,缩放就围绕视口角落转,画面整体向右上漂移。
        pt.x = min(max(pt.x, 0), b.width)
        pt.y = min(max(pt.y, 0), b.height)
        let base = zoomTarget ?? scale
        startSmoothZoom(to: base * factor, anchor: pt, duration: duration)
    }

    func startSmoothZoom(to targetRaw: CGFloat, anchor: CGPoint,
                                 duration: CFTimeInterval, completesAsFit: Bool = false) {
        let target = min(max(targetRaw, minScale), 64)
        guard abs(target - scale) > 0.0005 else {
            if completesAsFit { applyFit() }
            cancelSmoothZoom()
            return
        }
        zoomAnchorPoint = anchor
        zoomTarget = target
        zoomStart = scale
        zoomDuration = max(duration, 0.04)
        zoomStartTime = CACurrentMediaTime()
        zoomCompletesAsFit = completesAsFit
        wasFit = false
        startZoomLinkIfNeeded()
    }

    func startZoomLinkIfNeeded() {
        guard zoomLink == nil else { return }
        let proxy = ZoomTickProxy()
        proxy.coordinator = self
        let link = imageView.displayLink(target: proxy,
                                         selector: #selector(ZoomTickProxy.tick(_:)))
        proxy.link = link
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        zoomLink = link
    }

    func cancelSmoothZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
        zoomTarget = nil
        zoomCompletesAsFit = false
    }

    func zoomTick() {
        guard imageView.image != nil, let target = zoomTarget else {
            cancelSmoothZoom()
            return
        }
        let t = min(1, (CACurrentMediaTime() - zoomStartTime) / zoomDuration)
        // ease-out cubic: 起手干脆,收尾不硬切
        let eased = 1 - pow(1 - t, 3)
        let next = zoomStart + (target - zoomStart) * CGFloat(eased)
        if t >= 1 {
            let asFit = zoomCompletesAsFit
            applyScale(target, anchor: zoomAnchorPoint, settling: true)
            cancelSmoothZoom()
            if asFit { wasFit = true }
            // 动画收尾:执行等待中的全尺寸换图(等尺寸、中心保持,视觉无感)
            if let apply = pendingEscalateApply {
                pendingEscalateApply = nil
                apply()
            }
        } else {
            applyScale(next, anchor: zoomAnchorPoint, settling: false)
        }
    }

    /// 弱引用代理:NSView.displayLink 强持有 target,直接传 self 会形成保留环
    @MainActor
    final class ZoomTickProxy: NSObject {
        weak var coordinator: ImageViewCanvas.Coordinator?
        weak var link: CADisplayLink?
        var lastTick: CFTimeInterval = 0
        @objc func tick(_ sender: CADisplayLink) {
            guard let coordinator else {
                link?.invalidate()
                return
            }
            // 临时性能测量:--zoom-debug 下打印帧间隔,定位卡顿
            if coordinator.zoomDebug {
                let now = CACurrentMediaTime()
                if lastTick > 0 {
                    let delta = (now - lastTick) * 1000
                    if delta > 25 {   // 正常 60-120fps 是 8-17ms,超过 25ms 记为掉帧
                        FileHandle.standardError.write(Data("[perf] tick gap \(Int(delta))ms\n".utf8))
                    }
                }
                lastTick = now
            }
            coordinator.zoomTick()
        }
    }

    func commitCanvasChange(_ body: () -> Void) {
        mutatingCanvas = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        clipView.pinnedOrigin = nil
        mutatingCanvas = false
    }

    /// 写入文档尺寸与取景。动画过程不对齐像素(避免逐帧台阶),停稳后再贴 backing。
    func applyDocument(size: CGSize, origin: NSPoint, snap: Bool) {
        let backing = scrollView.window?.backingScaleFactor ?? 2
        let outSize = snap
            ? CGSize(width: ZoomMath.snapped(size.width, backing: backing),
                     height: ZoomMath.snapped(size.height, backing: backing))
            : size
        let outOrigin = snap ? ZoomMath.snappedPoint(origin, backing: backing) : origin
        clipView.pinnedOrigin = outOrigin
        imageView.frame = NSRect(origin: .zero, size: outSize)
        clipView.setBoundsOrigin(outOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 核心缩放:内容随 frame 伸缩,锚点(本地坐标)指向的内容点保持不动
    func applyScale(_ newScale: CGFloat, anchor: CGPoint,
                            resetMagnification: Bool = false, settling: Bool = true) {
        guard imageView.image != nil, imageSize.width > 0, scale > 0 else { return }
        let clamped = min(max(newScale, minScale), 64)
        guard clamped != scale || resetMagnification else {
            debugLog("applyScale SKIPPED clamped==scale")
            return
        }
        debugLog("applyScale from=\(scale) to=\(clamped) anchor=(\(anchor.x), \(anchor.y))")
        commitCanvasChange {
            if resetMagnification { scrollView.magnification = 1 }
            let oldDoc = imageView.frame.size.width > 0
                ? imageView.frame.size
                : CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let newSize = CGSize(width: imageSize.width * clamped, height: imageSize.height * clamped)
            let ratio = oldDoc.width > 0 ? newSize.width / oldDoc.width : 1
            let zoomAnchor = resetMagnification ? visibleCenter() : anchor
            let anchored = ZoomMath.anchoredOrigin(
                oldOrigin: clipView.bounds.origin,
                anchor: zoomAnchor,
                docSize: oldDoc,
                ratio: ratio
            )
            let origin = ZoomMath.constrainedOrigin(
                proposed: anchored,
                docSize: newSize,
                clipSize: clipView.bounds.size
            )
            applyDocument(size: newSize, origin: origin, snap: settling)
            if settling, imageSize.width > 0 {
                scale = imageView.frame.width / imageSize.width
            } else {
                scale = clamped
            }
        }
        debugLog("applyScale done")
        notifyScale()
        if settling {
            scheduleEscalateCheck()
        }
    }

    /// 百分比语义:每个图像源像素对应多少屏幕物理像素。
    /// 必须除以源图像素(truePixelSize)而不是当前位图——否则升级换图的瞬间
    /// 位图变宽、同一画面读数会腰斩(90%→45%)。DPI 标注的文件按真实像素如实呈现。
    func effectiveScale(backing: CGFloat) -> CGFloat {
        let frameWidth = imageView.frame.width
        if frameWidth > 0, truePixelSize.width > 0 {
            return frameWidth * backing * scrollView.magnification / truePixelSize.width
        }
        return scale * scrollView.magnification
    }

    func notifyScale() {
        let backing = scrollView.window?.backingScaleFactor ?? 2
        let value = effectiveScale(backing: backing)
        let percent = Int((value * 100).rounded())
        guard percent != lastNotifiedPercent else { return }
        lastNotifiedPercent = percent
        debugLog("notify percent=\(percent)% frameW=\(imageView.frame.width) trueW=\(truePixelSize.width)")
        parent.onScaleChange(value)
    }

    /// 等平滑缩放停稳再升级,避免解码完成时叠在动画尾帧上造成一次位移
    func scheduleEscalateCheck() {
        escalateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.maybeEscalate()
        }
        escalateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 缩放后如果当前表示的像素不足以清晰呈现,加载全尺寸替换(视觉尺寸保持不变)
    func maybeEscalate() {
        guard !isFullResolution, !escalating, !isRotatedBitmap, zoomTarget == nil,
              frameCount <= 1,
              let image = imageView.image,
              let rep = image.representations.first, rep.pixelsWide > 0 else { return }
        let backing = scrollView.window?.backingScaleFactor ?? 2
        let displayedPx = imageView.frame.width * backing
        // 基准是「当前位图的真实像素」,不是源图像素。
        // 浏览位图是降采样过的,拿源图尺寸当基准会让 100% 缩放时仍停在插值画质:
        // 4000px 的图以 2800px 位图显示到 4000 设备像素,判定 4000 > 4200 为假,永远不升级。
        // 系数 0.9 让全尺寸在到达 100% 之前就位。
        if displayedPx > CGFloat(rep.pixelsWide) * 0.9 {
            // 已有待执行的换图(等动画结束)时不重复触发
            guard pendingEscalateApply == nil else { return }
            escalate {}
        }
    }

    func escalate(completion: @escaping () -> Void) {
        // 动图跳过:没有更高分辨率可升,解码出来的静态帧会被下一帧动画覆盖
        guard let url = currentURL, !escalating, frameCount <= 1 else {
            completion()
            return
        }
        escalating = true
        Task { [weak self] in
            guard let self else { return }
            let full: NSImage? = await Task.detached(priority: .userInitiated) {
                try? ImageLoader.decode(url: url, maxPixelSize: nil)
            }.value
            defer {
                self.escalating = false
                completion()
            }
            guard !Task.isCancelled, self.currentURL == url, let full,
                  full.size.width > 0 else { return }
            // 缩放动画进行中:推迟到动画结束再换图,手势全程零不连续。
            // (换图本身视觉无感,但叠在手势中途的任何时序误差都会被感知为"漂移")
            if self.zoomTarget != nil {
                self.pendingEscalateApply = { [weak self] in
                    self?.applyEscalatedImage(full, url: url)
                }
            } else {
                self.applyEscalatedImage(full, url: url)
            }
        }
    }

    /// 把解码完成的全尺寸位图换入画布(等尺寸、视口中心保持,视觉无感)。
    /// 调用时机:不在平滑缩放动画中途。
    func applyEscalatedImage(_ full: NSImage, url: URL) {
        guard currentURL == url, !isRotatedBitmap,
              full.size.width > 0 else { return }
        // 以解码完成时的实时视觉尺寸换算:
        // 加载期间用户的缩放/平移不能被解码开始前的快照覆盖(延迟回跳的根源)
        let visual = imageView.frame.size
        let origin = clipView.bounds.origin
        guard visual.width > 0 else { return }
        let newScale = min(max(visual.width / full.size.width, minScale), 64)
        let newSize = CGSize(width: full.size.width * newScale, height: full.size.height * newScale)
        let kept = ZoomMath.originKeepingVisibleCenter(
            oldOrigin: origin,
            oldDoc: visual,
            newDoc: newSize,
            clipSize: clipView.bounds.size
        )
        // scale 的单位是"占 NSImage 点尺寸的比例",位图从降采样换成全尺寸后单位变了。
        // 进行中的平滑缩放(zoomTarget/zoomStart)必须同步换算到新单位,否则动画会
        // 套用旧目标导致画面瞬间跳大/缩放读数闪跳——缩放跨过升级阈值时必现的卡顿。
        let oldBitmapW = bitmapPixelSize.width
        let fullBitmapW = CGFloat(full.representations.first?.pixelsWide ?? Int(full.size.width))
        let unitRatio = oldBitmapW > 0 && fullBitmapW > 0 ? oldBitmapW / fullBitmapW : 1
        commitCanvasChange {
            self.imageView.image = full
            self.bitmapPixelSize = CGSize(
                width: full.representations.first?.pixelsWide ?? Int(full.size.width),
                height: full.representations.first?.pixelsHigh ?? Int(full.size.height)
            )
            self.isFullResolution = true
            self.scale = newScale
            self.applyDocument(size: newSize, origin: kept, snap: true)
            self.fitScale = self.fitScaleValue()
            if self.zoomTarget != nil, unitRatio != 1 {
                self.zoomTarget = self.zoomTarget! * unitRatio
                self.zoomStart *= unitRatio
            }
        }
        notifyScale()
    }

    func pan(by delta: CGSize) {
        guard imageView.image != nil else { return }
        wasFit = false
        let proposed = NSPoint(
            x: clipView.bounds.origin.x - delta.width,
            y: clipView.bounds.origin.y - delta.height
        )
        let origin = ZoomMath.constrainedOrigin(
            proposed: proposed,
            docSize: imageView.frame.size,
            clipSize: clipView.bounds.size
        )
        commitCanvasChange {
            applyDocument(size: imageView.frame.size, origin: origin, snap: true)
        }
    }

    // MARK: 旋转

    /// 顺时针旋转 90°(可叠加):直接旋转位图后替换 image。
    /// 替换后宽高已对调,bitmapPixelSize 同步翻转,缩放读数/升级判定保持正确。
    /// 图片未就绪时返回 false(调用方保留差额,待就绪后重试)。
    @discardableResult
    func performRotate() -> Bool {
        guard imageView.image != nil,
              let cg = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rotated = ImageLoader.rotatedCW90(cg) else { return false }
        cancelSmoothZoom()
        absorbMagnification()
        // 动图每帧会用原始帧重建 NSImage,会覆盖旋转结果;先停播再转(静态呈现当前帧的旋转变体)
        stopAnimation()
        let newImage = NSImage(cgImage: rotated, size: NSSize(width: cg.height, height: cg.width))
        commitCanvasChange {
            self.imageView.image = newImage
            self.bitmapPixelSize = CGSize(width: cg.height, height: cg.width)
            if self.truePixelSize.width > 0, self.truePixelSize.height > 0 {
                self.truePixelSize = CGSize(width: self.truePixelSize.height, height: self.truePixelSize.width)
            }
            self.isRotatedBitmap = true   // 位图已重排:不再升级解码(会覆盖旋转),读数以位图为准
            self.isFullResolution = true
            self.applyFit()
        }
        parent.onRotationChange(true)
        debugLog("performRotate applied")
        return true
    }

    /// 复位临时显示旋转:直接以当前文件重走加载流程(优先命中缓存,几乎瞬时恢复)。
    func resetRotation() {
        guard isRotatedBitmap, let url = currentURL else { return }
        let file = ImageFile(id: url)
        currentURL = nil
        isRotatedBitmap = false
        parent.onRotationChange(false)
        applyFile(file)
    }

}
