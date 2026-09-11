import SwiftUI

/// 边栏下半区:当前文件夹的缩略图网格(异步加载、当前项高亮、切换跟随滚动)
struct ThumbnailGridView: View {

    @Environment(FolderStore.self) private var store
    /// 是否处于向上扩展态(由 SidebarView 持有,联动压缩文件夹树)
    @Binding var expanded: Bool
    @State private var headerHovering = false
    /// 过滤框焦点。写回 `store.isTextInputFocused`,让菜单里的裸键快捷键整体让路。
    @FocusState private var filterFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 120), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 左:标题+计数一组;右:恢复链接与箭头。整行可点切换展开
            HStack(spacing: 8) {
                Text(filterHeaderText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                if store.folderScanning {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                if store.hiddenCountInCurrentFolder > 0 {
                    Menu {
                        ForEach(store.hiddenFilesInCurrentFolder, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                store.unhideImage(url)
                            }
                        }
                        Divider()
                        Button("全部恢复") {
                            store.unhideAllInCurrentFolder()
                        }
                    } label: {
                        Text("已隐藏 \(store.hiddenCountInCurrentFolder)")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(Color.accentColor)
                    .help("显示被隐藏的图片,或全部恢复")
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(headerHovering ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
            .onHover { headerHovering = $0 }
            .onTapGesture { expanded.toggle() }
            .help(expanded ? "复原缩略图区域" : "扩大缩略图区域")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // 整行 hover 反馈:暗示"这一行是开关",而非只有箭头可点;高亮吃满内边距,外留 4pt
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(headerHovering ? 0.05 : 0))
            )
            .padding(.horizontal, 4)

            if !store.images.isEmpty { filterField }

            if store.folderScanning && store.images.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.images.isEmpty {
                // 空态:一张虚线描边的“空缩略图”占位;已选文件夹但无图时才补文字说明
                VStack(spacing: 10) {
                    EmptyThumbnailPlaceholder()
                    if store.selectedFolder != nil {
                        Text("此文件夹没有图片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleImages.isEmpty {
                noMatchView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Array(store.visibleImages.enumerated()), id: \.element.id) { idx, file in
                                ThumbCell(file: file, isCurrent: file.id == store.selectedImageID, isVisible: idx < 30)
                                    .id(file.id)
                                    .onTapGesture { store.selectImage(file.id) }
                                    .contextMenu {
                                        Button {
                                            store.copyImageToPasteboard(file.id)
                                        } label: {
                                            Label("复制图片", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            store.hideImage(file.id)
                                        } label: {
                                            Label("隐藏", systemImage: "eye.slash")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            store.deleteImage(file.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: store.selectedImageID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 标题计数:过滤中显示「可见/总数」,一眼看出被筛掉了多少。
    private var filterHeaderText: String {
        store.isFiltering
            ? "缩略图 · \(store.visibleImages.count)/\(store.images.count)"
            : "缩略图 · \(store.images.count)"
    }

    /// 过滤输入框。绑定走 `store.setFilter` 而不是直接写字段 ——
    /// 改过滤词必须顺手收拢被筛掉的选中项,这个不变式由 store 自己守。
    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("过滤文件名", text: Binding(
                get: { store.filterText },
                set: { store.setFilter($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($filterFocused)
            if store.isFiltering {
                Button {
                    store.clearFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除过滤")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .onChange(of: filterFocused) { _, focused in
            store.isTextInputFocused = focused
        }
        .onExitCommand { filterFocused = false }
        .onDisappear {
            // 侧栏收起、切到编辑态、文件夹清空都会让这个输入框消失,
            // 而焦点回调不一定再触发一次 —— 别把"正在输入"留成 true 把菜单全锁死。
            if store.isTextInputFocused { store.isTextInputFocused = false }
        }
        .padding(.horizontal, 12)
        // 顶上留一拍:标题行自带 6pt 底内边距,不加这个过滤框会贴着标题行的 hover 高亮
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 过滤词一个都没匹配上。此时**画布仍显示原来那张图**(store 保留选中不动),
    /// 所以这里只是网格的局部空态,不是"文件夹空了"。
    private var noMatchView: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("没有匹配「\(store.filterText)」的图片")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("清除过滤") { store.clearFilter() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 空缩略图占位:虚线圆角框 + 淡色图片图标,尺寸与缩略图格子一致
private struct EmptyThumbnailPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.14),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(width: 96, height: 76)
    }
}

/// 扁平小胶囊按钮:固定 28×16(与 callout 文字行高一致),半透明底 + 细描边
struct FlatPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.primary.opacity(0.7))
            .frame(width: 42, height: 16)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ThumbCell: View {

    let file: ImageFile
    let isCurrent: Bool
    var isVisible: Bool = false
    @State private var thumb: NSImage?
    /// 解码失败标记。不记这个的话 thumb 永远是 nil,
    /// .task(id:) 只在 id 变化时重跑,失败项会永远卡在转圈。
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)   // 完整显示整张图,不裁切
                        .padding(2)
                } else if failed {
                    // 权限受限 / 文件损坏 / 无法解码的 RAW 会走到这里
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
            )

            Text(file.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: file.id) {
            guard thumb == nil, !failed else { return }
            let loaded = await ThumbnailProvider.shared.asyncThumbnail(
                for: file.url, maxPixel: 180, isVisible: isVisible
            )
            if let loaded {
                thumb = loaded
            } else {
                failed = true
            }
        }
    }
}
