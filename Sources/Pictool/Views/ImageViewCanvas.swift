import SwiftUI
import AppKit
import ImageIO

/// 主视图画布:NSScrollView + NSImageView(AppKit 混合核心点)。
/// 触控板捏合 / ⌘ 或 ⌥ + 滚轮缩放(以光标为锚点),拖拽平移,双击切换 适配/实际大小。
/// 浏览时按窗口 2 倍降采样解码;放大越过阈值自动加载全尺寸替换(视觉无缝)。
struct ImageViewCanvas: NSViewRepresentable {

    let file: ImageFile?
    /// 当前可见图片序列,供原生 NSPageController 建立分页条。
    var files: [ImageFile] = []
    /// 当前图前后邻居,供预解码使用。
    var neighbors: ImageNeighbors
    /// 画布背景(来自偏好设置),切图与切换偏好时实时生效
    let background: CanvasBackground
    /// 打开新图时的默认缩放
    let openZoomMode: OpenZoomMode
    /// 切图过渡。设置里改完,下一次切图生效。
    let transition: ImageTransitionStyle
    let zoomRequest: (action: ZoomAction, token: Int)?
    /// 当前图累计旋转次数(每格 90°)。画布按「次数 - 已应用」补差值,
    /// 新建的画布实例(纯净模式切换)能重放完整角度。
    let rotationCount: Int
    /// 切图方向信号:+1 下一张,-1 上一张,0 无方向
    let stepDirection: Int
    var onLoadingChange: (Bool) -> Void
    var onScaleChange: (CGFloat) -> Void
    var onImageInfo: (DisplayImageInfo) -> Void
    /// 当前显示位图是否已被用户旋转。旋转是纯显示态,切图即丢,需要让界面如实告知。
    var onRotationChange: (Bool) -> Void
    var onSelect: (ImageFile.ID) -> Void = { _ in }
    var onStep: (Int) -> ImageNeighbors

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.containerView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyBackground(background)
        coordinator.syncPageController(files: files, currentFile: file)
        coordinator.applyFile(file)
        if let request = zoomRequest, request.token != coordinator.appliedZoomToken {
            coordinator.appliedZoomToken = request.token
            coordinator.performZoom(request.action)
        }
        // 补齐旋转差值:新建画布(纯净模式切换)从 0 起,能把累计角度完整重放。
        // 图片尚未就绪时 performRotate 会跳过,差额留在 appliedRotationCount 上,
        // 待图片就绪触发的下一次 UI 更新再补。
        let pendingRotations = rotationCount - coordinator.appliedRotationCount
        if pendingRotations > 0 {
            var applied = 0
            for _ in 0..<pendingRotations {
                guard coordinator.performRotate() else { break }
                applied += 1
            }
            coordinator.appliedRotationCount += applied
        } else if pendingRotations < 0 {
            coordinator.appliedRotationCount = rotationCount
            if rotationCount == 0, coordinator.isRotatedBitmap {
                coordinator.resetRotation()
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSPageControllerDelegate {

        var parent: ImageViewCanvas
        let containerView = CanvasContainerView()
        let pageController = NSPageController()
        let scrollView = CanvasScrollView()
        let clipView = CanvasClipView()
        let imageView = CanvasImageView()

        var currentURL: URL?
        var loadTask: Task<Void, Never>?
        var animationTask: Task<Void, Never>?
        var appliedZoomToken = 0
        var appliedRotationCount = 0
        let zoomDebug = ProcessInfo.processInfo.arguments.contains("--zoom-debug")

        /// --zoom-debug 时同步落一份到固定文件,便于从 Finder 启动的实例抓日志
        static let debugLogFile: FileHandle? = {
            guard ProcessInfo.processInfo.arguments.contains("--zoom-debug") else { return nil }
            let path = "/tmp/pictool_zoom.log"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            return FileHandle(forWritingAtPath: path)
        }()

        func debugLog(_ tag: String) {
            guard zoomDebug else { return }
            let b = clipView.bounds
            let line = "[zoom] \(tag) scale=\(scale) fitScale=\(fitScale) wasFit=\(wasFit) origin=(\(b.origin.x), \(b.origin.y)) frame=\(imageView.frame) clip=(\(b.width), \(b.height)) mag=\(scrollView.magnification)"
            print(line)
            fflush(stdout)
            if let fh = Self.debugLogFile {
                fh.write(Data((line + "\n").utf8))
            }
        }

        /// 延迟复查:捕获"事后被改回"的延迟性回退
        func lateCheck(_ tag: String, after: TimeInterval = 0.6) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                self?.debugLog("LATE[\(tag)]")
            }
        }

        var scale: CGFloat = 1          // 点 / 图像点(以当前 NSImage.size 为准)
        var fitScale: CGFloat = 1
        var wasFit = true
        var isFullResolution = false
        /// 解码完成但缩放动画未结束的换图操作,动画收尾时执行
        var pendingEscalateApply: (() -> Void)?
        /// 当前图的帧数;动图不参与全尺寸升级(没有更高分辨率,升级只会打断播放)
        var frameCount = 1
        var escalating = false
        var truePixelSize = CGSize.zero
        /// 当前 imageView 位图的真实像素(旋转后宽高对调;动图帧始终等于 truePixelSize)。
        /// 缩放读数与升级解码判定的统一几何基准。
        var bitmapPixelSize = CGSize.zero
        /// 位图已被用户旋转过(此时不再从降采样缓存升级,避免旋转被覆盖)
        var isRotatedBitmap = false
        var mutatingCanvas = false
        var lastNotifiedPercent = Int.min
        /// 原生 NSPageController 当前绑定的图片 URL 列表
        var arrangedURLs: [URL] = []
        /// 是否正处于 NSPageController 实时双指过渡或程序动画中
        var isLivePaging = false
        /// 程序触发 NSPageController 动画代数(防连按旧回调提前显示 scrollView)
        var pageAnimationGeneration = 0
        var lastFileSwitchTime: TimeInterval = 0
        /// deinit 是 nonisolated 的,Swift 6 不允许它访问非 Sendable 的实例状态。
        /// `DispatchWorkItem.cancel()` 本身线程安全,这里显式标注豁免即可。
        nonisolated(unsafe) var escalateWork: DispatchWorkItem?

        // 平滑缩放状态(由 ImageViewCanvas+Zoom.swift 驱动)
        var zoomLink: CADisplayLink?
        var zoomTarget: CGFloat?
        var zoomStart: CGFloat = 1
        var zoomStartTime: CFTimeInterval = 0
        var zoomDuration: CFTimeInterval = 0.22
        var zoomAnchorPoint: CGPoint = .zero
        var zoomCompletesAsFit = false
        /// 上次用来解释「实际大小」的屏幕倍率。换屏时用它把百分比换算到新屏。
        var lastBacking: CGFloat = 0

        deinit {
            loadTask?.cancel()
            animState.advance()
            animationTask?.cancel()
            escalateWork?.cancel()
        }

        /// 视图卸载时主动回收动画、DisplayLink 与挂起任务，避免依赖 deinit 时机。
        func teardown() {
            loadTask?.cancel()
            loadTask = nil
            stopAnimation()
            cancelSmoothZoom()
            escalateWork?.cancel()
            escalateWork = nil
        }

        init(_ parent: ImageViewCanvas) {
            self.parent = parent
            super.init()

            // 容器视图严格裁剪边界,杜绝任何过渡图层溢出到左侧边栏
            containerView.clipsToBounds = true
            containerView.canvasBackground = parent.background

            // 原生 AppKit NSPageController:负责双指触控板跟手翻页、惯性、橡皮筋与水平条过渡
            let pageHost = NSView(frame: containerView.bounds)
            pageHost.autoresizingMask = [.width, .height]
            pageHost.clipsToBounds = true
            pageController.view = pageHost
            pageController.delegate = self
            pageController.transitionStyle = .horizontalStrip
            containerView.addSubview(pageHost)

            // 滚动条保持开启(放大后滚轮/触控板平移仍走 clip view),条子本身画成 0 宽以免 fit 取整误出条。
            scrollView.frame = containerView.bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.clipsToBounds = true
            scrollView.verticalScroller = HiddenScroller(frame: .zero)
            scrollView.horizontalScroller = HiddenScroller(frame: .zero)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets()
            scrollView.borderType = .noBorder
            // 磨砂档:滚动视图不能自己铺底色,否则整块画布会盖住窗口背后的玻璃
            scrollView.drawsBackground = !parent.background.isTranslucent
            scrollView.backgroundColor = parent.background.color
            // 捏合不走系统 magnification(手势结束兑换 frame 必有一次跳变),与滚轮同一套 applyScale
            scrollView.allowsMagnification = false
            clipView.drawsBackground = false
            clipView.canvasBackground = parent.background
            clipView.documentView = imageView
            scrollView.contentView = clipView
            containerView.addSubview(scrollView)

            imageView.imageScaling = .scaleNone

            clipView.onZoomDelta = { [weak self] delta, anchor in
                self?.smoothZoom(multiplyingBy: 1 + delta, anchor: anchor, duration: 0.18)
            }
            scrollView.onMagnifyDelta = { [weak self] delta, _ in
                guard let self else { return }
                self.smoothZoom(multiplyingBy: 1 + delta, anchor: self.visibleCenter(), duration: 0.08)
            }
            scrollView.onSmartZoom = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            clipView.onStep = { [weak self] delta in
                self?.stepFromControl(delta)
            }
            clipView.onHorizontalSwipe = { [weak self] step in
                self?.stepFromControl(step)
            }
            clipView.onNativeScrollWheel = { [weak self] event in
                self?.handleNativeScrollWheel(event) ?? false
            }
            clipView.onLayoutChange = { [weak self] in
                self?.handleLayout()
            }
            clipView.onDisplayChange = { [weak self] in
                self?.handleDisplayChange()
            }
            clipView.onSmartZoom = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            imageView.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.toggleZoom(at: self.visibleCenter())
            }
            imageView.onPan = { [weak self] delta in
                self?.pan(by: delta)
            }
            imageView.onSwipe = { [weak self] delta in
                self?.stepFromControl(delta)
            }

            setupSelfTestHooks()
        }

