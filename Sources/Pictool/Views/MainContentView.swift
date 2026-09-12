import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面:纯 SwiftUI——hiddenTitleBar 无系统 header,
/// NavigationSplitView(侧栏 + 详情)+ 自定义 Overlay header + 信息面板 + 状态栏
struct MainContentView: View {

    @Environment(FolderStore.self) private var store
    /// 只用于给纯净模式右上角的图标挑"反色描边"(见 `exitGlyphHalo`)
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPreparingPrint = false
    // 拼版打印:选项弹层 + 解码期间的门禁(与 isPreparingPrint 分开,
    // 因为它还要在弹层里禁按钮)
    @State private var showContactSheetOptions = false
    @State private var contactSheetOptions = ContactSheetOptions()
    @State private var contactSheetPreparing = false
    @State private var showZoomMenu = false
    @State private var isDropTargeted = false
    @State private var sidebarWidth: CGFloat = UserDefaults.standard.double(forKey: "sidebarWidth") > 0 ? UserDefaults.standard.double(forKey: "sidebarWidth") : 260
    @State private var dragStartWidth: CGFloat = 260
    @State private var isHoveringDivider = false
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue
    @AppStorage(OpenZoomMode.storageKey) private var openZoomMode = OpenZoomMode.defaultValue
    @AppStorage(WrapNavigation.storageKey) private var wrapNavigation = WrapNavigation.defaultValue
    @AppStorage(ImageSortKey.storageKey) private var sortKey = ImageSortKey.defaultValue
    @AppStorage(ImageSortDirection.storageKey) private var sortDirection = ImageSortDirection.defaultValue
    @AppStorage(SlideShowInterval.storageKey) private var slideshowInterval = SlideShowInterval.defaultValue
    // 幻灯片控制条:**只在幻灯片会话里存在**。会话开始浮现一次,静止 2.5 秒淡出,
    // 悬停在它上面时保持;不播放时鼠标扫过底边一概不弹(纯净模式就该是一张图)。
    @State private var slideshowHUDVisible = false
    @State private var isHoveringSlideshowHUD = false
    @State private var slideshowHoverGeneration = 0
    @State private var lastHoverLocation: CGPoint?
    /// 纯净模式期间常驻的本地 mouseMoved 监视器,喂两处边缘热区(右上角退出按钮 / 底边控制条)
    @State private var hoverMonitor: Any?
    // 纯净模式的退出按钮(甲+丙):进模式先满不透明 3 秒让人看见,再淡成"幽灵";
    // 鼠标进右上角热区恢复满不透明,离开 2.5 秒淡回去 —— 与底部 HUD 同一套节拍。
    @State private var exitAffordanceVisible = false
    @State private var exitAffordanceInZone = false
    @State private var exitFadeGeneration = 0

