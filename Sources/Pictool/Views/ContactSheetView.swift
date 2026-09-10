import AppKit

/// 拼版里的一格:已解码的小图 + 可选标题(文件名)。
struct ContactSheetItem {
    var image: NSImage
    var title: String?
}

/// 拼版打印的文档视图。
///
/// 一页 = 纸张尺寸的一个「切块」,整个文档就是 `pageCount` 页竖直叠起来。
/// 用 `knowsPageRange` / `rectForPage` 显式接管分页,`NSPrintOperation` 才能自动续页
/// (拼版的一切布局都在页内算好,交给默认分页器反而会按视图尺寸乱切)。
///
/// 坐标系:`isFlipped = true`(原点左上、y 向下),与 `ContactSheetLayout` 一致。
/// 好处是「第 1 行」就是视觉上的第一行,且文字不需要再做一次上下翻转。
final class ContactSheetView: NSView {

    private let metrics: ContactSheetLayout.Metrics
    private let items: [ContactSheetItem]

    init(metrics: ContactSheetLayout.Metrics, items: [ContactSheetItem]) {
        self.metrics = metrics
        self.items = items
        let pages = CGFloat(max(1, metrics.pageCount))
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: metrics.pageSize.width,
                                 height: metrics.pageSize.height * pages))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: 分页

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, metrics.pageCount))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0,
               y: CGFloat(max(1, page) - 1) * metrics.pageSize.height,
               width: metrics.pageSize.width,
               height: metrics.pageSize.height)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let pageHeight = metrics.pageSize.height
        guard pageHeight > 0 else { return }
        // 只画与 dirtyRect 相交的那几页:整册一次 draw 时不必把 10 页全重画一遍。
        let rawFirst = Int(floor(dirtyRect.minY / pageHeight))
        let rawLast = Int(floor(max(dirtyRect.maxY - 0.001, 0) / pageHeight))
        let first = max(0, rawFirst)
        let last = min(max(1, metrics.pageCount) - 1, rawLast)
        guard first <= last else { return }
        for page in first...last { drawPage(page) }
    }

    private func drawPage(_ page: Int) {
        let layout = ContactSheetLayout.imagesPerPage(imageCount: items.count,
                                                     rows: metrics.rows,
                                                     columns: metrics.columns)
        let onThisPage = page < layout.count ? layout[page] : 0
        guard onThisPage > 0 else { return }

        let grid = ContactSheetLayout.grid(pageSize: metrics.pageSize,
                                           rows: metrics.rows,
                                           columns: metrics.columns,
                                           inset: metrics.inset,
                                           spacing: metrics.spacing)
        let firstIndex = layout.prefix(page).reduce(0, +)
        let originY = CGFloat(page) * metrics.pageSize.height

        for slot in 0..<onThisPage {
            let index = firstIndex + slot
            guard index < items.count, slot < grid.frames.count else { break }
            let cell = grid.frames[slot].offsetBy(dx: 0, dy: originY)
            let item = items[index]
            let imageArea = ContactSheetLayout.imageRect(in: cell, titleHeight: metrics.titleHeight)
            let box = ContactSheetLayout.fittedRect(aspect: Self.pixelSize(of: item.image),
                                                    in: imageArea)
            item.image.draw(in: box,
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1,
                            respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high])
            if metrics.titleHeight > 0, let title = item.title, !title.isEmpty {
                drawTitle(title, in: ContactSheetLayout.titleRect(in: cell,
                                                                 titleHeight: metrics.titleHeight))
            }
        }
    }

    /// 位图像素尺寸(不是 point 尺寸)。缩放比要用它算,用 `image.size` 会因 DPI 元数据跑偏。
    private static func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func drawTitle(_ title: String, in rect: CGRect) {
        guard !rect.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        // 视图是 flipped,`draw(with:options:)` 会照常正着画,不需要额外翻矩阵。
        NSAttributedString(string: title, attributes: attributes)
            .draw(with: rect.insetBy(dx: 2, dy: 0),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - 装载

/// 拼版图片装载:限并发地把 URL 解码成「刚好够格子用」的小图。
///
/// ⚠️ **刻意不走 `ThumbnailProvider.shared`**:它的 NSCache 只按 URL 索引、不区分
/// `maxPixel`——网格里已经缓存过的 180px 缩略图会被当成 900px 的请求结果直接返回,
/// 拼版会整版发糊,而且还会把大图塞进 80MB 上限的网格缓存里互相挤。
/// 这里直接用无缓存的 `ThumbnailProvider.generate(url:maxPixel:)`,并按格子的实际
/// 像素尺寸下单,**绝不解全尺寸**(20 张 24MP 拼版会瞬间吃掉几百 MB)。
enum ContactSheetImageLoader {

    /// 一格的输入。
    struct Source: Sendable {
        var url: URL
        var title: String?
    }

    /// 同时解码数。按批推进,避免一次性压满 CPU 与内存。
    static let maxConcurrent = 4

    nonisolated static func load(_ sources: [Source], maxPixel: CGFloat) async -> [ContactSheetItem?] {
        guard !sources.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, sources.count))
        return await withTaskGroup(of: (Int, NSImage?).self) { group in
            var out = [ContactSheetItem?](repeating: nil, count: sources.count)
            var next = 0

            // 窗口式推进:始终只让 limit 个解码在飞。写成内联而不是局部函数,
            // 因为 withTaskGroup 的 group 是 inout 参数,局部函数捕获它不安全。
            while next < limit {
                let index = next
                let url = sources[index].url
                group.addTask(priority: .userInitiated) {
                    (index, ThumbnailProvider.generate(url: url, maxPixel: maxPixel))
                }
                next += 1
            }

            for await (index, image) in group {
                if let image {
                    out[index] = ContactSheetItem(image: image, title: sources[index].title)
                }
                if next < sources.count {
                    let index = next
                    let url = sources[index].url
                    group.addTask(priority: .userInitiated) {
                        (index, ThumbnailProvider.generate(url: url, maxPixel: maxPixel))
                    }
                    next += 1
                }
            }
            return out
        }
    }
}