        /// 捏合手势结束:立即把视觉缩放(magnification)兑换为真实重绘。
        /// 若长期保留 magnification≠1,布局处理、缩放下限、升级解码都会基于失真状态运算,
        /// 且双击适配等路径不会重置它导致显示尺寸错误。
        func finishLiveMagnification() {
            guard imageView.image != nil else { return }
            debugLog("liveMagnify end m=\(scrollView.magnification)")
            if abs(scrollView.magnification - 1) > 0.0005 {
                absorbMagnification()
                lateCheck("afterAbsorb")
            }
        }

        /// 把当前的视觉缩放(magnification)在同一帧内兑换为真实重绘。
        /// AppKit 内建放大以视口中心为锚(实测 magnification 前后文档中心不变),
        /// 兑换也必须全程中心锚定:先归一(视觉回到手势前取景),再绕同一中心放大内容。
        /// 若改用光标锚定会与系统语义错位,兑换瞬间产生方向性漂移。
        /// 只在无手势进行时调用(按钮/键盘/手势结束),手势进行中禁止。
        func absorbMagnification() {
            guard imageView.image != nil else { return }
            let m = scrollView.magnification
            guard abs(m - 1) > 0.0005 else {
                scrollView.magnification = 1
                return
            }
            debugLog("absorb m=\(m)")
            wasFit = false
            applyScale(scale * m, anchor: visibleCenter(), resetMagnification: true)
        }

