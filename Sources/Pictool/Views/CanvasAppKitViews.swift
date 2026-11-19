import AppKit
import QuartzCore

// MARK: - AppKit 子类

/// 0 宽且不绘制,让 NSScrollView 仍处理滚轮平移,画面上不出条子。
final class HiddenScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {}
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
}

/// 捏合手势自己处理,避免 NSScrollView.magnification 在松手时再兑换一次 frame。
final class CanvasScrollView: NSScrollView {
    var onMagnifyDelta: ((CGFloat, CGPoint) -> Void)?
    var onSmartZoom: (() -> Void)?

    override func tile() {
        super.tile()
        verticalScroller?.alphaValue = 0
        horizontalScroller?.alphaValue = 0
    }

    override func magnify(with event: NSEvent) {
        let loc = contentView.convert(event.locationInWindow, from: nil)
        onMagnifyDelta?(event.magnification, loc)
    }

    override func smartMagnify(with event: NSEvent) {
        onSmartZoom?()
    }
}

/// 居中裁剪视图:文档小于可视区时居中。
/// ⌘/⌥ 滚轮缩放与左右方向键由本类处理。
final class CanvasClipView: NSClipView {

    var onZoomDelta: ((CGFloat, CGPoint) -> Void)?
    var onStep: ((Int) -> Void)?
    var onLayoutChange: (() -> Void)?
    /// 窗口换了屏幕或缩放倍率
    var onDisplayChange: (() -> Void)?
    var onSmartZoom: (() -> Void)?
    /// 横滑切图提交(淡入模式回退用)。方向语义全项目统一:+1 = 下一张,-1 = 上一张
    var onHorizontalSwipe: ((Int) -> Void)?
    /// 原生 NSPageController 双指横滑转发:返回 true 表示已由 NSPageController 接管。
    var onNativeScrollWheel: ((NSEvent) -> Bool)?
    /// applyDocument 写入期间锁定 origin,防止 constrain 在同一拍改掉取景
    var pinnedOrigin: NSPoint?
    /// 画布背景(随偏好设置切换)。值没变就别置脏,否则每次 updateNSView 都会整块重绘。
    var canvasBackground: CanvasBackground = .dark {
        didSet { if oldValue != canvasBackground { needsDisplay = true } }
    }

    private var swipeAccumulatedDX: CGFloat = 0
    private var swipeGestureActive = false
    private var swipeCommittedThisGesture = false
    /// 提交防抖:两次提交至少间隔此秒数,兜住异常事件流(如未发 .ended 的手势)
    private var lastSwipeCommitTime = TimeInterval(0)
    private static let horizontalSwipeThreshold: CGFloat = 55
    private static let swipeCommitMinInterval: TimeInterval = 0.30

    /// 磨砂档必须交出不透明 —— 否则这块画布会盖住窗口背后的玻璃,磨砂就白做了。
    /// 切换档位时 `canvasBackground` 的 `didSet` 会置脏,AppKit 会重新读一次这个属性。
    override var isOpaque: Bool { !canvasBackground.isTranslucent }

