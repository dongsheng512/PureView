import AppKit
import ImageIO
import QuickLookThumbnailing

/// 缩略图生成与缓存:优先使用 macOS 原生 QuickLookThumbnailing(复用系统级磁盘与内存缩略图缓存),
/// 失败时回退 ImageIO 降采样解码;内存级 NSCache + 合并重复请求 + 精准取消。
final class ThumbnailProvider: @unchecked Sendable {

    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private let fallbackQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "pictool.thumbnails"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private let lock = NSLock()
    private var inFlight: [NSURL: [(NSImage?) -> Void]] = [:]
    private var activeQLRequests: [NSURL: QLThumbnailGenerator.Request] = [:]

    init() {
        cache.countLimit = 900
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 源文件被覆盖写回后移除旧缓存,避免网格继续命中修改前的缩略图。
    func invalidate(url: URL) {
        cache.removeObject(forKey: url as NSURL)
        cache.removeObject(forKey: url.standardizedFileURL as NSURL)
    }

    func thumbnail(for url: URL, maxPixel: CGFloat = 180, isVisible: Bool = false, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let hit = cachedThumbnail(for: url) {
            Task { @MainActor in completion(hit) }
            return
        }
        let key = url as NSURL
        lock.lock()
        inFlight[key, default: []].append { image in
            Task { @MainActor in completion(image) }
        }
        let needsStart = (inFlight[key]?.count ?? 0) == 1
        lock.unlock()
        guard needsStart else { return }

        // 优先走 macOS 原生 QuickLookThumbnailing:
        // 直接复用系统级缩略图缓存(Finder 看过的目录毫秒级秒出),原生支持 RAW/PSD/HEIC/AVIF 等格式。
        let scale: CGFloat = 2.0
        let pointSide = max(32, maxPixel / scale)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSide, height: pointSide),
            scale: scale,
            representationTypes: .thumbnail
        )
        lock.lock()
        activeQLRequests[key] = request
        lock.unlock()

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let self else { return }
            self.lock.lock()
            let stillTracked = self.activeQLRequests.removeValue(forKey: key) != nil
            self.lock.unlock()
            guard stillTracked else { return }

            if let rep {
                let cg = rep.cgImage
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.finishRequest(key: key, image: image)
                return
            }
            // 系统 QuickLook 无法生成时(如临时目录/特殊截断文件)无缝回退 ImageIO 降采样解码
            let op = BlockOperation { [weak self] in
                guard let self else { return }
                let image = Self.generate(url: url, maxPixel: maxPixel)
                self.finishRequest(key: key, image: image)
            }
            op.queuePriority = isVisible ? .high : .normal
            op.qualityOfService = isVisible ? .userInitiated : .utility
            self.fallbackQueue.addOperation(op)
        }
    }

    private func finishRequest(key: NSURL, image: NSImage?) {
        if let image {
            // 精确 cost:用 CG 位图像素,避免 NSImage.size 为 points 时低估 4x
            let cost: Int
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cost = cg.bytesPerRow * cg.height
            } else {
                cost = Int(image.size.width * image.size.height * 4)
            }
            cache.setObject(image, forKey: key, cost: max(cost, 1))
        }
        lock.lock()
        let waiters = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters { waiter(image) }
    }

    func asyncThumbnail(for url: URL, maxPixel: CGFloat = 180, isVisible: Bool = false) async -> NSImage? {
        await withCheckedContinuation { cont in
            thumbnail(for: url, maxPixel: maxPixel, isVisible: isVisible) { cont.resume(returning: $0) }
        }
    }

    /// ImageIO 缩略图:不整图解码、自动应用 EXIF 方向(拼版打印与 QuickLook 失败兜底共用)
    static func generate(url: URL, maxPixel: CGFloat) -> NSImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        // 1) 优先吃内嵌缩略图（IfAbsent:false）。命中且尺寸够用时是零解码路径：
        //    实测 4000×3000 JPEG 内嵌 160×120 缩略图时 0.1ms，而整图缩放解码 5.9ms，差约 60 倍。
        let embeddedOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOpts as CFDictionary)
        if let embedded, CGFloat(max(embedded.width, embedded.height)) >= maxPixel {
            return NSImage(cgImage: embedded, size: NSSize(width: embedded.width, height: embedded.height))
        }
        // 2) 内嵌图不存在、或小于请求尺寸（EXIF 标准缩略图常见只有 160×120，直接铺到网格会发糊）
        //    → 用 FromImageAlways 强制从整图做缩放解码。
        let scaledOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, scaledOpts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // 3) 整图解不出来（截断 / 写坏的相机文件）时，宁可用小一点的内嵌图，
        //    也不要让网格退回"无法解码"图标。
        if let embedded {
            return NSImage(cgImage: embedded, size: NSSize(width: embedded.width, height: embedded.height))
        }
        return nil
    }

    func cancelAll() {
        fallbackQueue.cancelAllOperations()
        lock.lock()
        let qlRequests = activeQLRequests.values
        activeQLRequests.removeAll()
        let abandoned = inFlight
        inFlight.removeAll()
        lock.unlock()
        for req in qlRequests {
            QLThumbnailGenerator.shared.cancel(req)
        }
        // 必须把等待者唤醒。withCheckedContinuation 不响应取消,直接丢弃回调数组
        // 会让每个等待方的 Task 永久挂在 continuation 上——切一次文件夹泄漏一批。
        for waiters in abandoned.values { for waiter in waiters { waiter(nil) } }
    }
}
