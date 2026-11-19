import SwiftUI
import AppKit

/// 窗口 chrome：移除原生标题栏，仅保留 PureHeader 单层
struct WindowChrome: NSViewRepresentable {
    let immersive: Bool
    var fullscreenLinkedImmersive = false
    var allowBackgroundMove = true

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.immersive = immersive
        (nsView as? ChromeView)?.fullscreenLinkedImmersive = fullscreenLinkedImmersive
        (nsView as? ChromeView)?.allowBackgroundMove = allowBackgroundMove
        (nsView as? ChromeView)?.apply()
    }
}

private final class ChromeView: NSView {
    var immersive = false
    var fullscreenLinkedImmersive = false
    var allowBackgroundMove = true
    /// 应用名(全屏那条系统栏要显示它)。取自 Info.plist,避免与 `build.sh` 里的
    /// `CFBundleName` 各写一份;取不到时退回 "PureView"。
    private static let appName: String = {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
              !name.isEmpty else { return "PureView" }
        return name
    }()
    /// 见过的标题栏容器(全屏 / 非全屏要来回切显隐),以及它被压成 0 高之前的原始高度
    private var titlebarViews: [NSView] = []
    private var titlebarOriginalHeight: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        DispatchQueue.main.async { [weak self] in self?.stripTitlebar() }
        observeWindowState()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
    func apply() { stripTitlebar() }

    /// 进出全屏要重跑一遍:全屏下标题栏是"还给系统"的,与平时正好相反。
    /// 光靠 updateNSView 不行 —— SwiftUI 不会因为窗口进了全屏就重算这个视图。
    /// 会改变"标题栏该不该露出来"的所有窗口事件。
    /// 进出全屏是主因;**换显示器 / 换缩放同样会重排 theme frame** —— AppKit 会把标题栏容器
    /// 的高度还原,不重跑一次,原生标题栏就会重新冒出来(红绿灯出现在窗口左上角)。
    private static let chromeNotifications: [Notification.Name] = [
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification,
    ]

    private func observeWindowState() {
        let center = NotificationCenter.default
        for name in Self.chromeNotifications {
            center.removeObserver(self, name: name, object: nil)
        }
        guard let window else { return }
        for name in Self.chromeNotifications {
            center.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
        }
    }

