import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// MainContentView 将编辑工具栏提升到窗口顶栏;通过 preference 保留 EditView 对工具状态的唯一所有权。
struct EditToolbarPreferenceKey: PreferenceKey {
    static var defaultValue: AnyView? { nil }

    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        if let next = nextValue() { value = next }
    }
}

// 统一编辑器(预览.app 式工具条):裁切 / 文字 / 画笔 / 马赛克 / 橡皮。
// 画布按工具切换;导出走 CropService(变换 → 烙印 → 裁切 → 水印)。

struct EditView: View {

    let file: ImageFile
    let initialQuarterTurns: Int
    var initialTool: EditTool = .text
    var toolbarInHeader = false

    var onClose: () -> Void = {}

    init(file: ImageFile, initialQuarterTurns: Int, initialTool: EditTool = .text,
         toolbarInHeader: Bool = false,
         onClose: @escaping () -> Void = {}) {
        self.file = file
        self.initialQuarterTurns = initialQuarterTurns
        self.initialTool = initialTool
        self.toolbarInHeader = toolbarInHeader
        self.onClose = onClose
        _tool = State(initialValue: initialTool)
        _quarterTurns = State(initialValue: ((initialQuarterTurns % 4) + 4) % 4)
    }

    @Environment(FolderStore.self) var store
    @Environment(AnnotationStore.self) var annotationStore

    // 预览:base 为未变换的 1500px;transformedCG 为几何变换后未调色;display 为最终调色后
    @State var basePreview: CGImage?
    @State var unstraightenedCG: CGImage?
    @State var unstraightenedPreview: NSImage?
    @State var transformedCG: CGImage?
    @State var originalPreview: NSImage?
    @State var displayCG: CGImage?
    @State var displayPreview: NSImage?
    @State var overlayImage: NSImage?
    @State var previewFailed = false
    @State var overlayGeneration = 0
    @State var previewGeneration = 0
    @State var adjustGeneration = 0
    @State var adjustRebuildTask: Task<Void, Never>?
    @State var sourceFullPixelSize = CGSize.zero
    @State var transformedPixelSize = CGSize.zero

    // 变换与调色
    @State var quarterTurns = 0
    @State var flipH = false
    @State var flipV = false
    @State var straighten = 0.0
    @State var isStraightening = false
    @State var adjustments = ImageAdjustments()
    @State var showAdjustPopover = false
    @State var comparingOriginal = false

    // 裁切选区(默认整图,未进裁切工具时导出整张)
    @State var selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State var ratio: CropRatio = .free
    @State var showCropPopover = false
    /// 预设行方向。横 = 4:3/3:2/16:9/5:4,竖 = 3:4/2:3/9:16/4:5。
    @State var presetLandscape = true
    @State var customW = "4"
    @State var customH = "3"
    @FocusState var editingCustomRatio: Bool

    // 标记状态
    @State var annotations: [Annotation] = []
    @State var selectedID: UUID?
    @State var undoStack: [EditSnapshot] = []
    @State var redoStack: [EditSnapshot] = []
    @State var tool: EditTool = .text
    @State var markupColor: MarkupColor = .red
    @State var sizeLevel = 1
    @State var mosaicEffect: MosaicEffect = .pixelate
    /// 马赛克绘制方式:涂抹 / 框选
    @State var mosaicMode: MosaicDrawMode = .brush
    /// 文字半透明高对比度底衬开关
    @State var textHasBackground = false
    /// 正在双击编辑已有文字时的真实字号比例(避免角柄缩放过的文字双击编辑跳字号)
    @State var draftSizeFraction: CGFloat?
    /// 画笔样式:实线 / 荧光(同一画笔工具的两种笔,不是两个工具)
    @State var strokeStyle: StrokeStyleKind = .solid
    @State var shapeKind: ShapeKind = .rect
    @State var shapeFilled = false
    @State var detectingFaces = false
    @State var liveShapeTo: CGPoint?
    @State var moveStartFrom = CGPoint.zero
    @State var moveStartTo = CGPoint.zero
    @State var livePoints: [CGPoint] = []
    @State var erasedInGesture = false
    /// 橡皮悬停将要整笔删掉的对象。只高亮,不改选中。
    @State var eraserHoverID: UUID?
    @State var syncingControls = false
    @State var selectingExisting = false
    @State var grabOffset = CGSize.zero
    @State var dragStartPoint: CGPoint?
    /// 拖动起点的整笔点位:笔迹移动从手势起点算绝对位移,避免逐帧漂移
    @State var moveStartPoints: [CGPoint] = []
    /// 文字角柄改字号(B4):手势起点锚定比例,按对角距比值缩放
    @State var textResizing = false
    @State var resizeStartFraction: CGFloat = 0
    @State var resizeStartDistance: CGFloat = 0
    @State var shapeResizing: ShapeHandle?
    @State var reshapeStartFrom = CGPoint.zero
    @State var reshapeStartTo = CGPoint.zero
    /// 实时预览重绘节流(≥30ms 一帧):马赛克画线 / 移动 / 角柄缩放共用,尾帧补齐
    @State var lastMosaicRebuild = Date.distantPast
    @State var overlayRebuildTask: Task<Void, Never>?
    /// 右键菜单 action target 保活(NSMenuItem.target 不持有)
    @State var contextBoxes: [ContextActionBox] = []

