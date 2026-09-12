import SwiftUI
import AppKit

/// 左侧边栏:上半区项目文件夹树,下半区当前文件夹的缩略图网格
struct SidebarView: View {

    @Environment(FolderStore.self) private var store
    /// 侧栏明暗跟随画布背景偏好(而不是系统外观)
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue
    private var sidebarScheme: ColorScheme { ChromeTheme.colorScheme(for: canvasBackground) }
    @State private var expandedIDs: Set<FolderNode.ID> = []
    /// 缩略图区是否向上扩展(压缩文件夹树高度);再点一次复原。
    /// 打开/切换文件夹后默认展开,手动复原后不再被打断(直到下次切文件夹)
    @State private var thumbnailsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            folderTree
            if store.isSingleImageMode, store.pendingOtherCount > 0 {
                singleImagePrompt
            }
            if !store.roots.isEmpty {
                ThumbnailGridView(expanded: $thumbnailsExpanded)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: thumbnailsExpanded)
        .onChange(of: store.selectedFolderID) { _, _ in
            thumbnailsExpanded = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                SidebarMaterial(dark: canvasBackground.prefersDarkChrome)
                ChromeTheme.sidebarWash(for: canvasBackground)
            }
        }
        // 侧栏内文字/选中态/控件颜色跟随画布背景明暗
        .environment(\.colorScheme, sidebarScheme)
    }

    private var folderTree: some View {
        Group {
            if store.roots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("尚未打开文件夹")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectionBinding) {
                    ForEach(store.roots) { node in
                        FolderTreeRow(node: node, store: store, expandedIDs: $expandedIDs)
                            .tag(node.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(
            minHeight: 110,
            maxHeight: store.roots.isEmpty ? .infinity : (thumbnailsExpanded ? 110 : 340)
        )
    }

    private var selectionBinding: Binding<FolderNode.ID?> {
        Binding(
            get: { store.selectedFolderID },
            set: { newValue in
                guard let id = newValue, let node = store.node(id: id) else { return }
                store.selectFolder(node)
            }
        )
    }

    private var singleImagePrompt: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("同目录还有 \(store.pendingOtherCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            Button {
                store.loadAllFromCurrentFolder()
            } label: {
                Text("加载同目录所有图片")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Finder 同款侧栏材质(顶栏左侧与侧栏共用)
struct SidebarMaterial: NSViewRepresentable {
    /// 跟随画布背景明暗:黑色画布时用深色磨砂(vibrantDark)
    var dark: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        applyAppearance(to: view)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        applyAppearance(to: nsView)
    }

    private func applyAppearance(to view: NSVisualEffectView) {
        // 磨砂材质的明暗由外观决定;深色界面档位强制深色外观,得到深色磨砂
        view.appearance = NSAppearance(named: dark ? .vibrantDark : .aqua)
    }
}

/// 整窗的磨砂玻璃底衬。**只有画布背景选「磨砂」时才挂**
/// (挂载点见 `MainContentView.body`)。
///
/// `blendingMode = .behindWindow` 要求窗口本身非不透明 —— 这一点由
/// `ChromeView.stripTitlebar()` 保证(`window.isOpaque = false` + 背景色 `.clear`),
/// 侧栏的 `SidebarMaterial` 也依赖同一个前提。
///
/// 与侧栏那层的关系:两层都是向**窗口背后**取景(不是互相取景),所以不会叠加成双重模糊。
///
/// **不要再往上面叠提白层。** 试过一层半透明白(`Y' = Y·(1−k) + 255k`)想把这一档
/// 从"磨砂黑"提亮到中灰,实机看过被否决 —— 提白之后玻璃的层次感被压平,
/// 观感不如原样的系统材质。要动就动 `material` 档位本身。
struct GlassBackdrop: View {
    var canvas: CanvasBackground

    var body: some View {
        GlassMaterial(canvas: canvas)
    }
}

/// 玻璃的系统材质本身。`behindWindow` 会把窗口后面的桌面采进来 ——
/// **桌面是深色时它就是深的**,这是这一档偏暗的来源,刻意保留。
struct GlassMaterial: NSViewRepresentable {
    var canvas: CanvasBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // 整窗大面积底衬用 underWindowBackground;`.sidebar` 那档是给窄面板调的,铺满全窗偏重
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        applyAppearance(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        applyAppearance(to: nsView)
    }

    private func applyAppearance(to view: NSVisualEffectView) {
        let wanted = NSAppearance(named: canvas.prefersDarkChrome ? .vibrantDark : .aqua)
        // 判等再写:这是每次 SwiftUI 重渲染都会跑到的路径(P1-3 / afa642f 同一类问题)
        if view.appearance != wanted { view.appearance = wanted }
    }
}

enum ChromeTheme {
    /// 主区背景(欢迎页 / 画布浅色 #FAFAFB)
    static let mainAreaFill = Color(red: 0.980, green: 0.980, blue: 0.984)

    /// 侧栏洗色:浅色档给一层很淡的白,侧栏才比主区略"浮"起来一点。
    /// 深色档与磨砂档都不洗色 —— 磨砂档的侧栏与画布要呈现**同一层窗口玻璃**,叠色就对不上了。
    static func sidebarWash(for canvas: CanvasBackground) -> Color {
        canvas.prefersDarkChrome ? .clear : Color.white.opacity(0.10)
    }

    static func fill(_ canvas: CanvasBackground) -> Color {
        switch canvas {
        case .dark: Color(white: 0.10)
        case .light: mainAreaFill
        // 磨砂档:顶栏交出底色,由窗口背后的玻璃材质呈现(见 GlassBackdrop)
        case .frosted: Color.clear
        }
    }

    /// 编辑/浏览画布:比顶栏底栏略深,工作区才从界面里分出来。
    static func canvasFill(_ canvas: CanvasBackground) -> Color {
        switch canvas {
        case .dark: Color(white: 0.07)
        case .light: Color(red: 0.945, green: 0.945, blue: 0.950)
        case .frosted: Color.clear
        }
    }

    /// 编辑工具条与顶栏同一底色,只靠 hairline 分开,避免两层色块。
    static func editBarFill(_ canvas: CanvasBackground) -> Color {
        fill(canvas)
    }

    static func colorScheme(for canvas: CanvasBackground) -> ColorScheme {
        canvas.prefersDarkChrome ? .dark : .light
    }

    /// 顶栏与编辑条之间的淡实线(不透明,避免透出窗口)
    static func hairline(_ canvas: CanvasBackground) -> Color {
        canvas.prefersDarkChrome ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
}

/// 主区顶栏/底栏/欢迎页,跟画布纯色
struct MainChromeBackground: View {
    var canvas: CanvasBackground

    var body: some View {
        ChromeTheme.fill(canvas)
    }
}

/// 侧栏顶段(红绿灯列):与侧栏同材质,不跟主区顶栏
struct SidebarTopBackground: View {
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        ZStack {
            SidebarMaterial(dark: canvasBackground.prefersDarkChrome)
            ChromeTheme.sidebarWash(for: canvasBackground)
        }
    }
}

struct FolderTreeRow: View {

    let node: FolderNode
    let store: FolderStore
    @Binding var expandedIDs: Set<FolderNode.ID>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            ForEach(node.children) { child in
                FolderTreeRow(node: child, store: store, expandedIDs: $expandedIDs)
                    .tag(child.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: node.depth == 0 ? "folder.fill" : "folder")
                    .foregroundStyle(node.depth == 0 ? Color.accentColor : .secondary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contextMenu {
                Button("刷新") {
                    store.selectFolder(node)
                }
                if node.depth == 0 {
                    Button("从侧栏移除", role: .destructive) {
                        store.removeRoot(id: node.id)
                    }
                }
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(node.id) },
            set: { open in
                if open {
                    store.ensureChildren(of: node)
                    expandedIDs.insert(node.id)
                } else {
                    expandedIDs.remove(node.id)
                }
            }
        )
    }
}
