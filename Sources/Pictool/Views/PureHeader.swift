import SwiftUI
import AppKit

/// 纯 SwiftUI 顶部栏：32pt，承载全部功能按钮，样式完全可定制。
/// 与系统标题栏解耦（hiddenTitleBar + WindowChrome），高度/背景/圆角均可改。
struct PureHeader: View {

    @Environment(FolderStore.self) private var store
    /// 侧栏可见时的宽度,用来把顶栏左段切成独立的「侧栏顶」
    var sidebarWidth: CGFloat? = nil
    /// 全屏时红绿灯交还给了系统标题栏(屏幕顶部那条自动隐藏的栏),这里不再占那一格
    var isFullScreen: Bool = false
    @AppStorage(SidebarTopStyle.storageKey) private var sidebarTopStyle = SidebarTopStyle.defaultValue
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    private var mainHeaderColorScheme: ColorScheme {
        ChromeTheme.colorScheme(for: canvasBackground)
    }

    var body: some View {
        HStack(spacing: 5) {
            leftCluster
            Spacer()
            rightCluster
        }
        .padding(.horizontal, 12)
        .environment(\.colorScheme, mainHeaderColorScheme)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        // 拖拽区必须与背景同层且在其之上:分成两个 .background 时后挂的那层在更底下,
        // 会被不透明的 headerBackground 完全遮住,双击缩放收不到事件。
        .background {
            ZStack {
                headerBackground
                // 自定义拖拽区：空白处拖动窗口，双击缩放；按钮区域不受影响
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { _ in
                                if let window = NSApp.keyWindow ?? NSApp.mainWindow,
                                   let event = NSApp.currentEvent {
                                    window.performDrag(with: event)
                                }
                            }
                    )
                    .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
            }
        }
        // 与下方侧栏同一曲线同一触发:材质分界线与侧栏边缘是同一条竖缝,锁步移动
        .animation(.easeInOut(duration: 0.22), value: store.sidebarVisible)
    }

    @ViewBuilder
    private var headerBackground: some View {
        ZStack(alignment: .leading) {
            mainHeaderBackground
            if sidebarTopStyle == .followSidebar, let width = sidebarWidth {
                // 宽度连续伸缩(而非可见性二值切换),与侧栏列宽动画完全同步
                SidebarTopBackground()
                    .frame(width: store.sidebarVisible ? width : 0)
                    .clipped()
            }
        }
    }

    private var mainHeaderBackground: some View {
        MainChromeBackground(canvas: canvasBackground)
    }

    private var leftCluster: some View {
        HStack(spacing: 5) {
            // 全屏时不摆红绿灯:它们在系统那条栏里,这里留空只会多出一截空档
            if !isFullScreen {
                NativeTrafficLights()
                    .frame(width: NativeTrafficLights.width, height: NativeTrafficLights.height)
            }
            HeaderButton("sidebar.leading", help: "显示/隐藏侧栏 (⌃⌘S)") {
                store.toggleSidebar()
            }
            Spacer().frame(width: 8)
            Text("PureView")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var rightCluster: some View {
        HStack(spacing: 5) {
            if !store.isEditing {
                HeaderButton("folder.badge.plus", help: "打开图片文件夹 (⌘O)") {
                    store.openFolderPanel()
                }
                HeaderDivider()
            }
            HeaderButton("chevron.left", help: "上一张 (←)",
                         disabled: !store.canStep(-1)) { store.step(-1) }
            HeaderButton("chevron.right", help: "下一张 (→)",
                         disabled: !store.canStep(1)) { store.step(1) }
            HeaderDivider()
            if !store.isEditing {
                HeaderButton("minus.magnifyingglass", help: "缩小 (⌘-)",
                             disabled: store.currentImage == nil) { store.requestZoom(.zoomOut) }
                HeaderButton("plus.magnifyingglass", help: "放大 (⌘=)",
                             disabled: store.currentImage == nil) { store.requestZoom(.zoomIn) }
                HeaderDivider()
                HeaderButton("rotate.right", help: "顺时针旋转 90°",
                             disabled: store.currentImage == nil) { store.requestRotate() }
            }
            HeaderButton("square.and.pencil",
                         help: store.isEditing ? "退出编辑" : "编辑 (D)",
                         disabled: store.currentImage == nil,
                         emphasized: store.isEditing) { store.toggleEditing() }
            if !store.isEditing {
                HeaderButton("printer", help: "打印 (⌘P)",
                             disabled: store.currentImage == nil) { store.requestPrint() }
            }
            HeaderButton("info.circle", help: "图片信息 (I)") {
                store.showInspector.toggle()
            }
            if !store.isEditing {
                HeaderButton(
                    store.isSlideshowActive && !store.isSlideshowPaused ? "pause.circle" : "play.circle",
                    help: store.isSlideshowActive && !store.isSlideshowPaused
                        ? "暂停幻灯片 (空格)"
                        : "幻灯片播放 (空格)",
                    disabled: store.currentImage == nil || store.visibleImages.count < 2
                ) { store.toggleSlideshow() }
                HeaderDivider()
                HeaderButton(
                    store.isImmersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: store.isImmersive ? "退出只看图 (Esc / F)" : "只看图,隐藏所有界面 (F)",
                    disabled: store.currentImage == nil && !store.isImmersive
                ) { store.toggleImmersive() }
            }
        }
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    var emphasized = false
    let action: () -> Void

    @State private var hovering = false

    init(_ systemImage: String, help: String, disabled: Bool = false,
         emphasized: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.disabled = disabled
        self.emphasized = emphasized
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: emphasized ? .semibold : .regular))
                .frame(width: 24, height: 20)
                .background(
                    // 选中态只用填充表达(macOS 工具栏范式):阴影语义是"抬升",和"按下"矛盾
                    emphasized
                        ? Color.accentColor.opacity(0.18)
                        : (hovering && !disabled ? Color.primary.opacity(0.08) : .clear),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .onHover { hovering = $0 }
    }
}

private struct HeaderDivider: View {
    var body: some View { Divider().frame(height: 13) }
}

/// 把窗口自带的关闭/最小化/缩放按钮嵌进自定义顶栏,保留系统绘制、悬停符号和无障碍。
struct NativeTrafficLights: NSViewRepresentable {
    static let width: CGFloat = 56
    static let height: CGFloat = 16

    func makeNSView(context: Context) -> NativeTrafficLightsView {
        NativeTrafficLightsView()
    }

    func updateNSView(_ nsView: NativeTrafficLightsView, context: Context) {
        nsView.embedButtons()
    }
}

final class NativeTrafficLightsView: NSView {
    private var tracking: NSTrackingArea?
    private var hovering = false
    private static let buttonSpacing: CGFloat = 8
    private static let mouseInGroup = NSSelectorFromString("_setMouseInGroup:")
    /// 按钮被接管前的原生父视图(标题栏容器)。全屏时要交还给它。
    private weak var originalContainer: NSView?
    /// 接管时所在的窗口。`viewWillMove(toWindow: nil)` 期间极少数情况下 `self.window` 已经空了,
    /// 留一份兜底 —— 拿不到窗口就还不了按钮,全屏时会一个红绿灯都没有。
    private weak var cachedWindow: NSWindow?
    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        embedButtons()
        DispatchQueue.main.async { [weak self] in self?.embedButtons() }
    }

    /// 视图被从窗口上摘掉之前(例如全屏时 SwiftUI 不再渲染这一格),先把红绿灯交还标题栏。
    /// 漏了这一步,按钮会跟着这个 view 一起从窗口里消失 —— 全屏时就一个红绿灯都没有了。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { releaseButtons() }
    }

    override func layout() {
        super.layout()
        embedButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyGroupHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyGroupHover()
    }

    func embedButtons() {
        guard let window else { return }
        cachedWindow = window
        // 全屏时把红绿灯交还系统标题栏 —— macOS 会把标题栏抽成屏幕顶部那条自动隐藏的栏,
        // 应用名和红绿灯本来就该在那儿。继续接管的话,那条栏是空的,红绿灯会留在应用自己的
        // 顶栏里,看起来就像"全屏了但窗口还是原来那个"。
        if window.styleMask.contains(.fullScreen) {
            releaseButtons()
            return
        }
        var x: CGFloat = 0
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if button.superview !== self {
                // 只在第一次接管时记下原生容器;之后 button.superview 就是 self 了
                if originalContainer == nil { originalContainer = button.superview }
                button.removeFromSuperview()
                addSubview(button)
            }
            button.isHidden = false
            let size = button.frame.size.width > 1 ? button.frame.size : NSSize(width: 14, height: 16)
            let y = ((bounds.height - size.height) / 2).rounded(.toNearestOrAwayFromZero)
            button.setFrameOrigin(NSPoint(x: x, y: max(0, y)))
            x += size.width + Self.buttonSpacing
        }
        applyGroupHover()
    }

    /// 把接管过来的红绿灯还回标题栏容器,位置交回 AppKit 自己摆。
    private func releaseButtons() {
        guard let window = window ?? cachedWindow else { return }
        guard Self.buttonTypes.contains(where: { window.standardWindowButton($0)?.superview === self }) else { return }
        let host = originalContainer ?? Self.findTitlebar(in: window)
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type), button.superview === self else { continue }
            button.removeFromSuperview()
            button.isHidden = false
            host?.addSubview(button)
        }
        // 交还后立刻催一次布局:光标 needsLayout 要等下一轮 run loop,
        // 全屏切换那一帧容易被人眼看到"按钮还堆在 (0,0)"。
        host?.needsLayout = true
        host?.layoutSubtreeIfNeeded()
        window.contentView?.superview?.needsLayout = true
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    private static func findTitlebar(in window: NSWindow) -> NSView? {
        guard let theme = window.contentView?.superview else { return nil }
        return theme.subviews.first { String(describing: type(of: $0)).contains("Titlebar") }
    }

    private func applyGroupHover() {
        for type in Self.buttonTypes {
            guard let button = window?.standardWindowButton(type),
                  button.responds(to: Self.mouseInGroup) else { continue }
            button.perform(Self.mouseInGroup, with: NSNumber(value: hovering))
        }
    }
}

