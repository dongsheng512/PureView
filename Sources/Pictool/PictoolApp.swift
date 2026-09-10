import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let openExternalURLs = Notification.Name("openExternalURLs")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: FolderStore?

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        handle(urls: [url])
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        handle(urls: urls)
        application.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func handle(urls: [URL]) {
        guard let store = store else {
            // 尚未初始化时先发通知，MainContentView 会在 onReceive 中处理
            NotificationCenter.default.post(name: .openExternalURLs, object: urls)
            return
        }
        Task { @MainActor in
            let imageURLs = urls.filter { ImageDiscovery.isImageFile($0) }
            let dirURLs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            if !imageURLs.isEmpty {
                store.revealExternalImages(imageURLs)
            } else if let dir = dirURLs.first {
                store.openFolder(dir)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct PictoolApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = FolderStore()
    @State private var annotations = AnnotationStore()

    /// 文本输入(缩略图过滤框)是否获得焦点。菜单里所有**裸键与编辑类**快捷键据此让路,
    /// 否则用户打字时会误触发切图/裁切/删文件。
    private var textInputActive: Bool { store.isTextInputFocused }

    var body: some Scene {
        Window("PureView", id: "main") {
            MainContentView()
                .environment(store)
                .environment(annotations)
                .ignoresSafeArea(.container, edges: .top)
                .onAppear { delegate.store = store }
                .onReceive(NotificationCenter.default.publisher(for: .openExternalURLs)) { note in
                    if let urls = note.object as? [URL] {
                        if urls.count == 1, let url = urls.first {
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                store.openFolder(url)
                            } else {
                                store.revealExternalImages(urls)
                            }
                        } else {
                            store.revealExternalImages(urls)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 680)
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { store.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(store.isModalPresented)
                Button("刷新") { store.refreshCurrentFolder() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.selectedFolder == nil || store.isModalPresented)
                Menu("最近打开的文件夹") {
                    if store.recentFolders.isEmpty {
                        Button("无记录") {}
                            .disabled(true)
                    } else {
                        ForEach(store.recentFolders) { item in
                            Button(item.name) { store.openRecentFolder(item.url) }
                                .help(item.displayPath)
                                .disabled(store.isModalPresented)
                        }
                    }
                    Divider()
                    Button("清除最近记录") { store.clearRecentFolders() }
                        .disabled(store.recentFolders.isEmpty)
                }
            }
            CommandGroup(replacing: .printItem) {
                Button("打印…") { store.requestPrint() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Button("拼版打印…") { store.requestContactSheet() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(store.currentImage == nil || store.isModalPresented
                              || store.visibleImages.count < 2)
            }
            CommandMenu("图片") {
                // 裸键与方向键在模态面板打开时一律失效,否则会在面板背后改动浏览状态。
                // 另外还要让位给文本输入:缩略图过滤框是本窗口唯一的输入框,
                // 它一旦拿到焦点,敲 "i" 会切信息面板、敲 "c" 会进裁切、⌘⌫ 会去废纸篓删文件
                // —— 全是用户想打字却动了别的东西。这个坑以前不存在,因为主窗口没有输入框。
                Button("上一张") { store.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!store.canStep(-1) || store.isModalPresented || textInputActive)
                Button("下一张") { store.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!store.canStep(1) || store.isModalPresented || textInputActive)
                Divider()
                Button("适配窗口") { store.requestZoom(.fit) }
                    .keyboardShortcut("0", modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented || textInputActive)
                Button("实际大小") { store.requestZoom(.actualSize) }
                    .keyboardShortcut("1", modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented || textInputActive)
                Button("放大") { store.requestZoom(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Button("缩小") { store.requestZoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Divider()
                Button("信息面板") { store.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [])
                    .disabled(store.isModalPresented || textInputActive)
                Button(store.isImmersive ? "退出只看图" : "只看图") {
                    store.toggleImmersive()
                }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled((store.currentImage == nil && !store.isImmersive)
                              || store.isModalPresented || textInputActive)
                Button(
                    store.isSlideshowActive
                        ? (store.isSlideshowPaused ? "继续幻灯片" : "暂停幻灯片")
                        : "幻灯片播放"
                ) {
                    store.toggleSlideshow()
                }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(store.currentImage == nil || store.isModalPresented
                              || store.visibleImages.count < 2 || textInputActive)
                Button("裁切…") { store.requestCrop() }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(store.currentImage == nil
                              || (store.isModalPresented && !store.isEditing)
                              || store.isTextDraftActive
                              || textInputActive)
                Button("标记…") { store.requestMarkup() }
                    .keyboardShortcut("d", modifiers: [])
                    .disabled(store.currentImage == nil
                              || (store.isModalPresented && !store.isEditing)
                              || store.isTextDraftActive
                              || textInputActive)
                Divider()
                Button("顺时针旋转 90°") { store.requestRotate() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(store.currentImage == nil || store.isModalPresented)
                Divider()
                // D2 浏览快捷键:动作早就有了(右键菜单 / 顶栏),缺的只是键盘入口。
                // 一律以 canActOnCurrentImage 门禁 —— 编辑中、模态中全部失效,
                // 否则会在面板背后改动浏览状态。
                //
                // 与排期文档的一处偏离:文档写"无选中标注时才复制图片"(即编辑中也可能复制
                // 图片),实际做成**编辑中一律不复制图片**。因为 EditView 自己也注册了 ⌘C
                // (复制选中标注),两个同名快捷键同时有效会退化成"看谁先响应"的不确定行为。
                // 保守起见编辑态只留 EditView 那一个,代价是"编辑中无选中标注时 ⌘C 不动"。
                Button("复制图片") { store.copyCurrentImage() }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(!store.canActOnCurrentImage || textInputActive)
                Button("隐藏") { store.hideCurrentImage() }
                    .keyboardShortcut("h", modifiers: [])
                    .disabled(!store.canActOnCurrentImage || textInputActive)
                Button("移到废纸篓…") { store.deleteCurrentImage() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!store.canActOnCurrentImage || textInputActive)
                Button("在 Finder 中显示") { store.revealCurrentInFinder() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(store.currentImage == nil)
            }
        }
        Settings {
            SettingsView()
        }
    }
}
