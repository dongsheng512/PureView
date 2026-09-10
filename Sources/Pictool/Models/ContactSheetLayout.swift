import CoreGraphics

/// 拼版(联系表)打印的**纯几何**。
///
/// 单位统一为「点」,与 `NSPrintInfo.paperSize` 同一坐标系。本类型不持有任何 AppKit 状态,
/// 所以可以脱离 UI 直接单测——项目硬约束:`CropMath` / `MarkupGeometry` / `WatermarkLayout` /
/// `EditCanvasMath` / `ZoomMath` 之后,几何换算一律走这条路。
///
/// 坐标约定:`isFlipped = true`(原点左上、y 向下),与 `ContactSheetView` 一致,
/// 于是一行正好是一页里的一排,`draw` 与分页都能用同一套矩形。
enum ContactSheetLayout {

    /// 打印目标分辨率。格子边长(点)→ 像素 = 点 / 72 × dpi。
    static let printTargetDPI: CGFloat = 300

    /// 单格缩略图请求的像素上限。下限保证小格子不至于糊,上限兜住内存
    /// (48 格 × 1024² 也只是几十 MB,远低于 500MB 红线)。
    static let thumbnailPixelRange: ClosedRange<CGFloat> = 256...1024

    /// 一页的格网排布。
    struct Grid: Equatable {
        var rows: Int
        var columns: Int
        var cellSize: CGSize
        /// 按阅读顺序排列(从左到右、从上到下),个数 = rows × columns。
        var frames: [CGRect]
    }

    /// 由纸张与选项推出的全部版式指标。`Sendable` 的值类型,可以安全跨线程。
    struct Metrics: Equatable {
        /// 已按格网形状摆正后的纸张(点)。宽格网 → 横向纸。
        var pageSize: CGSize
        var rows: Int
        var columns: Int
        var cellSize: CGSize
        /// 纸张内边距。留出打印机硬件不可印边,避免最外圈被裁掉。
        var inset: CGFloat
        var spacing: CGFloat
        /// 每格底部给文件名预留的高度(不标名字时为 0)。
        var titleHeight: CGFloat
        var perPage: Int
        var pageCount: Int
        /// 每格位图的请求像素(长边)。
        var thumbnailMaxPixel: CGFloat

        /// 格网比纸更宽 → 用横向纸。
        var isLandscape: Bool { columns > rows }
    }

    /// 每格文件名条的高度。8pt 字 + 1pt 余量;不显示时为 0,格子整块留给图。
    static let titleHeight: CGFloat = 13

    // MARK: - 格网

