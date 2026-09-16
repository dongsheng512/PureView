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
        // 非全屏贴齐原生红绿灯左边距(约 8pt);全屏无灯,用和右侧一样的 12pt
        .padding(.leading, isFullScreen ? 12 : 8)
        .padding(.trailing, 12)
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
        HStack(spacing: 0) {
            // 全屏时不摆红绿灯:它们在系统那条栏里,这里留空只会多出一截空档
            if !isFullScreen {
                NativeTrafficLights()
                    .frame(width: NativeTrafficLights.width, height: NativeTrafficLights.height)
            }
            // 灯组与侧栏按钮分开:系统工具栏大约 16pt,不要和三盏灯挤成一排
            HeaderButton("sidebar.leading", help: "显示/隐藏侧栏 (⌃⌘S)") {
                store.toggleSidebar()
            }
            .padding(.leading, isFullScreen ? 0 : 16)
            Text("PureView")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.leading, 10)
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
        observeOwnerWindow()
        embedButtons()
        DispatchQueue.main.async { [weak self] in self?.embedButtons() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// 换显示器 / 换缩放时,AppKit 会重排 theme frame(标题栏容器的高度可能被还原,
    /// 标准按钮甚至会被塞回标题栏)。这条路上我们收不到任何"SwiftUI 该重新布局"的信号 ——
    /// 窗口尺寸没变,`layout()` 就不会触发。所以自己盯住窗口的换屏 / 换缩放通知,
    /// 收到就把坐标系重新对齐一遍。
    private func observeOwnerWindow() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(ownerWindowGeometryChanged),
                           name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(ownerWindowGeometryChanged),
                           name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    @objc private func ownerWindowGeometryChanged() {
        embedButtons()
        // 同步这一次常被 AppKit 随后的重排盖掉,下一轮 run loop 再补一遍
        DispatchQueue.main.async { [weak self] in self?.embedButtons() }
    }

    /// 视图被从窗口上摘掉之前,若正处于全屏就把红绿灯交还系统标题栏。
    ///
    /// **只在全屏时交还**。顶栏消失还有另一条常见路径 —— 进纯净模式(只看图)时整个
    /// `PureHeader` 被换掉 —— 那条路径**绝不能**交还:纯净模式下标题栏容器是"隐藏 + 0 高"的,
    /// 把按钮塞回去之后 AppKit 在随后的布局里会把容器高度还原,按钮就直接露在画面左上角了。
    /// 不交还时按钮随本视图一起离开层级、不会被绘制,退出纯净模式时新视图再把它们接管回来。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        guard let window = window ?? cachedWindow, window.styleMask.contains(.fullScreen) else { return }
        releaseButtons()
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

    /// 把窗口的三个标准按钮搬进本视图,并让**系统自己的布局**成为本视图的坐标系。
    ///
    /// ⚠️ **不要再直接写按钮的 frame。** 这三个是 AppKit 的托管视图:只要 theme frame 走一次
    /// 布局(改窗口尺寸、styleMask 抖动、换屏/换缩放……),AppKit 就会把它们的 frame 重新写成
    /// **原生数值**(实测 (7,6)/(27,6)/(47,6),14×16),只不过此时是在**本视图的坐标系里**解释。
    /// 而这条路上我们自己的 `layout()` 不会被调用 —— 本视图尺寸没变,AppKit 不会把它标脏 ——
    /// 于是按钮就永久停在原生位置上:纵向被顶高 `原生 y + 高/2 − 16/2`(实机截图里正好高 6pt),
    /// 横向间距变成原生 20 而不是"帧宽 14 + 8 = 22"(22 还会让第三个按钮越过 56pt 的槽被裁掉)。
    /// 这就是"红绿灯错位"的成因,而且它会随窗口事件反复出现。
    ///
    /// 所以这里**一个 frame 都不写**:只搬父视图,再平移本视图的 `bounds.origin`,让 AppKit
    /// 写回的原生 frame 正好落在我们要的位置。之后 AppKit 无论重排多少次,写回的都是同一批
    /// **绝对值**(实测与本视图的 bounds 无关,连做三轮重排值不变),对我们等于空操作。
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
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if button.superview !== self {
                // 只在第一次接管时记下原生容器;之后 button.superview 就是 self 了
                if originalContainer == nil { originalContainer = button.superview }
                button.removeFromSuperview()
                addSubview(button)
            }
            button.isHidden = false
        }
        alignToNativeLayout()
        applyGroupHover()
    }

    /// 以第一个按钮的**原生 frame** 为基准平移 `bounds.origin`:
    /// 横向让按钮组左缘贴住本视图左缘,纵向让按钮中心落在本视图的垂直中线上。
    ///
    /// 每次布局都重算 —— 换显示器时原生数值本身会变(标题栏高度不同),必须跟着走。
    /// 值不变时不写(赋值本身会触发一次重新合成,与 `ChromeView.stripTitlebar` 同一类开销)。
    private func alignToNativeLayout() {
        guard let first = window?.standardWindowButton(Self.buttonTypes[0]) else { return }
        let f = first.frame
        let wanted = NSRect(
            x: f.origin.x,
            y: f.origin.y + f.size.height / 2 - bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )
        if bounds != wanted { bounds = wanted }
    }

    /// 把接管过来的红绿灯还回标题栏容器,位置交回 AppKit 自己摆。
    ///
    /// **只有全屏才该交还**(那条自动隐藏的栏要显示应用名 + 红绿灯)。这里是唯一的交还出口,
    /// 所以把判断放在这里:非全屏一律不动手,免得把按钮摆进一个"隐藏 + 0 高"的标题栏里 ——
    /// AppKit 之后一旦还原容器高度,按钮就会赤条条地出现在画面左上角。
    private func releaseButtons() {
        guard let window = window ?? cachedWindow else { return }
        guard window.styleMask.contains(.fullScreen) else { return }
        guard Self.buttonTypes.contains(where: { window.standardWindowButton($0)?.superview === self }) else { return }
        // 找不到落点就**什么都别做**:先把按钮从自己身上摘下来、又没地方放,它们就成了
        // 没有父视图的孤儿 —— 全屏时一个红绿灯都不会有。宁可维持在旧位置。
        guard let host = originalContainer ?? Self.findTitlebar(in: window) else { return }
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type), button.superview === self else { continue }
            button.removeFromSuperview()
            // 刻意**不动** `isHidden`:按钮显隐的唯一归属是 ChromeView.stripTitlebar()
            // (它按 immersive 决定)。这里顺手点亮的话,纯净模式(标题栏容器只是被隐藏、
            // 高度可能被 AppKit 还原)下按钮就会露出来。
            host.addSubview(button)
        }
        // 交还后立刻催一次布局:光标 needsLayout 要等下一轮 run loop,
        // 全屏切换那一帧容易被人眼看到"按钮还堆在 (0,0)"。
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
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