        /// 自测:模拟一次捏合结束(仅 Debug 构建编译)
        func setupSelfTestHooks() {
#if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--zoom-test") else { return }
            NotificationCenter.default.addObserver(
                forName: Notification.Name("PictoolSimPinch"), object: nil, queue: .main
            ) { [weak self] note in
                let m = (note.userInfo?["m"] as? Double) ?? 1.5
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.debugLog("SIM pinch begin m=\(m)")
                    self.scrollView.magnification = CGFloat(m)
                    self.finishLiveMagnification()
                    self.lateCheck("afterSimPinch")
                }
            }
            // 漂移实验:模拟真实捏合路径(连续小步长 smoothZoom,固定锚点),
            // 记录逐 tick 的 origin 与「锚点内容点固定」理论值的偏差。
            // 严格串行:每步动画结束后才触发下一步,避免步间合并导致测量失真。
            NotificationCenter.default.addObserver(
                forName: Notification.Name("PictoolSimAnchorPinch"), object: nil, queue: .main
            ) { [weak self] note in
                // userInfo 是 NSDictionary(非 Sendable),必须在跨隔离边界之前
                // 就把需要的标量取出来,只把 Sendable 的值带进 MainActor 闭包。
                let u = note.userInfo ?? [:]
                let ax = (u["ax"] as? Double) ?? 0.5
                let ay = (u["ay"] as? Double) ?? 0.5
                let steps = (u["steps"] as? Int) ?? 60
                let factor = (u["factor"] as? Double) ?? 1.025
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let clip = self.clipView.bounds
                    let anchor = CGPoint(x: clip.width * CGFloat(ax), y: clip.height * CGFloat(ay))
                    let startOrigin = self.clipView.bounds.origin
                    let startDoc = self.imageView.frame.size
                    let anchorDoc0 = CGPoint(x: anchor.x + startOrigin.x, y: anchor.y + startOrigin.y)
                    var step = 0
                    FileHandle.standardError.write(Data(
                        "[drift] begin anchor=(\(anchor.x),\(anchor.y)) origin=\(startOrigin) doc=\(startDoc)\n".utf8))
                    @MainActor func runStep() {
                        self.smoothZoom(multiplyingBy: CGFloat(factor), anchor: anchor, duration: 0.02)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            MainActor.assumeIsolated {
                                step += 1
                                let o = self.clipView.bounds.origin
                                let d = self.imageView.frame.size
                                // 理论 origin:锚点内容点自实验开始保持不动
                                let totalRatio = d.width / startDoc.width
                                let ideal = CGPoint(x: anchorDoc0.x * totalRatio - anchor.x,
                                                    y: anchorDoc0.y * totalRatio - anchor.y)
                                let errX = o.x - ideal.x
                                let errY = o.y - ideal.y
                                if step % 10 == 0 || abs(errX) > 1 || abs(errY) > 1 {
                                    FileHandle.standardError.write(Data(
                                        "[drift] step=\(step) origin=(\(o.x),\(o.y)) ideal=(\(ideal.x),\(ideal.y)) err=(\(errX),\(errY)) doc=\(d.width)\n".utf8))
                                }
                                if step < steps {
                                    runStep()
                                } else {
                                    FileHandle.standardError.write(Data(
                                        "[drift] END origin=\(o) totalErr=(\(errX),\(errY)) zoom=\(d.width/startDoc.width)\n".utf8))
                                }
                            }
                        }
                    }
                    runStep()
                }
            }
