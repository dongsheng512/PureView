import AppKit
import QuartzCore

/// 主画布容器:严格裁剪子视图边界,彻底杜绝任何过渡图层溢出到左侧边栏。
final class CanvasContainerView: NSView {
    var canvasBackground: CanvasBackground = .dark {
        didSet { if oldValue != canvasBackground { needsDisplay = true } }
    }

    override var isOpaque: Bool { !canvasBackground.isTranslucent }

    override func draw(_ dirtyRect: NSRect) {
        if canvasBackground.isTranslucent {
            NSColor.clear.set()
            dirtyRect.fill(using: .clear)
            return
        }
        canvasBackground.fill(dirtyRect)
    }
}

/// NSPageController 的单页控制器:仅用于翻页过渡期间呈现居中适配的预览图。
/// 优先同步命中 DisplayImageCache(零延迟),未命中则后台异步解码填充。
@MainActor
final class PageSlideViewController: NSViewController {
    private let slideView = PageSlideView()
    private var loadTask: Task<Void, Never>?
    private var displayedURL: URL?

    override func loadView() {
        view = slideView
    }

    func display(url: URL, maxPixel: CGFloat) {
        if displayedURL == url, slideView.image != nil { return }
        displayedURL = url
        loadTask?.cancel()
        loadTask = nil

        if let cached = ImageLoader.cachedDisplayImage(url: url, maxPixelSize: maxPixel) {
            slideView.image = cached.image
            return
        }
        slideView.image = nil
        loadTask = Task { [weak self] in
            let loaded = await ImageLoader.displayImage(url: url, maxPixelSize: maxPixel)
            guard !Task.isCancelled, let self, self.displayedURL == url else { return }
            self.slideView.image = loaded?.image
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        loadTask?.cancel()
        loadTask = nil
    }
}

/// 单页图片视图:透明底 + 居中保持宽高比绘制(与 CanvasScrollView 的适配态几何完全一致)。
private final class PageSlideView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let backing = window?.backingScaleFactor ?? 2
        let rect = ImageHandoff.fittedRect(imageSize: image.size, viewport: bounds.size, backing: backing)
        guard rect.width > 1, rect.height > 1 else { return }
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

// MARK: - 原生 NSPageController 翻页适配器

extension ImageViewCanvas.Coordinator {

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 同步可见图片列表与当前选中索引到原生 NSPageController。
    /// 当偏好为「跟手翻页」且通过方向键/按钮切到相邻 1 张时,调用原生 animator() 播放水平条翻页。
    func syncPageController(files: [ImageFile], currentFile: ImageFile?) {
        let urls = files.map(\.url)
        let listChanged = urls != arrangedURLs
        if listChanged {
            arrangedURLs = urls
            if !isLivePaging {
                pageController.arrangedObjects = urls
            }
        }
        guard let targetURL = currentFile?.url,
              let targetIndex = urls.firstIndex(of: targetURL) else {
            return
        }
        guard !isLivePaging else { return }
        let oldIndex = pageController.selectedIndex
        guard oldIndex != targetIndex else { return }

        let isAdjacent = oldIndex >= 0 && abs(targetIndex - oldIndex) == 1
        let shouldAnimate = !listChanged
            && isAdjacent
            && parent.transition == .slide
            && !Self.reduceMotion
            && imageView.image != nil
            && parent.stepDirection != 0

        if shouldAnimate {
            animatePageController(to: targetIndex)
        } else {
            pageController.selectedIndex = targetIndex
        }
    }

