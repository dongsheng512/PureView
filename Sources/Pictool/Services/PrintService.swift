import AppKit

@MainActor
enum PrintService {

    /// 标准打印面板:视图按图片点尺寸排版,缩放百分比由 AppKit 作用到预览。
    /// 100% = 原图 72dpi 实际大小;打开时把百分比设为「刚好铺满当前纸张」,之后拖动即按正常百分比缩放。
    static func print(image: NSImage) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isVerticallyCentered = true
        info.isHorizontallyCentered = true
        // 原生缩放本身不要求留白。边距 0,初始百分比按整张纸计算,避免「可印区域」
        // (打印机硬件边 + 默认 1 英寸页边)把图缩在纸心。
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0

        let imgSize = PrintPageView.imageAspect(image)
        if imgSize.width > 0, imgSize.height > 0 {
            info.orientation = imgSize.width >= imgSize.height ? .landscape : .portrait
        }

        info.scalingFactor = PrintPageView.fitScale(imageSize: imgSize, paperSize: info.paperSize)

        let view = PrintPageView(image: image)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.canSpawnSeparateThread = false
        // 纸张和方向都露出来。改其中任意一个时,下面的 follower 会把百分比重算成新的铺满值。
        operation.printPanel.options = [
            .showsCopies, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview,
        ]
        let follower = PrintScaleFollower(info: info, imageSize: imgSize)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
        follower.invalidate()
    }

    // MARK: - 拼版(联系表)

    /// 拼版:按**当前纸张**算出全套版式指标。
    ///
    /// 之所以要单独暴露:缩略图必须在打开打印面板**之前**按格子像素尺寸去解码,
    /// 而这个尺寸只有算完版式才知道。`print(contactSheet:options:)` 内部用的是同一套
    /// 计算(同一个 `NSPrintInfo.shared.paperSize`),所以两边算出来的格子尺寸是一致的。
    static func contactSheetMetrics(options: ContactSheetOptions,
                                    imageCount: Int) -> ContactSheetLayout.Metrics {
        ContactSheetLayout.metrics(paperSize: NSPrintInfo.shared.paperSize,
                                   options: options,
                                   imageCount: imageCount)
    }

    /// 拼版打印。与单张路径**并列**,单张路径一行未改。
    ///
    /// 版式(几列几行、每格多少点、预留文件名条)全部在页内算好,所以:
    /// - 用**显式分页**(`knowsPageRange` / `rectForPage`),而不是单张路径的 `clip`;
    /// - `scalingFactor = 1`,面板里也不提供缩放,否则百分比会把整个格网再缩一次;
    /// - 面板里不提供换纸/换方向——版式在打开面板前就按当时的纸张定死了。
    ///   改纸请先取消,在系统里换默认纸再重开。
    static func print(contactSheet items: [ContactSheetItem], options: ContactSheetOptions) {
        guard !items.isEmpty else { return }

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        // 与单张路径一致:边距 0,不可印边靠 ContactSheetOptions.inset 让开。
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0
        info.isVerticallyCentered = true
        info.isHorizontallyCentered = true
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.scalingFactor = 1

        let metrics = ContactSheetLayout.metrics(paperSize: info.paperSize,
                                                 options: options,
                                                 imageCount: items.count)
        info.orientation = metrics.isLandscape ? .landscape : .portrait

        let view = ContactSheetView(metrics: metrics, items: items)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.canSpawnSeparateThread = false
        operation.printPanel.options = [.showsCopies, .showsPageRange, .showsPreview]
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// 文档就是图片本身。分页/缩放交给 NSPrintOperation,预览才能跟着百分比走。
final class PrintPageView: NSView {

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        let size = Self.imageAspect(image)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    static func imageAspect(_ image: NSImage) -> NSSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }
        return image.size
    }

    /// 铺满整张纸所需的缩放(面板百分比 = 此值 × 100)。
    /// 纯几何,不碰 AppKit 状态,所以 nonisolated——单测与非 UI 代码都能直接调。
    nonisolated static func fitScale(imageSize: NSSize, paperSize: NSSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, paperSize.width > 0, paperSize.height > 0 else {
            return 1
        }
        return min(paperSize.width / imageSize.width, paperSize.height / imageSize.height)
    }

    /// 当前纸张长边在 300dpi 下的像素。纸张尺寸是点(1/72 英寸)。
    /// 小相纸少解一点,A3 比固定的 3600 更够用。
    nonisolated static func printMaxPixel(paperSize: NSSize) -> CGFloat {
        let longest = max(paperSize.width, paperSize.height)
        guard longest > 0 else { return 3600 }
        return longest / 72 * ContactSheetLayout.printTargetDPI
    }

    /// 裁切只占整图的一部分时,解码要放大到让裁出来的那块仍够铺满纸。
    /// 整图(边长为 1)时与 `printMaxPixel` 相同。
    nonisolated static func decodeMaxPixel(paperSize: NSSize, normalizedRect: CGRect) -> CGFloat {
        let paper = printMaxPixel(paperSize: paperSize)
        let span = max(normalizedRect.width, normalizedRect.height)
        guard span > 0.001 else { return paper }
        return paper / min(span, 1)
    }
}

/// 打印面板里改纸张或方向后,把缩放百分比重新设成「刚好铺满」。
/// 用户拖过的百分比只在纸张没变时保留;纸一变,旧百分比会裁切或留出大块空白。
private final class PrintScaleFollower: NSObject, @unchecked Sendable {
    private let imageSize: NSSize
    private var observations: [NSKeyValueObservation] = []

    init(info: NSPrintInfo, imageSize: NSSize) {
        self.imageSize = imageSize
        super.init()
        observations = [
            info.observe(\.paperSize, options: [.new]) { [weak self] info, _ in
                self?.refit(info)
            },
            info.observe(\.orientation, options: [.new]) { [weak self] info, _ in
                self?.refit(info)
            },
        ]
    }

    func invalidate() {
        observations.removeAll()
    }

    /// 方向和纸张会先后通知。后一次读到的 paperSize 已经是新纸,百分比跟着铺满。
    private func refit(_ info: NSPrintInfo) {
        let scale = PrintPageView.fitScale(imageSize: imageSize, paperSize: info.paperSize)
        if abs(info.scalingFactor - scale) > 0.0001 {
            info.scalingFactor = scale
        }
    }
}
