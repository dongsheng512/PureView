import SwiftUI
import AppKit

extension EditView {

    // MARK: 子视图

    var topBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            headerCenterTools
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            headerRightActions
            closeButton
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            ZStack {
                // 与顶栏/画布同色:整窗一体。全屏下没有窗口顶栏,这条就是唯一的一条 bar,
                // 再靠色阶分层就会和画布之间多出一道横向接缝(与主顶栏同一口径)。
                ChromeTheme.fill(canvasBackground)
                hiddenShortcuts
            }
        }
    }

    /// 嵌入窗口主顶栏的精简工具组（方案A）：
    /// 顶栏只负责「工具切换 + 整图调整 + 撤销/导出」，当前工具的细节参数下沉到画布顶部悬浮胶囊，
    /// 彻底避免单层顶栏拥挤折叠，同时保留充足的窗口拖拽留白。
    var headerToolbarContent: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            headerCenterTools
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            headerRightActions
        }
        // 快捷键命令随工具栏一同提升到窗口顶栏,避免嵌入模式丢失 ⌘Z / Esc 等操作。
        .background(hiddenShortcuts)
    }

    /// 顶栏中段：分成「标注工具」与「整图调整(旋转/调色/水印)」两组轻胶囊，层次分明。
    var headerCenterTools: some View {
        HStack(spacing: 8) {
            toolCluster
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            HStack(spacing: 2) {
                transformMenu
                adjustButton
                watermarkButton
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
    }

    /// 顶栏右段：按住对比原图(有修改时) + 撤销/重做 | 导出；退出图标在顶栏最右由 PureHeader 提供。
    var headerRightActions: some View {
        HStack(spacing: 6) {
            if hasComparableEdits {
                compareOriginalButton
            }
            undoCluster
            HeaderDivider()
            exportMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 画布顶部居中悬浮的轻玻璃属性胶囊：只承载当前激活工具的参数，橡皮工具自动隐藏。
    var floatingToolOptionsBar: some View {
        HStack(spacing: 8) {
            inlineOptions
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            AdaptiveGlassSurface(
                shape: Capsule(),
                legacyStroke: AnyShapeStyle(Color.primary.opacity(0.10)),
                shadowOpacity: 0.12
            )
        }
    }

    var toolCluster: some View {
        HStack(spacing: 4) {
            ForEach(EditTool.allCases) { t in
                toolbarToolButton(t)
            }
        }
    }

    var transformCluster: some View {
        HStack(spacing: 6) {
            Divider().frame(height: 16)

            Button { rotate(cw: false) } label: {
                Image(systemName: "rotate.left").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("逆时针旋转 90°")
            Button { rotate(cw: true) } label: {
                Image(systemName: "rotate.right").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("顺时针旋转 90°")
            Button { toggleFlipH() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("水平翻转")
            Button { toggleFlipV() } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(previewFailed)
            .help("垂直翻转")
        }
    }

    @ViewBuilder
    var undoCluster: some View {
        // 撤销/重做都不可用时整组隐藏:避免刚进编辑时多出空占位。
        if !undoStack.isEmpty || !redoStack.isEmpty {
            HStack(spacing: 2) {
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(undoStack.isEmpty)
                .help("撤销 (⌘Z)")
                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(redoStack.isEmpty)
                .help("重做 (⇧⌘Z)")
            }
        }
    }

    var transformMenu: some View {
        Menu {
            Button { rotate(cw: false) } label: {
                Label("逆时针旋转 90°", systemImage: "rotate.left")
            }
            Button { rotate(cw: true) } label: {
                Label("顺时针旋转 90°", systemImage: "rotate.right")
            }
            Divider()
            Button { toggleFlipH() } label: {
                Label("水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            Button { toggleFlipV() } label: {
                Label("垂直翻转", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
        } label: {
            Image(systemName: "rotate.right")
                // 字号与 frame 必须和工具按钮完全一致:Menu label 不写 font 会落到默认
                // 13pt,行盒比 12pt 高,居中后图标会比其他按钮低半格。
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(previewFailed)
        .help("旋转与翻转")
    }

    var watermarkButton: some View {
        Button {
            showColorPopover = false
            showWatermarkSettings.toggle()
        } label: {
            Image(systemName: watermarkDraft.enabled && watermarkDraft.hasContent
                    ? "text.below.photo.fill" : "text.below.photo")
                .font(.system(size: 12))
                .foregroundStyle(watermarkDraft.enabled && watermarkDraft.hasContent
                                 ? Color.accentColor : Color.primary)
                // 高度跟工具按钮对齐(22 而非 24),否则在 HStack 里高出一截
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("水印(编辑导出时的默认)。画布实时预览,导出时烙进像素")
        .popover(isPresented: $showWatermarkSettings, arrowEdge: .bottom) {
            WatermarkSettingsForm(settings: $watermarkDraft)
        }
    }

    var hasComparableEdits: Bool {
        !adjustments.isIdentity || !annotations.isEmpty || liveWatermark.hasContent
    }

    var adjustButton: some View {
        Button {
            closeStyleMenus()
            showWatermarkSettings = false
            showAdjustPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.below.sun.max")
                .font(.system(size: 12))
                .foregroundStyle(adjustments.isIdentity ? Color.primary : Color.accentColor)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(previewFailed)
        .help("调色与自动增强")
        .popover(isPresented: $showAdjustPopover, arrowEdge: .bottom) {
            AdjustmentsForm(
                adjustments: $adjustments,
                onBeginEditing: { pushUndo() },
                onToggleAutoEnhance: {
                    pushUndo()
                    adjustments.autoEnhanced.toggle()
                },
                onReset: {
                    guard !adjustments.isIdentity else { return }
                    pushUndo()
                    adjustments = ImageAdjustments()
                }
            )
        }
    }

    var compareOriginalButton: some View {
        Image(systemName: comparingOriginal ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            .font(.system(size: 12))
            .foregroundStyle(comparingOriginal ? Color.accentColor : Color.primary)
            .frame(width: 26, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(comparingOriginal ? 0.14 : 0))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !comparingOriginal { comparingOriginal = true }
                    }
                    .onEnded { _ in
                        comparingOriginal = false
                    }
            )
            .help("按住对比原图")
            .accessibilityLabel("按住对比原图")
    }

    var closeButton: some View {
        Button { onClose() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("退出编辑 (Esc)")
    }

    struct ExportTooltipBackground: View {
        var body: some View {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Color(nsColor: .textBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    var exportMenu: some View {
        Menu {
            Button {
                closeStyleMenus()
                showWatermarkSettings = false
                copyEditedToPasteboard()
            } label: {
                Label("复制编辑结果", systemImage: "doc.on.doc")
            }
            .disabled(exporting || previewFailed)
            Divider()
            Button {
                closeStyleMenus()
                showWatermarkSettings = false
                showExportPopover = true
            } label: {
                Label("存储为…", systemImage: "square.and.arrow.down")
            }
            if overwriteFormat != nil {
                Button(role: .destructive) {
                    closeStyleMenus()
                    showWatermarkSettings = false
                    export(overwrite: true)
                } label: {
                    Label("覆盖原图", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(exporting || previewFailed)
            }
            Divider()
            // 打印当前编辑结果。与 ⌘P 分开:⌘P 印的是磁盘原图,这里印的是裁切/水印/标注之后的。
            Button {
                printEdited()
            } label: {
                Label("打印…", systemImage: "printer")
            }
            .disabled(exporting || printPreparing || previewFailed)
        }
        label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 12))
                .foregroundStyle(exportReady ? .primary : .secondary)
                .frame(width: 24, height: 20)
                .background {
                    AdaptiveButtonFill(
                        emphasized: false,
                        hovering: exportMenuHovering,
                        disabled: !exportReady,
                        cornerRadius: 4
                    )
                }
                .contentShape(Rectangle())
                .onHover { exportMenuHovering = $0 }
                .accessibilityLabel("导出")
        }
        // 纯按钮外观,点击任意处弹菜单(隐藏系统箭头指示器)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(alignment: .topTrailing) {
            // 挂在 Menu 外层,右对齐。按钮贴着工具条右缘,居中气泡会被裁掉。
            if exportMenuHovering, exportReady {
                Text("导出")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ExportTooltipBackground())
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .fixedSize()
                    .offset(y: 34)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: exportMenuHovering)
        .disabled(exporting || displayPreview == nil || previewFailed)
        .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
            ExportOptionsForm(
                format: $format,
                quality: $quality,
                resizePreset: $exportResize,
                customLongestSide: $exportCustomLongestSide,
                includeGPS: $includeGPS,
                stripMetadata: $stripMetadata,
                watermark: $watermarkDraft,
                sourcePixelSize: fullResCropPixelSize,
                estimatedSizeText: estimatedExportSize,
                exporting: exporting,
                onExport: {
                    showExportPopover = false
                    export(overwrite: false)
                },
                onWatermarkSettings: { showWatermarkSettings = true }
            )
        }
    }

    /// 当前工具的属性选项,内联在工具条上(替代原先的下拉浮层):
    /// 调外观从「开面板→点」变一步,颜色与大小同处,切工具零布局跳动。
    @ViewBuilder
    var inlineOptions: some View {
        switch tool {
        case .crop:
            cropFloatingOptions
        case .eraser:
            EmptyView()
        case .text: textOptions
        case .step: stepOptions
        case .brush: brushOptions
        case .mosaic: mosaicOptions
        case .shape: shapeOptions
        }
    }

    /// 裁切悬浮条：左侧比例菜单入口 + 右侧直接拉直滑块，不用再开弹层即可实时拉直。
    var cropFloatingOptions: some View {
        HStack(spacing: 8) {
            cropOptionsButton
            Divider().frame(height: 12)
            HStack(spacing: 6) {
                Text("拉直")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $straighten, in: -45...45, onEditingChanged: { editing in
                    if editing {
                        pushUndo()
                        isStraightening = true
                    } else {
                        rebuildTransformedPreview(finishStraightening: true)
                    }
                })
                .controlSize(.small)
                .frame(width: 96)
                .disabled(previewFailed)
                Text("\(straighten, specifier: "%.0f")°")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
                if abs(straighten) >= 0.1 {
                    Button("归零") {
                        pushUndo()
                        straighten = 0
                        isStraightening = false
                        rebuildTransformedPreview()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(previewFailed)
                }
            }
        }
    }

    var cropOptionsButton: some View {
        Button {
            showCropPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11, weight: .medium))
                Text(ratio == .custom ? "\(customW):\(customH)" : ratio.rawValue)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(height: 22)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("裁切比例与拉直")
        .popover(isPresented: $showCropPopover, arrowEdge: .bottom) {
            cropMenu
        }
    }

    var textOptions: some View {
        HStack(spacing: 8) {
            colorToolbarButton
            levelChips
            Divider().frame(height: 12)
            TextChip(text: "底衬", selected: textHasBackground) {
                textHasBackground.toggle()
            }
            .help("为文字添加高对比度半透明圆角底衬")
        }
    }

    var stepOptions: some View {
        HStack(spacing: 8) {
            colorToolbarButton
            levelChips
            Divider().frame(height: 12)
            Text("#\(nextStepNumber)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .help("点击画布放置下一个序号气泡")
        }
    }

    var brushOptions: some View {
        HStack(spacing: 8) {
            colorToolbarButton
            styleChips(labels: StrokeStyleKind.allCases.map(\.label),
                       selected: StrokeStyleKind.allCases.firstIndex(of: strokeStyle) ?? 0) {
                applyStrokeStyleToSelection(StrokeStyleKind.allCases[$0])
            }
            levelChips
        }
    }

    var mosaicOptions: some View {
        HStack(spacing: 8) {
            styleChips(labels: MosaicEffect.allCases.map(\.label),
                       selected: MosaicEffect.allCases.firstIndex(of: mosaicEffect) ?? 0) {
                mosaicEffect = MosaicEffect.allCases[$0]
            }
            Divider().frame(height: 12)
            styleChips(labels: MosaicDrawMode.allCases.map(\.label),
                       selected: MosaicDrawMode.allCases.firstIndex(of: mosaicMode) ?? 0) {
                mosaicMode = MosaicDrawMode.allCases[$0]
            }
            Divider().frame(height: 12)
            levelChips
            Divider().frame(height: 12)
            Button {
                detectAndMosaicFaces()
            } label: {
                HStack(spacing: 3) {
                    if detectingFaces {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "faceid")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text("人脸")
                        .font(.system(size: 11))
                }
                .frame(height: 20)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detectingFaces || previewFailed)
            .help("自动识别人脸并一键生成马赛克框")
        }
    }

    var shapeOptions: some View {
        HStack(spacing: 8) {
            colorToolbarButton
            shapeChips
            levelChips
            if shapeKind == .rect || shapeKind == .ellipse {
                Divider().frame(height: 12)
                TextChip(text: "填充", selected: shapeFilled) {
                    shapeFilled.toggle()
                }
                .help("为矩形或椭圆添加半透明填充高亮")
            }
        }
    }

    func styleChips(labels: [String], selected: Int,
                            onPick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(labels.indices, id: \.self) { i in
                TextChip(text: labels[i], selected: selected == i, action: { onPick(i) })
            }
        }
        .disabled(previewFailed)
    }

    /// 形状种类内联在工具条上(图标档),不再放浮层网格。
    var shapeChips: some View {
        HStack(spacing: 3) {
            ForEach(ShapeKind.pickerOrder) { kind in
                SymbolChip(symbol: kind.systemImage, selected: shapeKind == kind) {
                    shapeKind = kind
                }
            }
        }
    }

    /// 小/中/大档位(字号/粗细/强度共用一个状态)。
    var levelChips: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                TextChip(text: ["小", "中", "大"][i], selected: sizeLevel == i) {
                    sizeLevel = i
                    applySizeLevelToSelection()
                }
            }
        }
        .disabled(previewFailed)
    }

    func toolbarToolButton(_ t: EditTool) -> some View {
        let isShape = t == .shape
        let active = tool == t
        return Button {
            selectToolbarTool(t)
        } label: {
            Image(systemName: isShape ? shapeKind.systemImage : t.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 22)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t == .shape ? shapeKind.label : t.label)
        .accessibilityLabel(t == .shape ? shapeKind.label : t.label)
    }

    func selectToolbarTool(_ t: EditTool) {
        showColorPopover = false
        switchTool(t)
    }

    var usesMarkupColor: Bool {
        tool == .text || tool == .brush || tool == .shape
    }

    var colorToolbarButton: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: MarkPalette.nsColor(markupColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("颜色")
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
            colorPopover
        }
    }

    var colorPopover: some View {
        let swatch: CGFloat = 16
        let gap: CGFloat = 8
        let inset: CGFloat = 12
        return VStack(spacing: inset) {
            VStack(spacing: gap) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<6, id: \.self) { col in
                            let i = row * 6 + col
                            Button {
                                applyColorToSelection(.palette(i))
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: MarkPalette.color(i)))
                                    .frame(width: swatch, height: swatch)
                                    .overlay(
                                        Circle().strokeBorder(
                                            markupColor == .palette(i) ? Color.accentColor : Color.secondary.opacity(0.35),
                                            lineWidth: markupColor == .palette(i) ? 2 : 0.5
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    showColorPopover = false
                    pickColorWithEyedropper()
                } label: {
                    Label("吸管", systemImage: "eyedropper")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("使用系统放大镜从屏幕任意位置取色")

                Button {
                    showColorPopover = false
                    openSystemColorPanel()
                } label: {
                    Label("调色盘", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(inset)
    }

    /// macOS 原生系统级放大镜吸管取色(NSColorSampler)
    func pickColorWithEyedropper() {
        let sampler = NSColorSampler()
        sampler.show { selected in
            guard let selected, let rgb = selected.usingColorSpace(.sRGB) else { return }
            let color = MarkupColor.custom(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
            Task { @MainActor in
                applyColorToSelection(color)
            }
        }
    }

    func openSystemColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = MarkPalette.nsColor(markupColor)
        panel.showsAlpha = false
        panel.isContinuous = true
        colorPanelListening = true
        lastColorPanelUndoTime = 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// 裁切弹层:比例 3 列网格全部可见(横向滚动会藏选项),拉直用面板全宽。
    var cropMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("比例").font(.caption).foregroundStyle(.secondary)
            }
            // 模式三档 + 方向开关。同一槽位永远是当前方向的比值,竖版不另记一颗按钮。
            HStack(spacing: 4) {
                cropChip(.free)
                cropChip(.original)
                cropChip(.custom)
            }
            HStack(spacing: 4) {
                directionToggleChip
                // 预设组:同一批位置,按方向映射到横版/竖版 case
                ForEach(presetSlots, id: \.0) { slot in
                    cropChip(presetLandscape ? slot.1 : slot.1.flipped, mono: true)
                }
            }
            if ratio == .custom { customRatioFields }
            HStack(spacing: 6) {
                Text("拉直").font(.caption).foregroundStyle(.secondary)
                Slider(value: $straighten, in: -45...45, onEditingChanged: { editing in
                    if editing {
                        pushUndo()
                        isStraightening = true
                    } else {
                        rebuildTransformedPreview(finishStraightening: true)
                    }
                })
                .controlSize(.small)
                .disabled(previewFailed)
                Text("\(straighten, specifier: "%.0f")°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Button("归零") {
                    pushUndo()
                    straighten = 0
                    isStraightening = false
                    rebuildTransformedPreview()
                }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .disabled(straighten == 0 || previewFailed)
            }
        }
        .padding(10)
        // 方向开关 + 5 个预设挤一行,250pt 时预设被压得太窄,加宽到 280。
        .frame(width: 280)
    }

    /// 方向切换:数字预设翻到对向 case;自定义没有对向 case,交换宽高字段。
    /// 两种都走 snapToRatio,固定 84% 居中,避免在旧选区内越切越小。
    func toggleDirection() {
        if ratio == .custom {
            swap(&customW, &customH)
            presetLandscape.toggle()
            snapToRatio()
            return
        }
        guard let flipped = ratio.flippedAsPreset(from: presetLandscape, to: !presetLandscape) else {
            presetLandscape.toggle()
            return
        }
        pickRatio(flipped)
        presetLandscape.toggle()
    }

    var directionToggleChip: some View {
        Button {
            toggleDirection()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: presetLandscape
                      ? "rectangle.landscape.rotate"
                      : "rectangle.portrait.rotate")
                    .font(.system(size: 10, weight: .medium))
                Text(presetLandscape ? "横" : "竖").font(.system(size: 11))
            }
            .frame(minWidth: 34, minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("切换横竖方向")
    }

    /// (槽位 ID, 横版 case)。竖版 = 横版.flipped,同一槽位语义稳定(第 2 槽永远是 4:3/3:4 家族)。
    /// ID 必须唯一 —— 空字符串会让 ForEach 把五个槽合并成一个,全部渲染成 1:1。
    var presetSlots: [(String, CropRatio)] {
        [("sq", .square), ("43", .fourBy3), ("32", .threeBy2), ("169", .sixteenBy9), ("54", .fiveBy4)]
    }

    func cropChip(_ r: CropRatio, mono: Bool = false) -> some View {
        Button { pickRatio(r) } label: {
            Text(r.rawValue)
                .font(mono ? .system(size: 11).monospacedDigit() : .system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(ratio == r ? 0.16 : 0.05))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func pickRatio(_ r: CropRatio) {
        guard ratio != r else { return }
        ratio = r
        if r != .free { snapToRatio() }
    }

    var customRatioFields: some View {
        HStack(spacing: 4) {
            TextField("宽", text: $customW)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .focused($editingCustomRatio)
                .onSubmit { snapToRatio() }
            Text(":").foregroundStyle(.secondary)
            TextField("高", text: $customH)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .focused($editingCustomRatio)
                .onSubmit { snapToRatio() }
        }
    }

    func closeStyleMenus() {
        showColorPopover = false
        showCompactOptions = false
        showCropPopover = false
        showExportPopover = false
        showAdjustPopover = false
    }

    var canvasArea: some View {
        ZStack {
            // 与顶栏/底栏同色:整窗一体,不再有一道横向色阶接缝。
            // 图片与背景的分界交给画布上那圈 imageBorder 描边。
            ChromeTheme.fill(canvasBackground)
            if let displayPreview, transformedPixelSize.width > 0 {
                let effectiveOverlay = comparingOriginal ? nil : overlayImage
                let effectiveWatermark = comparingOriginal ? WatermarkSettings() : liveWatermark
                if tool == .crop {
                    let cropImage: NSImage = {
                        if comparingOriginal, let originalPreview { return originalPreview }
                        if isStraightening, let unstraightenedPreview { return unstraightenedPreview }
                        return displayPreview
                    }()
                    ZStack {
                        CropCanvas(
                            image: cropImage,
                            selection: $selection,
                            lockAspect: lockAspect,
                            previewAspect: cropImage.size.width / max(1, cropImage.size.height),
                            onInteractionStart: beginUndoGroup,
                            overlay: effectiveOverlay,
                            watermark: effectiveWatermark,
                            // 尺寸读数搬到画布:它本质是「画布上的信息」,贴在选框角实时看得见
                            outputSize: transformedPixelSize.width > 0 ? pixelRect.size : .zero,
                            contextMenuProvider: { _ in cropContextMenu() },
                            annotationHitTest: { point in
                                hitTest(at: point, kinds: [.text, .step, .brush, .mosaic, .shape])
                            },
                            annotations: annotations,
                            selectedAnnotationID: selectedID,
                            onSelectAnnotation: { id in
                                if let id { selectedID = id } else { selectNone() }
                            },
                            onEditText: { id in
                                switchTool(.text)
                                beginEdit(id: id)
                            },
                            imageBorder: ChromeTheme.imageBorder(canvasBackground),
                            liveStraightenDegrees: straighten,
                            isStraightening: !comparingOriginal && isStraightening
                        )
                    }
                } else {
                    let markupImage = (comparingOriginal ? originalPreview : nil) ?? displayPreview
                    MarkupCanvas(
                        image: markupImage,
                        overlay: effectiveOverlay,
                        annotations: annotations,
                        selectedID: selectedID,
                        tool: tool,
                        markupColor: markupColor,
                        sizeLevel: sizeLevel,
                        mosaicEffect: mosaicEffect,
                        mosaicMode: mosaicMode,
                        strokeStyle: strokeStyle,
                        shapeKind: shapeKind,
                        shapeFilled: shapeFilled,
                        livePoints: livePoints,
                        liveShapeFrom: (tool == .shape || (tool == .mosaic && mosaicMode == .rect)) ? dragStartPoint : nil,
                        liveShapeTo: liveShapeTo,
                        onTextResizeStart: handleTextResizeStart,
                        onTextResizeChange: handleTextResizeChange,
                        onTextResizeEnd: handleTextResizeEnd,
                        onShapeHandleStart: handleShapeResizeStart,
                        onShapeHandleChange: handleShapeResizeChange,
                        onShapeHandleEnd: handleShapeResizeEnd,
                        draftAnchor: draftAnchor,
                        draftContent: $draftContent,
                        draftEditingID: draftEditingID,
                        draftSizeFraction: draftSizeFraction,
                        draftFocused: $draftFocused,
                        onDragStart: handleDragStart,
                        onTextDoubleClick: { point in
                            guard let id = hitTest(at: point, kinds: [.text]) else { return false }
                            beginEdit(id: id)
                            return true
                        },
                        onDragChange: handleDragChange,
                        onDragEnd: handleDragEnd,
                        onDraftSubmit: { commitDraft() },
                        onCancel: handleEscape,
                        selection: selection,
                        watermark: effectiveWatermark,
                        zoom: editZoom,
                        pan: editPan,
                        hoverID: tool == .eraser ? eraserHoverID : nil,
                        hoverTest: tool == .crop ? nil : { (point: CGPoint) in
                            hitTest(at: point, kinds: [.text, .step, .brush, .mosaic, .shape]) != nil
                        },
                        onCanvasHover: { point in
                            guard tool == .eraser else {
                                if eraserHoverID != nil { eraserHoverID = nil }
                                return
                            }
                            guard let point else {
                                eraserHoverID = nil
                                return
                            }
                            let hit = hitTest(at: point, kinds: [.text, .step, .brush, .mosaic, .shape])
                            if hit != eraserHoverID { eraserHoverID = hit }
                        },
                        baseCursor: tool == .text ? .iBeam : .crosshair,
                        contextMenuProvider: tool == .crop ? nil : { (point: CGPoint) in contextMenu(at: point) },
                        onScrollGesture: handleCanvasScroll,
                        onMagnifyGesture: handleCanvasMagnify,
                        onPanGesture: handleCanvasPan,
                        onPanGestureEnd: { lastPanTranslation = .zero },
                        onContainerChange: handleCanvasResize,
                        imageBorder: ChromeTheme.imageBorder(canvasBackground)
                    )
                }
            } else if previewFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("无法载入此图的像素数据")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("正在载入原图…")
            }

        }
        .frame(maxHeight: .infinity)
        // 缩放后图片不允许溢出画布区盖住顶栏/底栏
        .clipped()
        .overlay(alignment: .top) {
            if comparingOriginal {
                Text("原图")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if displayPreview != nil, !previewFailed, tool != .eraser {
                floatingToolOptionsBar
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.14), value: comparingOriginal)
        .animation(.easeInOut(duration: 0.14), value: tool)
        .overlay(alignment: .bottom) {
            if let exportNotice {
                Text(exportNotice)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: exportNotice)
    }

    /// 切工具保留选中(对齐预览.app);清草稿、弹层与全部手势残状态。
    func switchTool(_ t: EditTool) {
        guard t != tool else { return }
        cancelDraft()
        closeStyleMenus()
        moveUndoPushed = false
        selectingExisting = false
        grabOffset = .zero
        dragStartPoint = nil
        moveStartPoints = []
        livePoints = []
        liveShapeTo = nil
        erasedInGesture = false
        eraserHoverID = nil
        tapCandidate = false
        textResizing = false
        shapeResizing = nil
        lastPanTranslation = .zero
        tool = t
        // 回写给菜单 C/D 门禁与状态栏(顶栏切换不走 beginEdit 通道)
        store.editTool = t
    }

    /// ⌘Z/⇧⌘Z/⌫/Esc/S/[ ]/⌘C/⌘V。草稿聚焦时让位给文本编辑。
    var hiddenShortcuts: some View {
        Group {
            Button { undo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(draftFocused)
            Button { redo() } label: { EmptyView() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(draftFocused)
            Button { deleteSelected() } label: { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(draftFocused)
            Button { handleEscape() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
            Button { switchTool(.text) } label: { EmptyView() }
                .keyboardShortcut("t", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.step) } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.brush) } label: { EmptyView() }
                .keyboardShortcut("b", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.mosaic) } label: { EmptyView() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.crop) } label: { EmptyView() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.eraser) } label: { EmptyView() }
                .keyboardShortcut("e", modifiers: [])
                .disabled(draftFocused)
            Button { switchTool(.shape) } label: { EmptyView() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(draftFocused)
            Button { stepSizeLevel(-1) } label: { EmptyView() }
                .keyboardShortcut("[", modifiers: [])
                .disabled(draftFocused)
            Button { stepSizeLevel(1) } label: { EmptyView() }
                .keyboardShortcut("]", modifiers: [])
                .disabled(draftFocused)
            Button { copySelectedAnnotation() } label: { EmptyView() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(draftFocused || selectedID == nil)
            Button { pasteAnnotation() } label: { EmptyView() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(draftFocused || annotationStore.clipboard == nil)
            // ⌘⏎ 直达导出选项面板(融合后的菜单按钮不再有主操作区)
            Button { showExportPopover = true } label: { EmptyView() }
                .keyboardShortcut(.defaultAction)
                .disabled(draftFocused || exporting || displayPreview == nil || previewFailed)
            Button { resetCanvasViewport() } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(draftFocused)
            Button { stepCanvasZoom(1.25) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(draftFocused)
            Button { stepCanvasZoom(1 / 1.25) } label: { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(draftFocused)
            Button { nudge(dx: -1, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { nudge(dx: 1, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button { nudge(dx: 0, dy: -1) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button { nudge(dx: 0, dy: 1) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button { nudge(dx: -4, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button { nudge(dx: 4, dy: 0) } label: { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button { nudge(dx: 0, dy: -4) } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: .shift)
            Button { nudge(dx: 0, dy: 4) } label: { EmptyView() }
                .keyboardShortcut(.downArrow, modifiers: .shift)
        }
        .disabled(editingCustomRatio)
        .opacity(0)
        .accessibilityHidden(true)
    }

}