    override func draw(_ dirtyRect: NSRect) {
        // 磨砂档不画底色,但**必须把这块擦成透明**:非不透明的视图不会自动清理自己的
        // 绘制区域,只「跳过填充」会留下上一帧的残影。
        if canvasBackground.isTranslucent {
            NSColor.clear.set()
            dirtyRect.fill(using: .clear)
            return
        }
        canvasBackground.fill(dirtyRect)
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--zoom-debug") {
            let b = bounds
            FileHandle.standardError.write(Data(
                "[scroll] dy=\(event.scrollingDeltaY) dx=\(event.scrollingDeltaX) phase=\(event.momentumPhase.rawValue)/\(event.phase.rawValue) loc=(\(event.locationInWindow.x - b.origin.x),\(event.locationInWindow.y)) origin=\(b.origin)\n".utf8))
        }
#endif
        if mods.contains(.command) || mods.contains(.option) {
            // 以光标为锚点缩放(与捏合语义一致)
            onZoomDelta?(event.scrollingDeltaY * 0.01, convert(event.locationInWindow, from: nil))
            return
        }
#if DEBUG
        // 漂移实验开关:普通滚轮走捏合同一缩放路径,用真实 HID 事件验证锚定
        if ProcessInfo.processInfo.arguments.contains("--zoom-scroll-test") {
            onZoomDelta?(event.scrollingDeltaY * 0.01, convert(event.locationInWindow, from: nil))
            return
        }
#endif
        // 图片横向未溢出时,将双指横滑事件直接交给 AppKit 原生 NSPageController 接管
        // (跟手、惯性、橡皮筋、边界裁切全由系统原厂处理)。
        if !isDocumentHorizontallyScrollable,
           onNativeScrollWheel?(event) == true {
            return
        }
        // 淡入模式(未走原生分页)的横滑阈值切图回退
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let panX = ImageHandoff.trackpadFingerDelta(dx, naturalScrolling: event.isDirectionInvertedFromDevice)
        if abs(dx) > abs(dy) * 1.35, abs(dx) > 0.4,
           !isDocumentHorizontallyScrollable,
           event.phase != .ended, event.momentumPhase == [] {
            swipeGestureActive = true
            swipeAccumulatedDX += panX
            let now = CACurrentMediaTime()
            if !swipeCommittedThisGesture,
               now - lastSwipeCommitTime >= Self.swipeCommitMinInterval,
               abs(swipeAccumulatedDX) >= Self.horizontalSwipeThreshold {
                onHorizontalSwipe?(swipeAccumulatedDX > 0 ? -1 : 1)
                swipeCommittedThisGesture = true
                lastSwipeCommitTime = now
                swipeAccumulatedDX = 0
            }
            return
        }
        if event.phase == .ended || (swipeGestureActive && event.momentumPhase != []) {
            swipeGestureActive = false
            swipeCommittedThisGesture = false
            swipeAccumulatedDX = 0
            if event.momentumPhase != [] { return }
        }
        super.scrollWheel(with: event)
    }

    private var isDocumentHorizontallyScrollable: Bool {
        guard let doc = documentView else { return false }
        return doc.frame.width > bounds.width + 0.5
    }

    override func magnify(with event: NSEvent) {
        enclosingScrollView?.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        onSmartZoom?()
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let doc = documentView, doc.frame.contains(loc) {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            window?.zoom(self)
            return
        }
        window?.performDrag(with: event)
    }

    override func moveLeft(_ sender: Any?) { onStep?(-1) }
    override func moveRight(_ sender: Any?) { onStep?(1) }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = proposedBounds
        if let pinned = pinnedOrigin {
            rect.origin = pinned
            return rect
        }
        guard let doc = documentView?.frame else { return super.constrainBoundsRect(proposedBounds) }
        let backing = window?.backingScaleFactor ?? 2
        rect.origin = ZoomMath.snappedPoint(
            ZoomMath.constrainedOrigin(
                proposed: proposedBounds.origin,
                docSize: doc.size,
                clipSize: proposedBounds.size
            ),
            backing: backing
        )
        return rect
    }

    override func layout() {
        super.layout()
        onLayoutChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeDisplay()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let responder = window.firstResponder, responder is NSTextView { return }
            window.makeFirstResponder(self)
        }
    }

    /// deinit 非隔离,观察者句柄只在这里摘除。
    nonisolated(unsafe) private var displayObservers: [NSObjectProtocol] = []

    deinit {
        for observer in displayObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeDisplay() {
        for observer in displayObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        displayObservers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            displayObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.onDisplayChange?()
                    }
                }
            )
        }
    }
}