    /// 把 `rows × columns` 个等大格子铺满 `pageSize`(内边距 `inset`、格间距 `spacing`)。
    /// 尺寸退化为 0 或负时不做钳制到 1×1 —— 返回 `cellSize` 为 .zero 的空帧,
    /// 让调用方一眼看出参数不可用,而不是悄悄画出一个错的版式。
    static func grid(pageSize: CGSize,
                     rows: Int,
                     columns: Int,
                     inset: CGFloat,
                     spacing: CGFloat) -> Grid {
        let cols = max(1, columns)
        let rws = max(1, rows)
        let pad = max(0, inset)
        let gap = max(0, spacing)

        let usableW = pageSize.width - 2 * pad
        let usableH = pageSize.height - 2 * pad
        let cellW = (usableW - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (usableH - gap * CGFloat(rws - 1)) / CGFloat(rws)

        guard cellW > 0, cellH > 0 else {
            return Grid(rows: rws, columns: cols, cellSize: .zero,
                        frames: Array(repeating: .zero, count: cols * rws))
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(cols * rws)
        for row in 0..<rws {
            for col in 0..<cols {
                let x = pad + CGFloat(col) * (cellW + gap)
                let y = pad + CGFloat(row) * (cellH + gap)
                frames.append(CGRect(x: x, y: y, width: cellW, height: cellH))
            }
        }
        return Grid(rows: rws, columns: cols,
                    cellSize: CGSize(width: cellW, height: cellH), frames: frames)
    }

    // MARK: - 格内摆放

    /// 格子顶部、扣掉文件名条之后留给位图的区域。
    static func imageRect(in cell: CGRect, titleHeight: CGFloat) -> CGRect {
        guard titleHeight > 0, cell.height > titleHeight else { return cell }
        return CGRect(x: cell.minX, y: cell.minY,
                      width: cell.width, height: cell.height - titleHeight)
    }

    /// 格子底部的文件名条。不标名字时返回 `.null`,调用方 `isEmpty` 即可跳过。
    static func titleRect(in cell: CGRect, titleHeight: CGFloat) -> CGRect {
        guard titleHeight > 0, cell.height > titleHeight else { return .null }
        return CGRect(x: cell.minX, y: cell.maxY - titleHeight,
                      width: cell.width, height: titleHeight)
    }

    /// 按 `aspect` 等比内接于 `cell` 并居中。`aspect` 是**像素尺寸**(宽高比即可),
    /// 所以传原图宽高也不会变形。aspect 或 cell 退化时原样返回 `cell`。
    static func fittedRect(aspect: CGSize, in cell: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, cell.width > 0, cell.height > 0 else {
            return cell
        }
        let scale = min(cell.width / aspect.width, cell.height / aspect.height)
        let w = aspect.width * scale
        let h = aspect.height * scale
        return CGRect(x: cell.minX + (cell.width - w) / 2,
                      y: cell.minY + (cell.height - h) / 2,
                      width: w, height: h)
    }

    // MARK: - 分页

    /// 总张数摊到每页 `rows × columns` 格之后的页数。空集也算 1 页
    /// (`NSPrintOperation` 不接受 0 页)。
    static func pageCount(imageCount: Int, rows: Int, columns: Int) -> Int {
        let per = max(1, rows) * max(1, columns)
        guard imageCount > 0 else { return 1 }
        return (imageCount + per - 1) / per
    }

    /// 每页实际放几张。末页通常不满——用它算最后一页该画几个格子,
    /// 免得出现「最后一行空框」。
    static func imagesPerPage(imageCount: Int, rows: Int, columns: Int) -> [Int] {
        let per = max(1, rows) * max(1, columns)
        guard imageCount > 0 else { return [0] }
        var remaining = imageCount
        var out: [Int] = []
        while remaining > 0 {
            let take = min(per, remaining)
            out.append(take)
            remaining -= take
        }
        return out
    }

    // MARK: - 版式指标

    /// 纸张(未摆正)+ 选项 → 全套版式指标。**纯函数**,方向由格网形状决定:
    /// 列多于行就用横向纸,否则纵向。
    ///
    /// - Note: 返回的 `pageSize` 是**已摆正**的(横向纸返回宽 > 高),
    ///   调用方据此建视图并把 `NSPrintInfo.orientation` 设为同一个方向。
    ///   `paperSize` 本身不交换——交换 + 方向会转两次。
    static func metrics(paperSize: CGSize,
                        options: ContactSheetOptions,
                        imageCount: Int) -> Metrics {
        let columns = max(1, options.columns)
        let rows = max(1, options.rows)
        let isLandscape = columns > rows

        let shortSide = min(paperSize.width, paperSize.height)
        let longSide = max(paperSize.width, paperSize.height)
        let pageSize = isLandscape
            ? CGSize(width: longSide, height: shortSide)
            : CGSize(width: shortSide, height: longSide)

        let resolvedTitleHeight = options.showFilenames ? titleHeight : 0
        let grid = grid(pageSize: pageSize, rows: rows, columns: columns,
                        inset: options.inset, spacing: options.spacing)

        let longestCellSide = max(grid.cellSize.width, grid.cellSize.height)
        let wanted = longestCellSide / 72 * printTargetDPI
        let maxPixel = min(max(wanted, thumbnailPixelRange.lowerBound),
                           thumbnailPixelRange.upperBound)

        return Metrics(
            pageSize: pageSize,
            rows: rows,
            columns: columns,
            cellSize: grid.cellSize,
            inset: max(0, options.inset),
            spacing: max(0, options.spacing),
            titleHeight: resolvedTitleHeight,
            perPage: rows * columns,
            pageCount: pageCount(imageCount: imageCount, rows: rows, columns: columns),
            thumbnailMaxPixel: maxPixel.rounded(.up)
        )
    }
}