    /// 用 AppKit 原生 NSPageController.animator() 执行相邻切图动画(与双指横滑同一套原生引擎)。
    private func animatePageController(to index: Int) {
        pageAnimationGeneration += 1
        let gen = pageAnimationGeneration
        isLivePaging = true
        scrollView.isHidden = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageController.animator().selectedIndex = index
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pageAnimationGeneration == gen else { return }
                self.pageController.completeTransition()
                self.isLivePaging = false
                self.scrollView.isHidden = false
            }
        })
    }

    /// 将未放大状态下的触控板双指横滑直接转交 AppKit 原生 NSPageController。
    func handleNativeScrollWheel(_ event: NSEvent) -> Bool {
        guard parent.transition == .slide,
              !Self.reduceMotion,
              arrangedURLs.count > 1,
              imageView.image != nil else {
            return false
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let hasTouchPhase = event.phase != [] || event.momentumPhase != []
        guard hasTouchPhase else { return false }

        // 已在原生翻页中,或明显以横向为主的双指滑动 → 全部交给 NSPageController 接管
        if isLivePaging || (abs(dx) > abs(dy) * 1.1 && abs(dx) > 0.2) {
            pageController.scrollWheel(with: event)
            return true
        }
        return false
    }

    /// 方向键、按钮、鼠标横滑切图入口。
    func stepFromControl(_ direction: Int) {
        parent.neighbors = parent.onStep(direction)
    }

    // MARK: - NSPageControllerDelegate

    func pageController(_ pageController: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        "image"
    }

    func pageController(_ pageController: NSPageController, viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier) -> NSViewController {
        PageSlideViewController()
    }

    func pageController(_ pageController: NSPageController, prepare viewController: NSViewController, with object: Any?) {
        guard let vc = viewController as? PageSlideViewController,
              let url = object as? URL else { return }
        vc.display(url: url, maxPixel: displayMaxPixel())
    }

    func pageControllerWillStartLiveTransition(_ pageController: NSPageController) {
        pageAnimationGeneration += 1
        isLivePaging = true
        cancelSmoothZoom()
        // 隐藏顶层交互画布,露出原生 NSPageController 进行 100% 苹果原厂双指跟手过渡
        scrollView.isHidden = true
        prefetchNeighbors(maxPixel: displayMaxPixel())
    }

    func pageController(_ pageController: NSPageController, didTransitionTo object: Any) {
        guard let url = object as? URL else { return }
        if currentURL != url {
            parent.onSelect(url)
        }
    }

    func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
        pageController.completeTransition()
        isLivePaging = false
        // 如果过渡期间列表变更过,此时补同步
        if arrangedURLs.count != pageController.arrangedObjects.count {
            pageController.arrangedObjects = arrangedURLs
            if let cur = currentURL, let idx = arrangedURLs.firstIndex(of: cur) {
                pageController.selectedIndex = idx
            }
        }
        scrollView.isHidden = false
    }

    // MARK: - 淡入模式与显示装配

    /// 偏好选择「淡入」时的轻量单层过渡。
    func runFadeTransition(direction: Int) {
        guard let layer = imageView.layer, imageView.image != nil else { return }
        layer.removeAnimation(forKey: "entrySlide")
        layer.removeAnimation(forKey: "entryFade")
        layer.opacity = 1
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        if direction != 0 {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = layer.position.x + CGFloat(direction) * 24
            slide.toValue = layer.position.x
            slide.duration = 0.22
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(slide, forKey: "entrySlide")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "entryFade")
        CATransaction.commit()
    }

    func prefetchNeighbors(maxPixel: CGFloat) {
        var urls = parent.neighbors.urls
        // 额外预取前后第 2 张,确保双指连续快速翻页时每页秒出图
        if let cur = currentURL, let idx = arrangedURLs.firstIndex(of: cur) {
            for offset in [-2, 2] {
                let target = idx + offset
                if arrangedURLs.indices.contains(target) {
                    let u = arrangedURLs[target]
                    if !urls.contains(u) { urls.append(u) }
                }
            }
        }
        guard !urls.isEmpty else { return }
        for url in urls {
            ImageLoader.prefetchDisplay(url: url, maxPixelSize: maxPixel)
        }
    }

    func displayMaxPixel() -> CGFloat {
        let size = containerView.bounds.size
        let backing = scrollView.window?.backingScaleFactor ?? 2
        return max(2048, CGFloat(Int(max(size.width, size.height))) * backing)
    }

    func setDisplayImage(_ image: NSImage?, facts: ImageLoader.SourceFacts, url: URL) {
        parent.onLoadingChange(false)
        isFullResolution = false
        guard let image, facts.pixelWidth > 0 else {
            imageView.image = nil
            parent.onImageInfo(DisplayImageInfo())
            return
        }
        truePixelSize = CGSize(width: facts.pixelWidth, height: facts.pixelHeight)
        bitmapPixelSize = truePixelSize
        isRotatedBitmap = false
        appliedRotationCount = 0
        frameCount = max(1, facts.frameCount)
        parent.onRotationChange(false)
        parent.onImageInfo(DisplayImageInfo(
            pixelWidth: facts.pixelWidth,
            pixelHeight: facts.pixelHeight,
            frameCount: facts.frameCount,
            formatName: MetadataService.formatName(of: facts.formatID)
        ))
        imageView.image = image
        applyOpenZoom()
        if facts.frameCount > 1 {
            startAnimation(url: url)
        }
    }
}
