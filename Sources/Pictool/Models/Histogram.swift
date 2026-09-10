import CoreGraphics

/// 直方图:256 桶 × RGB。
///
/// 纯计算、不碰 AppKit —— 输入 `CGImage`、输出可比较的值类型,所以能直接单测。
///
/// 统计前会先等比降采样到 `maxSide` 以内:直方图是**分布**统计,几百像素就足够稳定,
/// 而原图可能是 40MP(通读一遍就是 160MB 的像素流量)。
struct Histogram: Equatable {

    /// 每通道桶数。
    static let binCount = 256

    /// 每桶像素数,下标 = 0...255 的通道值。
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    /// 参与统计的像素总数(降采样之后)。
    var sampleCount: Int

    static let empty = Histogram(red: [], green: [], blue: [], sampleCount: 0)

    var isEmpty: Bool { sampleCount == 0 }

    /// 三通道中最高的单桶计数。用于纵向归一化 —— 取单通道峰值而不是总和,
    /// 否则纯色图的尖峰会把另外两个通道压成一条平线。
    var peak: Int {
        max(red.max() ?? 0, max(green.max() ?? 0, blue.max() ?? 0))
    }

    /// 把某个通道换算成 0...1 的高度序列。空图或长度不对时给全零,不返回 NaN。
    func normalized(_ counts: [Int]) -> [Double] {
        let top = peak
        guard top > 0, counts.count == Self.binCount else {
            return Array(repeating: 0, count: Self.binCount)
        }
        return counts.map { Double($0) / Double(top) }
    }

    /// 从位图统计。
    ///
    /// 先铺白底再画图:带 alpha 的 PNG 若直接按**预乘**值统计,透明区域会被记成全黑,
    /// 直方图会凭空多出一根贴左的假尖峰。
    static func compute(from image: CGImage, maxSide: Int = 512) -> Histogram {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return .empty }

        let cap = max(1, maxSide)
        let scale = min(1, CGFloat(cap) / CGFloat(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        let bytesPerRow = width * 4

        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let tallied: (red: [Int], green: [Int], blue: [Int], count: Int)? =
            buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: bytesPerRow,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }

                let canvas = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(canvas)
                context.interpolationQuality = .medium
                context.draw(image, in: canvas)

                // 注意:这里只能走 raw 绑定的指针,不能再碰上面的 buffer 数组 ——
                // withUnsafeMutableBytes 期间重复访问会被独占性检查拦下。
                let pixels = raw.bindMemory(to: UInt8.self)
                var red = [Int](repeating: 0, count: binCount)
                var green = red
                var blue = red
                var count = 0
                for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
                    red[Int(pixels[offset])] += 1
                    green[Int(pixels[offset + 1])] += 1
                    blue[Int(pixels[offset + 2])] += 1
                    count += 1
                }
                return (red, green, blue, count)
            }

        guard let tallied else { return .empty }
        return Histogram(red: tallied.red,
                         green: tallied.green,
                         blue: tallied.blue,
                         sampleCount: tallied.count)
    }
}