    // 文字草稿
    @State var draftAnchor: CGPoint?
    @State var draftContent = ""
    @State var draftEditingID: UUID?
    @FocusState var draftFocused: Bool

    // 画布视口(缩放/平移,B1)
    @State var editZoom: CGFloat = 1
    @State var editPan: CGSize = .zero
    @State var canvasContainerSize: CGSize = .zero
    @State var lastPanTranslation: CGPoint = .zero

    // 导出
    @State var exporting = false
    /// 打印前要把编辑结果渲染成位图,和导出一样是重活。此标志用于在渲染期间禁用按钮,
    /// 防止连点弹出两个打印面板。
    @State var printPreparing = false
    /// 取消准备时递增,进行中的渲染结果直接丢掉。
    @State var printGeneration = 0
    @State var printError: String?
    @State var errorMessage: String?
    /// 「存储为」成功后的短提示。覆盖原图仍直接退出,不走这条。
    @State var exportNotice: String?
    @State var exportNoticeToken = 0
    @State var format: CropFormat = .png
    @State var exportResize: ExportResizePreset = .original
    @State var exportCustomLongestSide = "1600"
    @State var stripMetadata = false
    @State var estimatedExportSize: String? = nil
    @State var exportEstimateTask: Task<Void, Never>? = nil
    // 质量与 GPS 开关跨会话记忆。格式**不记**:`CropFormat.default(forSourceExt:)` 按源扩展名
    // 给的默认值(JPEG 进 JPEG 出)比一个全局记忆更有用,用记忆覆盖它是退步。
    @AppStorage(ExportQuality.storageKey) var quality = ExportQuality.defaultValue
    @AppStorage(ExportGPS.storageKey) var includeGPS = ExportGPS.defaultValue
    @State var watermarkDraft = WatermarkSettings()
    @State var showWatermarkSettings = false
    /// 工具属性面板是否展开。**不是系统 .popover**:那玩意是 transient 语义,在画布上
    /// 每按一次鼠标就关一次,而裁切的自然流程恰恰是「调参数 ↔ 拖选框」来回切。
    @State var showColorPopover = false
    @State var colorPanelListening = false
    /// 连续拖动系统色盘时合并 Undo 快照,避免 1 秒压入数十帧无效历史。
    @State var lastColorPanelUndoTime: TimeInterval = 0
    @State var tapCandidate = false
    @State var lastTapID: UUID?
    @State var lastTapTime = Date.distantPast
    @State var moveUndoPushed = false
    /// 窄窗口下工具选项收进弹层的开关
    @State var showCompactOptions = false
    @State var showExportPopover = false
    /// 导出按钮 hover 态。必须是持久化的 State:声明在 label 闭包里的 @State 不工作。
    @State var exportMenuHovering = false
    @State var holdingWindowLock = false
    @AppStorage(CanvasBackground.storageKey) var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        editorWithExportEstimate
            .overlay {
                if printPreparing {
                    VStack(spacing: 8) {
                        ProgressView("正在准备打印…")
                        Button("取消") {
                            printGeneration += 1
                            printPreparing = false
                        }
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background {
                        AdaptiveGlassSurface(
                            shape: RoundedRectangle(cornerRadius: 10),
                            legacyStroke: nil,
                            shadowOpacity: 0
                        )
                    }
                }
            }
            .alert("无法打印", isPresented: Binding(
                get: { printError != nil },
                set: { if !$0 { printError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(printError ?? "")
            }
            .alert("导出失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var editorWithExportEstimate: some View {
        editorWithStyleSync
            .onChange(of: showExportPopover) { _, shown in
                if shown { scheduleExportSizeEstimate() }
            }
            .onChange(of: format) { _, _ in if showExportPopover { scheduleExportSizeEstimate() } }
            .onChange(of: quality) { _, _ in if showExportPopover { scheduleExportSizeEstimate() } }
            .onChange(of: exportResize) { _, _ in if showExportPopover { scheduleExportSizeEstimate() } }
            .onChange(of: exportCustomLongestSide) { _, _ in if showExportPopover { scheduleExportSizeEstimate() } }
    }

    private var editorWithStyleSync: some View {
        editorBase
            .onChange(of: draftFocused) { _, focused in
                store.isTextDraftActive = focused
            }
            // 状态栏缩放控件(B1):与浏览模式同一入口
            .onChange(of: store.editZoomRequest?.token) { _, _ in
                guard let action = store.editZoomRequest?.action else { return }
                applyEditZoomAction(action)
            }
            .onChange(of: editZoom) { _, newZoom in
                store.editDisplayScale = newZoom
            }
            .onChange(of: selectedID) { _, id in
                store.editHasSelection = id != nil
                syncControlsFromSelection()
            }
            .onChange(of: draftEditingID) { _, _ in
                rebuildOverlay()
            }
            .onChange(of: watermarkDraft) { _, value in
                value.save()
            }
            .onChange(of: mosaicEffect) { _, effect in
                guard !syncingControls else { return }
                guard let id = selectedID,
                      let index = annotations.firstIndex(where: { $0.id == id }) else { return }
                switch annotations[index].kind {
                case let .mosaic(points, widthLevel, old) where old != effect:
                    pushUndo()
                    annotations[index].kind = .mosaic(points: points, widthLevel: widthLevel, effect: effect)
                case let .mosaicRect(from, to, widthLevel, old) where old != effect:
                    pushUndo()
                    annotations[index].kind = .mosaicRect(from: from, to: to, widthLevel: widthLevel, effect: effect)
                default:
                    break
                }
            }
            .onChange(of: textHasBackground) { _, hasBg in
                guard !syncingControls else { return }
                guard let id = selectedID,
                      let index = annotations.firstIndex(where: { $0.id == id }),
                      case let .text(anchor, content, sizeFraction, color, old) = annotations[index].kind,
                      old != hasBg else { return }
                pushUndo()
                annotations[index].kind = .text(anchor: anchor, content: content,
                                                sizeFraction: sizeFraction, color: color,
                                                hasBackground: hasBg)
            }
            .onChange(of: shapeFilled) { _, filled in
                guard !syncingControls else { return }
                guard let id = selectedID,
                      let index = annotations.firstIndex(where: { $0.id == id }),
                      case let .shape(kind, from, to, widthLevel, color, old) = annotations[index].kind,
                      (kind == .rect || kind == .ellipse),
                      old != filled else { return }
                pushUndo()
                annotations[index].kind = .shape(kind: kind, from: from, to: to,
                                                 widthLevel: widthLevel, color: color, filled: filled)
            }
    }

    private var editorBase: some View {
        VStack(spacing: 0) {
            if !toolbarInHeader { topBar }
            canvasArea
        }
        .preference(key: EditToolbarPreferenceKey.self,
                    value: toolbarInHeader ? AnyView(headerToolbarContent) : nil)
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
        .background(ChromeTheme.fill(canvasBackground))
        .background(WindowBackgroundMoveLock(allowMove: false))
        .onAppear {
            tool = initialTool
            restoreSession()
            watermarkDraft = WatermarkSettings.load()
            if !holdingWindowLock {
                holdingWindowLock = true
                WindowMoveControl.pushEditLock()
            }
        }
        .onDisappear {
            if draftAnchor != nil { commitDraft() }
            overlayRebuildTask?.cancel()
            adjustRebuildTask?.cancel()
            exportEstimateTask?.cancel()
            if holdingWindowLock {
                holdingWindowLock = false
                WindowMoveControl.popEditLock()
            }
            store.isTextDraftActive = false
            store.editDisplayScale = 1
            store.editHasSelection = false
            colorPanelListening = false
            lastColorPanelUndoTime = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            guard colorPanelListening else { return }
            let ns = NSColorPanel.shared.color
            let rgb = ns.usingColorSpace(.sRGB) ?? ns
            let now = ProcessInfo.processInfo.systemUptime
            let shouldPushUndo = (now - lastColorPanelUndoTime) > 0.8
            if shouldPushUndo { lastColorPanelUndoTime = now }
            applyColorToSelection(
                .custom(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent),
                recordUndo: shouldPushUndo
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow) === NSColorPanel.shared {
                colorPanelListening = false
                lastColorPanelUndoTime = 0
            }
        }
        .task { loadPreview() }
        .onExitCommand { handleEscape() }
        .onChange(of: store.editTool) { _, newTool in
            switchTool(newTool)
        }
        .onChange(of: annotations) { _, _ in
            persistSession()
            scheduleOverlayRebuild()
        }
        .onChange(of: selection) { _, _ in persistSession() }
        .onChange(of: quarterTurns) { _, _ in persistSession() }
        .onChange(of: flipH) { _, _ in persistSession() }
        .onChange(of: flipV) { _, _ in persistSession() }
        .onChange(of: straighten) { _, _ in persistSession() }
        .onChange(of: adjustments) { _, _ in
            persistSession()
            scheduleAdjustedPreview()
        }
        .onChange(of: livePoints) { _, _ in
            guard tool == .mosaic else { return }
            scheduleOverlayRebuild()
        }
        .onChange(of: liveShapeTo) { _, _ in
            guard tool == .mosaic, mosaicMode == .rect else { return }
            scheduleOverlayRebuild()
        }
    }

}