    private var sortPreference: ImageSortPreference {
        ImageSortPreference(key: sortKey, direction: sortDirection)
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.isImmersive {
                immersiveLayer
            } else {
                normalLayer
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowChrome(immersive: store.isImmersive, allowBackgroundMove: !store.isEditing))
        .onAppear {
            CanvasBackground.normalizeStoredValue()
            runZoomSelfTestIfRequested()
            dragStartWidth = sidebarWidth
            store.wrapNavigation = wrapNavigation
            store.slideshowInterval = slideshowInterval
            store.applySortPreference(sortPreference)
            contactSheetOptions = ContactSheetOptions.loadFromDefaults()
        }
        .onChange(of: slideshowInterval) { _, value in
            store.slideshowInterval = value
            store.slideshowIntervalChanged()
        }
        .onChange(of: store.isImmersive) { _, immersive in
            // 纯净模式全程挂本地事件监视器:右上角退出按钮的热区靠它
            updateHoverMonitor(active: immersive)
            if !immersive {
                withAnimation(.easeInOut(duration: 0.2)) { slideshowHUDVisible = false }
            }
        }
        // 底部控制条只在**幻灯片会话**里存在:会话开始浮现一次,会话结束立刻收起。
        // 不播放时鼠标扫过底边一概不弹 —— 纯净模式就该是一张图。
        .onChange(of: store.isSlideshowActive) { _, active in
            if active {
                showSlideshowHUD()
            } else {
                slideshowHoverGeneration += 1
                withAnimation(.easeInOut(duration: 0.2)) { slideshowHUDVisible = false }
            }
        }
        .onChange(of: wrapNavigation) { _, value in
            store.wrapNavigation = value
        }
        .onChange(of: sortKey) { _, _ in
            store.applySortPreference(sortPreference)
        }
        .onChange(of: sortDirection) { _, _ in
            store.applySortPreference(sortPreference)
        }
        .onChange(of: store.contactSheetRequestToken) { _, _ in
            presentContactSheetOptions()
        }
        .sheet(isPresented: $showContactSheetOptions) {
            contactSheetSheet
        }
        .onOpenURL { url in handleExternal(url) }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            ZStack {
                if isPreparingPrint {
                    ProgressView("正在准备打印…")
                        .padding(14)
                        // 加深色画布上也要能看清,给进度条一层材质底
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        // 拖入高亮:此前 isTargeted 传的是 nil,用户拖着文件进来没有任何反馈
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.isImmersive {
                exitAffordance
                    .padding(12)
                    .onAppear { showExitAffordance(fadeAfter: 3) }
            }
        }
        .onExitCommand {
            if store.isImmersive { store.toggleImmersive() }
        }
    }

    // MARK: - 纯净模式单独显示层：只显示图片，无任何 chrome
    private var immersiveLayer: some View {
        ZStack {
            ImageViewCanvas(
                file: store.currentImage,
                neighborURLs: store.neighborURLs,
                background: canvasBackground,
                openZoomMode: openZoomMode,
                zoomRequest: store.zoomRequest,
                rotationCount: store.rotationCount,
                stepDirection: store.lastStepDirection,
                onLoadingChange: { store.imageLoading = $0 },
                onScaleChange: { store.displayScale = $0 },
                onImageInfo: { store.displayInfo = $0 },
                onRotationChange: { store.isDisplayRotated = $0 },
                onStep: { store.step($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if slideshowHUDVisible {
                SlideshowHUD(
                    playing: store.isSlideshowActive && !store.isSlideshowPaused,
                    canPlay: store.visibleImages.count >= 2 && store.currentImage != nil,
                    positionText: "\(max(store.visibleIndex, 0) + 1) / \(store.visibleImages.count)",
                    intervalLabel: store.slideshowInterval.label,
                    onPrev: { store.step(-1) },
                    onToggle: { store.toggleSlideshow() },
                    onNext: { store.step(1) },
                    onCycleInterval: { slideshowInterval = store.slideshowInterval.next },
                    // 控制条只在幻灯片会话里存在,所以 X 的含义很确定 = 结束会话
                    // (并随之退出纯净模式)。原先那个 `: store.toggleImmersive()` 分支是给
                    // "未开播也在底边浮现"的用法兜底的,那条路径已经取消,分支也就没了意义。
                    onExit: { store.endSlideshow() }
                )
                .onHover { hovering in
                    isHoveringSlideshowHUD = hovering
                    // 进入 HUD 时 showSlideshowHUD 里的 generation 作废旧计时,
                    // 离开时重新起一个淡出计时,HUD 保持可见
                    if hovering { showSlideshowHUD() }
                }
                .transition(.opacity)
                .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: slideshowHUDVisible)
        .ignoresSafeArea()
    }

    // MARK: 边缘热区(本地事件监视器,不受画布 NSView 吞掉 mouseMoved 影响)
    //
    // 两处热区共用这一个监视器:右上角 120×64 → 退出按钮回满不透明;
    // 底边 160pt → 幻灯片控制条(只在幻灯片会话里)。

    private func showSlideshowHUD() {
        slideshowHoverGeneration += 1
        let gen = slideshowHoverGeneration
        withAnimation(.easeInOut(duration: 0.2)) { slideshowHUDVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard gen == slideshowHoverGeneration, !isHoveringSlideshowHUD else { return }
            withAnimation(.easeInOut(duration: 0.2)) { slideshowHUDVisible = false }
        }
    }

    private func updateHoverMonitor(active: Bool) {
        if active, hoverMonitor == nil {
            hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                noteMouseActivity()
                return event
            }
        } else if !active, let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
            lastHoverLocation = nil
            exitAffordanceInZone = false
        }
    }

    private func noteMouseActivity() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        // 甲+丙:右上角 120×64 热区。进区恢复满不透明,出区 2.5 秒淡回幽灵态。
        // 只在"跨过区界"那一帧动状态,免得每次 mouseMoved 都重启动画。
        let inExitZone = mouse.x > frame.maxX - 120 && mouse.y > frame.maxY - 64
        if inExitZone != exitAffordanceInZone {
            exitAffordanceInZone = inExitZone
            showExitAffordance(fadeAfter: inExitZone ? nil : 2.5)
        }
        // 底边 160pt 热区。**只有幻灯片会话里才浮现** —— 不播放时纯净模式不该有任何浮层,
        // 而控制条在会话开始时已经弹过一次,没必要靠鼠标扫过底边再把它叫回来。
        guard store.isSlideshowActive else { return }
        guard mouse.y - frame.minY < 160 else { return }
        if let last = lastHoverLocation,
           abs(mouse.x - last.x) < 6, abs(mouse.y - last.y) < 6 { return }
        lastHoverLocation = mouse
        showSlideshowHUD()
    }

    // MARK: 纯净模式的退出按钮显隐(甲+丙)

    /// 静止态图标的不透明度。留在 0 以上是有意的:纯隐藏等于"鼠标不来就没人知道它存在",
    /// 而这里要的是"静止时不打扰,想找时看得见"。
    private static let exitGhostIconOpacity: Double = 0.45

    /// 静止态图标直接压在图片上、没有底材托着,所以补一层**与图标反色**的描边:
    /// 深色外观(白图标)配黑晕 → 浅色图片上也认得出;浅色外观(深图标)配白晕 → 深色图片上也认得出。
    private var exitGlyphHalo: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.85)
    }