#endif
        }

        /// 已应用的背景。updateNSView 每次 SwiftUI 重渲染都会跑,
        /// 不判等的话 clipView 的 didSet 会让画布每帧全量重绘(平滑缩放时尤其明显)。
        var appliedBackground: CanvasBackground?

        /// 应用画布背景;图片层保持透明以便 PNG 透出背景
        func applyBackground(_ background: CanvasBackground) {
            guard appliedBackground != background else { return }
            appliedBackground = background
            containerView.canvasBackground = background
            // 磨砂档:交出底色,让窗口背后那层玻璃透上来(与 init 里同一处约束)
            scrollView.drawsBackground = !background.isTranslucent
            scrollView.backgroundColor = background.color
            clipView.drawsBackground = false
            clipView.canvasBackground = background
            imageView.layer?.isOpaque = false
            imageView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        // MARK: 加载

        func applyFile(_ file: ImageFile?) {
            let url = file?.url
            guard url != currentURL else { return }
            currentURL = url
            stopAnimation()
            cancelSmoothZoom()
            loadTask?.cancel()
            loadTask = nil
            escalateWork?.cancel()
            escalating = false
            pendingEscalateApply = nil   // 换图后旧图的全尺寸换入作废
            scrollView.magnification = 1   // 切换图片时重置手势缩放

            guard let url else {
                imageView.image = nil
                parent.onLoadingChange(false)
                parent.onImageInfo(DisplayImageInfo())
                parent.onScaleChange(1)
                parent.onRotationChange(false)
                return
            }

            let maxPixel = displayMaxPixel()
            if let cached = ImageLoader.cachedDisplayImage(url: url, maxPixelSize: maxPixel) {
                lastFileSwitchTime = CACurrentMediaTime()
                parent.onLoadingChange(false)
                setDisplayImage(cached.image, facts: cached.facts, url: url)
                if !isLivePaging, parent.transition == .fade, !Self.reduceMotion {
                    runFadeTransition(direction: parent.stepDirection)
                }
                prefetchNeighbors(maxPixel: maxPixel)
                return
            }

            // 保留上一张直到新图就绪,避免切图闪白。单次切图立刻开解;仅在连续快切(<120ms)时短防抖合并中间帧。
            let now = CACurrentMediaTime()
            let isRapidSwitch = (now - lastFileSwitchTime) < 0.12
            lastFileSwitchTime = now
            parent.onLoadingChange(true)
            loadTask = Task { [weak self] in
                guard let self else { return }
                if isRapidSwitch {
                    try? await Task.sleep(nanoseconds: 35_000_000)
                }
                guard !Task.isCancelled, self.currentURL == url else { return }
                let loaded = await ImageLoader.displayImage(url: url, maxPixelSize: maxPixel)
                guard !Task.isCancelled, self.currentURL == url else { return }
                self.loadTask = nil
                self.parent.onLoadingChange(false)
                if let loaded {
                    self.setDisplayImage(loaded.image, facts: loaded.facts, url: url)
                    if !self.isLivePaging, self.parent.transition == .fade, !Self.reduceMotion {
                        self.runFadeTransition(direction: self.parent.stepDirection)
                    }
                } else {
                    self.imageView.image = nil
                    self.parent.onImageInfo(DisplayImageInfo())
                }
                self.prefetchNeighbors(maxPixel: maxPixel)
            }
        }

        /// 切图过渡。淡入只动新图;整页滑移先把当前位图留成快照,再和邻图一起滑走。
        // MARK: 动图(GIF / APNG)

        /// 动画代数:切换图片时递增,使旧动画的帧回调失效
        final class AnimationState: @unchecked Sendable {
            private let lock = NSLock()
            private var generation = 0
            @discardableResult
            func advance() -> Int {
                lock.lock(); defer { lock.unlock() }
                generation += 1
                return generation
            }
            func isCurrent(_ gen: Int) -> Bool {
                lock.lock(); defer { lock.unlock() }
                return gen == generation
            }
        }

        let animState = AnimationState()

        /// CLT SDK 提供 block 版本 API:block 在主队列按帧回调,stop 指针停止播放
        func startAnimation(url: URL) {
            let generation = animState.advance()
            let displaySize = imageView.image?.size ?? .zero
            let state = animState
            animationTask = Task.detached(priority: .userInitiated) { [weak self] in
                CGAnimateImageAtURLWithBlock(url as CFURL, nil as CFDictionary?) { [weak self] _, frame, stop in
                    guard let self, state.isCurrent(generation) else {
                        stop.pointee = true
                        return
                    }
                    Task { @MainActor [weak self] in
                        guard let self, state.isCurrent(generation) else { return }
                        guard self.currentURL == url else {
                            self.animState.advance()
                            return
                        }
                        let size = displaySize.width > 0
                            ? displaySize
                            : NSSize(width: frame.width, height: frame.height)
                        self.imageView.image = NSImage(cgImage: frame, size: size)
                    }
                }
            }
        }

        func stopAnimation() {
            animState.advance()
            animationTask?.cancel()
            animationTask = nil
        }

    }
}