    @objc private func windowStateChanged() {
        stripTitlebar()
        // 换屏那次重排往往紧跟在通知之后,同步这一次会被它覆盖 —— 下一轮 run loop 再补一次
        DispatchQueue.main.async { [weak self] in self?.stripTitlebar() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 窗口 chrome 的唯一落点。**每次 SwiftUI 重渲染都会跑到这里**(经 `WindowChrome.updateNSView`),
    /// 所以下面**每一处赋值都只在值真的会变时才写** —— 无条件写 `title` / 标题栏容器的
    /// `frame.size.height` / 图层遮罩,每次都会强制 theme frame 重新布局与重新合成,
    /// 在 1x(1080p)面板上会被看成画面轻微闪动。
    /// (同一类问题 P1-3 在画布那边已经修过:`updateNSView` 不再无条件重绘整块画布。)
    private func stripTitlebar() {
        WindowMoveControl.setBackgroundMove(allowBackgroundMove)
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        // 记住窗口位置与尺寸,下次启动恢复到上次的位置
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("MainWindow")
        }
        // 全屏时把标题栏还给系统:macOS 会把它抽成屏幕顶部那条自动隐藏的栏,
        // 显示"应用名 + 红绿灯"。此前这里一刀切地藏掉标题栏,全屏时那条栏就是空的,
        // 红绿灯只能留在应用自己的顶栏里 —— 看起来就像"全屏了,窗口还是原来那个"。
        let fullScreen = window.styleMask.contains(.fullScreen)
        // 纯净模式(无论是否全屏)都不要系统那条栏;非纯净的全屏要看得见。
        // 全屏引发的纯净由 fullscreenLinkedImmersive 标记:进全屏时自动带入,
        // 此时鼠标扫顶部也没有系统栏 —— 出口统一收敛到右上角热区/Esc。
        let showSystemTitlebar = fullScreen && !immersive && !fullscreenLinkedImmersive
        // 全屏那条栏本身要看得见,所以别让它透明;平时仍然透明(应用顶栏自己画背景)
        if window.titlebarAppearsTransparent != !showSystemTitlebar {
            window.titlebarAppearsTransparent = !showSystemTitlebar
        }
        let visibility: NSWindow.TitleVisibility = showSystemTitlebar ? .visible : .hidden
        if window.titleVisibility != visibility { window.titleVisibility = visibility }
        // 用 Info.plist 的 CFBundleName,别在这里再硬写一遍应用名(改一次要记得改两处)
        let title = showSystemTitlebar ? Self.appName : ""
        if window.title != title { window.title = title }
        if window.backgroundColor != .clear { window.backgroundColor = .clear }
        if window.isOpaque { window.isOpaque = false }
        // 全屏/纯净无圆角;14–15 自己裁 10pt;26+ 交给系统窗口裁,避免和本机半径叠出白边
        let radius: CGFloat = (immersive || fullScreen) ? 0 : WindowChromeMetrics.cornerRadius
        applyChrome(to: window.contentView, radius: radius)
        applyChrome(to: window.contentView?.superview, radius: radius)
        // 原生标题栏藏掉,避免挡自定义顶栏点击;红绿灯由 PureHeader 里的 NativeTrafficLights 接管。
        // 纯净模式连按钮一起藏(全屏引发的纯净也算)。
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(b) else { continue }
            let shouldHide = immersive || fullscreenLinkedImmersive
            if button.isHidden != shouldHide { button.isHidden = shouldHide }
        }
        for view in titlebarViews(in: window) {
            if showSystemTitlebar {
                if view.isHidden { view.isHidden = false }
                // 之前被压成 0 高,这里要还原,否则那条栏是一条零高度的缝
                if titlebarOriginalHeight > 1, view.frame.size.height < 1 {
                    view.frame.size.height = titlebarOriginalHeight
                }
            } else {
                if titlebarOriginalHeight < 1, view.frame.size.height > 1 {
                    titlebarOriginalHeight = view.frame.size.height
                }
                if !view.isHidden { view.isHidden = true }
                if view.frame.size.height != 0 { view.frame.size.height = 0 }
            }
        }
    }

    /// 圆角 / 遮罩只在真的需要改时才动 —— 给图层赋值本身就会触发一次重新合成。
    /// 圆角为 0 时(`immersive` 或全屏)没必要开 `masksToBounds`:既是纯开销,
    /// 又会把整窗内容拖进离屏通道,在 1x 面板上容易出现合成层面的轻微闪动。
    private func applyChrome(to view: NSView?, radius: CGFloat) {
        guard let view else { return }
        if !view.wantsLayer { view.wantsLayer = true }
        if view.layer?.cornerRadius != radius { view.layer?.cornerRadius = radius }
        let curve: CALayerCornerCurve = radius > 0 ? .continuous : .circular
        if view.layer?.cornerCurve != curve { view.layer?.cornerCurve = curve }
        let shouldMask = radius > 0
        if view.layer?.masksToBounds != shouldMask { view.layer?.masksToBounds = shouldMask }
    }

    /// 标题栏容器:用记住的那些(AppKit 进出全屏时可能把它挪进另一个窗口,
    /// 那时按类型名在 theme frame 的子树里就找不到了),再并上当前扫到的。
    /// 这里刻意不清理"看起来已经死掉"的引用 —— 过渡中途 superview 可能短暂为 nil,
    /// 一旦清掉就再也无法把它露出来;一个窗口最多也就这么一两个容器,留着无妨。
    private func titlebarViews(in window: NSWindow) -> [NSView] {
        if let theme = window.contentView?.superview {
            for sub in theme.subviews
            where String(describing: type(of: sub)).contains("Titlebar")
                && !titlebarViews.contains(where: { $0 === sub }) {
                titlebarViews.append(sub)
            }
        }
        return titlebarViews
    }
}