    /// 纯净模式右上角的出口。**静止时不画"按钮",只留一个单薄的图标**;
    /// 鼠标靠近(角上 120×64 热区,或直接悬停图标本体)时底材淡入、图标回满不透明。
    /// 这样静止时画面里没有方块、只有一个小图标,但出口始终"看得见、找得到"。
    private var exitAffordance: some View {
        Button {
            store.toggleImmersive()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .shadow(color: exitGlyphHalo, radius: 2, y: 0.5)
                .frame(width: 28, height: 22)
                // "按钮"这块底只在现身时存在:静止态它是 0,所以画面里只有一个图标、没有方块。
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.regularMaterial)
                        .opacity(exitAffordanceVisible ? 1 : 0)
                }
                .opacity(exitAffordanceVisible ? 1 : Self.exitGhostIconOpacity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("退出只看图 (Esc / F)")
        // 兜底路径:悬停按钮本体(28×22)也恢复满不透明。
        // 之所以还要这一条:角上那块 120×64 热区靠 `mouseMoved` 事件驱动,
        // 而全项目没有一处开过 `acceptsMouseMovedEvents`,浏览态画布也没装
        // 带 .mouseMoved 的 tracking area —— 万一事件根本不生成,按钮就永远停在幽灵态。
        // 这一条挂在 `.padding(12)` **之前**,命中区就是按钮本体,不会在窗口角上留死区。
        .onContinuousHover { phase in
            switch phase {
            case .active: showExitAffordance()
            case .ended: showExitAffordance(fadeAfter: 2.5)
            }
        }
    }