/// 图片视图:双击切换缩放;鼠标拖拽按手势模式分流——
/// 图片水平方向无溢出时,横向主导的拖动是「滑动切图」(阈值提交,防误触);
/// 其余情况走平移。渲染走 layer.contents(GPU 纹理):缩放改 frame 只是几何变换,
/// 不触发主线程按新尺寸重栅格化位图——丝滑的关键。
final class CanvasImageView: NSImageView {

    var onDoubleClick: (() -> Void)?
    var onPan: ((CGSize) -> Void)?
    /// 滑动切图提交。方向语义全项目统一:+1 = 下一张,-1 = 上一张
    var onSwipe: ((Int) -> Void)?
    /// 跟手拖拽。返回 true 表示已接管,松手不再按阈值另交一张。
    var onSwipePan: ((CGFloat, Bool) -> Bool)?

    private enum DragMode { case undecided, pan, swipe }
    private var dragMode: DragMode = .undecided
    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var swipeTotalDX: CGFloat = 0
    private static let swipeDecideThreshold: CGFloat = 10
    private static let swipeCommitThreshold: CGFloat = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // 层托管(layer-hosting):自建 CALayer 并接管,
        // AppKit 不再向层栅格化 draw(_) 内容,layer.contents 由本类独占管理
        wantsLayer = true
        let hostLayer = CALayer()
        hostLayer.contentsGravity = .resize
        hostLayer.minificationFilter = .trilinear
        // 禁止 frame/contents 隐式动画,否则缩放停住后图层还会再滑一小段
        hostLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "contentsScale": NSNull(),
            "transform": NSNull(),
        ]
        layer = hostLayer
        hostLayer.isOpaque = false
        hostLayer.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayer()
    }

    override var image: NSImage? {
        get { super.image }
        set {
            let kept = frame
            super.image = newValue
            if frame != kept { frame = kept }
            syncLayer()
        }
    }

    private func syncLayer() {
        guard let layer else { return }
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 内容由 GPU 纹理呈现;AppKit 位图绘制通道关闭
    override func draw(_ dirtyRect: NSRect) {}

    override func magnify(with event: NSEvent) {
        enclosingScrollView?.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        enclosingScrollView?.smartMagnify(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetDragState()
            onDoubleClick?()
            return
        }
        dragMode = .undecided
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = mouseDownPoint
        swipeTotalDX = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let last = lastDragPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let total = CGSize(width: current.x - start.x, height: current.y - start.y)

        if dragMode == .undecided {
            let absX = abs(total.width), absY = abs(total.height)
            guard max(absX, absY) >= Self.swipeDecideThreshold else { return }
            // 横向主导且图片水平方向没有可滚动余量 → 滑动切图;其余一律平移
            if absX > absY && !isHorizontallyOverflowing {
                dragMode = .swipe
                // 判定前那几像素也算上,否则图片会一直落在光标后面。
                lastDragPoint = start
            } else {
                dragMode = .pan
            }
        }
        switch dragMode {
        case .swipe:
            let dx = current.x - last.x
            if onSwipePan?(dx, false) != true {
                swipeTotalDX += dx
            }
        case .pan:
            onPan?(CGSize(width: current.x - last.x, height: current.y - last.y))
        case .undecided:
            break
        }
        lastDragPoint = current
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetDragState() }
        guard dragMode == .swipe else { return }
        if onSwipePan?(0, true) == true { return }
        guard abs(swipeTotalDX) >= Self.swipeCommitThreshold else { return }
        // 跟相册一样:往右拖 = 上一张,往左拖 = 下一张。与触控板横滑同一方向。
        onSwipe?(swipeTotalDX > 0 ? -1 : 1)
    }

    private func resetDragState() {
        dragMode = .undecided
        mouseDownPoint = nil
        lastDragPoint = nil
        swipeTotalDX = 0
    }

    /// 图片显示宽度是否超过视口宽度(超出时横向拖动属于平移语义)
    private var isHorizontallyOverflowing: Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return frame.width > clip.bounds.width + 0.5
    }
}