    /// 让退出按钮回到满不透明。`fadeAfter` 秒后自动淡回幽灵态;传 nil = 保持满不透明
    /// (鼠标还在热区/按钮上)。generation 递增即作废上一个待执行的淡出。
    private func showExitAffordance(fadeAfter seconds: Double? = nil) {
        exitFadeGeneration += 1
        let gen = exitFadeGeneration
        if !exitAffordanceVisible {
            withAnimation(.easeInOut(duration: 0.15)) { exitAffordanceVisible = true }
        }
        guard let seconds else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            // 指针还在右上角(按钮上或热区里)就不淡:悬停与热区两条路径会互相覆盖,
            // 少了这个判断就会出现"鼠标明明停在角上、按钮却淡走了"。
            guard gen == exitFadeGeneration, !exitAffordanceInZone else { return }
            withAnimation(.easeInOut(duration: 0.35)) { exitAffordanceVisible = false }
        }
    }

    private var normalLayer: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        // 1px 分隔线贴在侧栏右边缘(深色画布用白色线,否则不可见)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(
                                    canvasBackground.isDark
                                        ? Color.white.opacity(isHoveringDivider ? 0.22 : 0.12)
                                        : Color.black.opacity(isHoveringDivider ? 0.14 : 0.07)
                                )
                                .frame(width: 1)
                        }
                        // 16pt 拖拽热区，居中于分隔线上（左右各 8pt），便于抓取
                        .overlay(alignment: .trailing) {
                            Color.clear
                                .frame(width: 16)
                                .contentShape(Rectangle())
                                .offset(x: 8)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            let next = dragStartWidth + value.translation.width
                                            sidebarWidth = min(400, max(180, next))
                                        }
                                        .onEnded { _ in dragStartWidth = sidebarWidth; UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") }
                                )
                                .onHover { inside in
                                    isHoveringDivider = inside
                                    WindowMoveControl.setBackgroundMove(!inside && !store.isEditing)
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                        }
                        // 磨砂材质不做透明度动画(半透明会透出画布),Finder 同款纯滑动
                        .transition(.move(edge: .leading))
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: store.printRequestToken) { _, _ in
                        prepareAndPrint()
                    }
            }
            .padding(.top, 32)
            // 侧栏收放动画:transition 早已写好(滑入+淡入),此前缺动画通道导致单帧硬切;
            // 只绑 sidebarVisible,分隔线拖拽宽度的即时性不受影响
            .animation(.easeInOut(duration: 0.22), value: store.sidebarVisible)
            PureHeader(sidebarWidth: sidebarWidth)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: .top)
        .onDisappear {
            WindowMoveControl.setBackgroundMove(true)
        }
    }

    // MARK: - 拼版打印

    /// 当前图起还剩几张可选,作为「张数」上限。
    private var contactSheetAvailableCount: Int {
        max(1, min(store.imagesFromCurrent.count, ContactSheetOptions.countRange.upperBound))
    }

    private var contactSheetSheet: some View {
        let clamped = contactSheetOptions.clamped(availableCount: contactSheetAvailableCount)
        let metrics = PrintService.contactSheetMetrics(options: clamped, imageCount: clamped.count)
        return ContactSheetOptionsForm(
            options: $contactSheetOptions,
            availableCount: contactSheetAvailableCount,
            metrics: metrics,
            preparing: contactSheetPreparing,
            onCancel: { showContactSheetOptions = false },
            onPrint: {
                let chosen = contactSheetOptions.clamped(availableCount: contactSheetAvailableCount)
                contactSheetOptions = chosen
                chosen.saveToDefaults()
                showContactSheetOptions = false
                prepareAndPrintContactSheet(options: chosen)
            }
        )
    }

    private func presentContactSheetOptions() {
        guard store.currentImage != nil, !contactSheetPreparing else { return }
        contactSheetOptions = contactSheetOptions
            .clamped(availableCount: contactSheetAvailableCount)
        showContactSheetOptions = true
    }

    private func prepareAndPrintContactSheet(options: ContactSheetOptions) {
        guard !contactSheetPreparing else { return }
        let picked = Array(store.imagesFromCurrent.prefix(options.count))
        guard !picked.isEmpty else { return }
        let sources = picked.map { ContactSheetImageLoader.Source(url: $0.url, title: $0.name) }

        contactSheetPreparing = true
        store.isModalPresented = true
        // 缩略图必须按格子的实际像素尺寸下单(几百 px),绝不能解全尺寸——
        // 20 张 24MP 拼版会瞬间吃掉几百 MB。
        let maxPixel = PrintService.contactSheetMetrics(options: options,
                                                        imageCount: sources.count).thumbnailMaxPixel
        Task {
            let loaded = await ContactSheetImageLoader.load(sources, maxPixel: maxPixel)
            // 解不出来的图直接略过,不占格子,免得版面上出现空框。
            let items = loaded.compactMap { $0 }
            contactSheetPreparing = false
            store.isModalPresented = false
            guard !items.isEmpty else { return }
            await MainActor.run {
                PrintService.print(contactSheet: items, options: options)
                store.isModalPresented = false
            }
        }
    }

    private func prepareAndPrint() {
        guard let file = store.currentImage, !isPreparingPrint else { return }
        isPreparingPrint = true
        store.isModalPresented = true
        let url = file.url
        Task {
            // 打印按纸张分辨率限解码尺寸即可:300dpi 的 A4 满打满算约 3508px 长边,
            // 再多的像素进不了纸。限住后大图解码从秒级降到毫秒级,不会一直转圈。
            let printMaxPixel: CGFloat = 3600
            let image = await Task.detached(priority: .userInitiated) {
                try? ImageLoader.decode(url: url, maxPixelSize: printMaxPixel)
            }.value
            isPreparingPrint = false
            // 打印面板是模态的,从 runModal 返回即代表已关闭
            store.isModalPresented = false
            guard let image else { return }
            await MainActor.run {
                PrintService.print(image: image)
                store.isModalPresented = false
            }
        }
    }

    // MARK: 详情区

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                if store.isEditing, let file = store.currentImage {
                    EditView(
                        file: file,
                        initialQuarterTurns: ((store.rotationCount % 4) + 4) % 4,
                        initialTool: store.editTool,
                        onClose: { store.endEditing() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(file.url)
                } else {
                ImageViewCanvas(
                    file: store.currentImage,
                    neighborURLs: store.neighborURLs,
                    background: canvasBackground,
                    openZoomMode: openZoomMode,
                    zoomRequest: store.zoomRequest,
                    rotationCount: store.rotationCount,
                    stepDirection: store.lastStepDirection,
                    onLoadingChange: { store.imageLoading = $0 },
                    onScaleChange: { store.displayScale = $0 },
                    onImageInfo: { store.displayInfo = $0 },
                    onRotationChange: { store.isDisplayRotated = $0 },
                    onStep: { store.step($0) },
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu {
                    if let file = store.currentImage {
                        Button { store.copyImageToPasteboard(file.id) } label: {
                            Label("复制图片", systemImage: "doc.on.doc")
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        Divider()
                        Button { store.requestRotate() } label: {
                            Label("顺时针旋转 90°", systemImage: "rotate.right")
                        }
                        Button { store.requestCrop() } label: {
                            Label("裁切…", systemImage: "crop")
                        }
                        Button { store.requestPrint() } label: {
                            Label("打印…", systemImage: "printer")
                        }
                    }
                }

                if store.roots.isEmpty {
                    welcomeOverlay
                } else if store.folderScanning && store.currentImage == nil {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.imageLoading && store.displayInfo.pixelWidth == 0 {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let current = store.currentImage, store.displayInfo.pixelWidth == 0, !store.imageLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("无法显示“\(current.name)”")
                            .foregroundStyle(.secondary)
                    }
                }
                }
                }

                if store.showInspector {
                    InfoInspector(file: store.currentImage)
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            // 只绑 showInspector,画布随分区宽度连续重排
            .animation(.easeInOut(duration: 0.22), value: store.showInspector)
            if !store.isImmersive {
                statusBar
            }
        }
        // 缩放下拉用窗口内 overlay 实现,保证弹出面板被窗口边界裁剪
        .overlay {
            if showZoomMenu {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showZoomMenu = false }
                    zoomDropdown
                        .padding(.trailing, 8)
                        .padding(.bottom, 32)
                }
                .onExitCommand { showZoomMenu = false }
                .transition(.opacity)
            }
        }
    }

    private var welcomeOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("打开一个图片文件夹开始浏览")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("打开文件夹…") { store.openFolderPanel() }
                .keyboardShortcut("o", modifiers: .command)
            if !store.recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近打开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    ForEach(store.recentFolders) { item in
                        WelcomeRecentRow(item: item) {
                            store.openRecentFolder(item.url)
                        }
                    }
                }
                .frame(maxWidth: 360)
            }
            Text("也可以直接把图片或文件夹拖入窗口")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
        .background(MainChromeBackground(canvas: canvasBackground))
    }

    private struct WelcomeRecentRow: View {
        let item: RecentFolders.Item
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .foregroundStyle(.primary)
                        Text(item.displayPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(item.displayPath)
        }
    }

    /// 缩放下拉的菜单项(悬停高亮)
    private struct ZoomMenuItem: View {
        let title: String
        let action: () -> Void

        @State private var hovering = false

        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                hovering ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .onHover { hovering = $0 }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let image = store.currentImage {
                // 身份组:文件名(主色强调)
                Text(image.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                let meta = statusMetaItems
                if !meta.isEmpty {
                    statusBarDivider
                    // 元数据组:中点轻连接,比空格更有"同属一组"的暗示
                    HStack(spacing: 5) {
                        ForEach(meta.indices, id: \.self) { i in
                            if i > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(meta[i])
                                .monospacedDigit()
                        }
                    }
                }

                // 旋转只是显示态,切图即丢、不写回文件;这里如实标注,避免用户误以为已保存
                if store.isDisplayRotated {
                    statusBarDivider
                    HStack(spacing: 3) {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 9))
                        Text("已旋转(未保存)")
                    }
                    .foregroundStyle(.secondary)
                }

                statusBarDivider
                // 导航组
                Text("\(store.visibleIndex + 1) / \(store.visibleImages.count)")
                    .monospacedDigit()
                if store.imageLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                zoomMenu
            } else if store.folderScanning {
                ProgressView()
                    .controlSize(.mini)
                Text("正在扫描文件夹…")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("未打开图片").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
        .background {
            MainChromeBackground(canvas: canvasBackground)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ChromeTheme.hairline(canvasBackground))
                .frame(height: 1)
        }
    }

    /// 元数据段:格式 / 像素尺寸 / 动图帧数(按可用性拼接)
    private var statusMetaItems: [String] {
        var items: [String] = []
        if !store.displayInfo.formatName.isEmpty {
            items.append(store.displayInfo.formatName)
        }
        if store.displayInfo.pixelWidth > 0 {
            items.append("\(store.displayInfo.pixelWidth) × \(store.displayInfo.pixelHeight)")
        }
        if store.displayInfo.isAnimated {
            items.append("\(store.displayInfo.frameCount) 帧")
        }
        return items
    }

    /// 状态栏分组竖线
    private var statusBarDivider: some View {
        Divider()
            .frame(height: 11)
    }

    private var zoomMenu: some View {
        Button {
            showZoomMenu.toggle()
        } label: {
            Text("\(Int(((store.isEditing ? store.editDisplayScale : store.displayScale) * 100).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .disabled(store.currentImage == nil || (store.isEditing && store.editTool == .crop))
    }

    /// 窗口内下拉面板(替代 NSMenu 弹出,不超出窗口边界)
    private var zoomDropdown: some View {
        // 编辑画布的倍率相对适应窗口(1.0 = fit),没有"实际大小"语义
        VStack(alignment: .leading, spacing: 2) {
            ZoomMenuItem("适配窗口") {
                showZoomMenu = false
                if store.isEditing { store.requestEditZoom(.fit) } else { store.requestZoom(.fit) }
            }
            if !store.isEditing {
                ZoomMenuItem("实际大小 (100%)") {
                    showZoomMenu = false
                    store.requestZoom(.actualSize)
                }
            }
            Divider().padding(.vertical, 2)
            ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { factor in
                if store.isEditing || factor != 4.0 {
                    ZoomMenuItem("\(Int((factor * 100).rounded()))%") {
                        showZoomMenu = false
                        if store.isEditing { store.requestEditZoom(.scale(factor)) } else { store.requestZoom(.scale(factor)) }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 170, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    // MARK: 自测模式(--zoom-test):自动执行一组缩放动作并记录日志

    private func runZoomSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        // --zoom-autopen:配合 --zoom-debug 抓缩放日志用,启动即打开 Downloads,省去手动开文件夹
        if args.contains("--zoom-autopen") {
            let downloads = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                store.openFolder(downloads)
            }
            return
        }
#if DEBUG
        // --drift-test:只加载图片并就绪,缩放由真实滚轮事件驱动,日志走 --zoom-debug
        if args.contains("--drift-test") {
            Task { @MainActor in
                store.openFolder(URL(fileURLWithPath: "/tmp/pictool_test"))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                FileHandle.standardError.write(Data("[drift-test] ready\n".utf8))
            }
            return
        }
        guard args.contains("--zoom-test") else { return }
        Task { @MainActor in
            let wait: UInt64 = 1_200_000_000
            store.openFolder(URL(fileURLWithPath: "/tmp/pictool_test"))
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] zoomIn #1\n".utf8))
            store.requestZoom(.zoomIn)
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] zoomIn #2\n".utf8))
            store.requestZoom(.zoomIn)
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] simulate pinch 1.5x\n".utf8))
            NotificationCenter.default.post(name: Notification.Name("PictoolSimPinch"),
                                            object: nil, userInfo: ["m": 1.5])
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] fit\n".utf8))
            store.requestZoom(.fit)
            try? await Task.sleep(nanoseconds: wait)
            // 面板打开状态下再测一轮缩放(对照:面板关闭时的上一组)
            FileHandle.standardError.write(Data("[test] panel OPEN\n".utf8))
            store.showInspector = true
            try? await Task.sleep(nanoseconds: wait * 2)
            for i in 1...8 {
                FileHandle.standardError.write(Data("[test] panel+zoomIn #\(i)\n".utf8))
                store.requestZoom(.zoomIn)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            FileHandle.standardError.write(Data("[test] panel CLOSE\n".utf8))
            store.showInspector = false
            try? await Task.sleep(nanoseconds: wait)
            // 旋转 × 纯净模式切换:验证新画布实例能重放完整旋转角度
            FileHandle.standardError.write(Data("[test] rotate #1\n".utf8))
            store.requestRotate()
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] immersive ON\n".utf8))
            store.toggleImmersive()
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] immersive OFF\n".utf8))
            store.toggleImmersive()
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] rotate #2\n".utf8))
            store.requestRotate()
            try? await Task.sleep(nanoseconds: wait)
            FileHandle.standardError.write(Data("[test] immersive ON again\n".utf8))
            store.toggleImmersive()
            try? await Task.sleep(nanoseconds: wait)
            // 漂移实验:偏心锚点连续小步长放大 4.3 倍,逐 tick 记录锚定偏差
            FileHandle.standardError.write(Data("[test] drift experiment\n".utf8))
            NotificationCenter.default.post(
                name: Notification.Name("PictoolSimAnchorPinch"), object: nil,
                userInfo: ["ax": 0.3, "ay": 0.3, "steps": 60, "factor": 1.025])
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            FileHandle.standardError.write(Data("[test] DONE\n".utf8))
        }
#endif
    }

    // MARK: 拖放 / 外部打开

    @MainActor
    private func handleExternal(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            store.openFolder(url)
        } else if ImageDiscovery.isImageFile(url) {
            store.revealExternalImages([url])
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        // 回调在后台线程、可能并发进来,所以状态收进 Locked,不在闭包里直接捕获 var。
        let state = Locked((pending: providers.count, urls: [URL]()))
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let outcome = state.withLock { s -> (finished: Bool, urls: [URL]) in
                    if let url { s.urls.append(url) }
                    s.pending -= 1
                    return (s.pending == 0, s.urls)
                }
                if outcome.finished {
                    Task { @MainActor in
                        self.handleDroppedURLs(outcome.urls)
                    }
                }
            }
        }
        return true
    }

    @MainActor
    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 目录拖入：直接打开首个目录（保持原有行为）
        let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if dirs.count == 1 && urls.count == 1 {
            store.openFolder(dirs[0])
            return
        }
        // 其余按图片处理（单张/多张同目录走单图模式，自动提示按需加载）
        let imageURLs = urls.filter { ImageDiscovery.isImageFile($0) }
        if !imageURLs.isEmpty {
            store.revealExternalImages(imageURLs)
            return
        }
        // 兜底：若拖入的是目录集合，打开首个
        if let firstDir = dirs.first { store.openFolder(firstDir) }
    }
}

/// 幻灯片控制条:底部居中胶囊条,播放/暂停、前后切换、间隔循环、结束会话。
/// **只在幻灯片会话里存在** —— 会话开始浮现一次、静止 2.5 秒淡出、鼠标移到窗口底边可再叫出来;
/// 不播放时纯净模式里不该有任何浮层(此时退出走右上角按钮 / Esc / F / 菜单栏)。
private struct SlideshowHUD: View {
    let playing: Bool
    var canPlay: Bool = true
    let positionText: String
    let intervalLabel: String
    let onPrev: () -> Void
    let onToggle: () -> Void
    let onNext: () -> Void
    let onCycleInterval: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(positionText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            hudButton("chevron.left", action: onPrev)
            hudButton(playing ? "pause.fill" : "play.fill", action: onToggle, prominent: true, disabled: !canPlay)
            hudButton("chevron.right", action: onNext)
            Divider().frame(height: 16)
            Button(action: onCycleInterval) {
                Text(intervalLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("播放间隔(点击切换)")
            Divider().frame(height: 16)
            hudButton("xmark", action: onExit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }

    private func hudButton(_ symbol: String, action: @escaping () -> Void, prominent: Bool = false, disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 14 : 12, weight: .medium))
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

/// 窗口 chrome：移除原生标题栏，仅保留 PureHeader 单层
private struct WindowChrome: NSViewRepresentable {
    let immersive: Bool
    var allowBackgroundMove = true
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.immersive = immersive
        (nsView as? ChromeView)?.allowBackgroundMove = allowBackgroundMove
        (nsView as? ChromeView)?.apply()
    }
}
private final class ChromeView: NSView {
    var immersive = false
    var allowBackgroundMove = true
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        DispatchQueue.main.async { [weak self] in self?.stripTitlebar() }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
    func apply() { stripTitlebar() }
    private func stripTitlebar() {
        WindowMoveControl.setBackgroundMove(allowBackgroundMove)
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        // 记住窗口位置与尺寸,下次启动恢复到上次的位置
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("MainWindow")
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = ""
        window.backgroundColor = .clear
        window.isOpaque = false
        let radius: CGFloat = immersive ? 0 : 10
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = radius
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.cornerRadius = radius
        window.contentView?.superview?.layer?.masksToBounds = true
        // 原生标题栏藏掉,避免挡自定义顶栏点击;红绿灯由 PureHeader 里的 NativeTrafficLights 接管。
        // 纯净模式连按钮一起藏。
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = immersive
        }
        if let theme = window.contentView?.superview {
            for sub in theme.subviews where String(describing: type(of: sub)).contains("Titlebar") {
                sub.isHidden = true
                sub.frame.size.height = 0
            }
        }
    }
}

