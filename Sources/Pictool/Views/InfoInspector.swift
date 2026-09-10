import SwiftUI
import AppKit

/// 右侧信息面板:文件 / 图像 / 拍摄信息(EXIF) / GPS,支持一键复制
struct InfoInspector: View {

    let file: ImageFile?
    @State private var info: ImageInfo?
    /// 当前图的亮度/颜色分布。从 512px 的**降采样**位图算,不碰原图。
    @State private var histogram: Histogram?
    // 窗口背景是透明的(.inspector 会透出去),面板自己铺当前画布背景色;AppStorage 保证设置里改背景时实时同步
    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue

    var body: some View {
        Group {
            if let file {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        histogramCard
                        if let info {
                            ForEach(info.sections) { section in
                                sectionView(section)
                            }
                        } else {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.top, 30)
                        }
                    }
                    .padding(12)
                }
                .task(id: file.id) {
                    info = nil
                    histogram = nil
                    let url = file.url
                    // 两件事都只读一个共同输入(文件),并行跑;直方图读的是 512px 小图,
                    // 与主画布那条 2048px 起的预览解码互不干扰。
                    async let parsedInfo = Task.detached(priority: .utility) {
                        MetadataService.info(for: url)
                    }.value
                    async let distribution = Task.detached(priority: .utility) { () -> Histogram in
                        guard let image = try? ImageLoader.decode(url: url, maxPixelSize: 512),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        else { return .empty }
                        return Histogram.compute(from: cgImage)
                    }.value
                    let (metadata, bins) = await (parsedInfo, distribution)
                    // task(id:) 在文件切换时会取消旧任务;以此挡住迟到的旧结果覆盖新图信息
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.12)) {
                        info = metadata
                        histogram = bins
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("打开图片后显示信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Text("图片信息")
                    .font(.headline)
                Spacer()
                Button {
                    copyInfo()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(info == nil)
                .help("复制全部信息")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 扁平:与面板同色纯底,不带材质厚度;仅靠底部细线与内容分界
            .background(ChromeTheme.fill(canvasBackground))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.separator.opacity(0.5))
                    .frame(height: 1)
            }
        }
        .background(ChromeTheme.fill(canvasBackground).ignoresSafeArea())
        .environment(\.colorScheme, ChromeTheme.colorScheme(for: canvasBackground))
    }

    /// 直方图卡片。位图还没算出来、或图完全解不出来(全空)时整块不占位。
    @ViewBuilder
    private var histogramCard: some View {
        if let histogram, !histogram.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("直方图")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                HistogramChart(histogram: histogram)
                    .frame(height: 76)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quinary)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            )
        }
    }

    private func sectionView(_ section: InfoSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(section.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quinary)
                // 面板底色和画布同色,卡片加一圈细描边才有层次
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        )
    }

    private func copyInfo() {
        guard let info else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.summaryText, forType: .string)
    }
}

/// 直方图绘制:黑底 + 三通道加色混合,重叠处自然变白,和预览/PS 的观感一致。
/// 纵向按三通道**共同**的峰值归一化,所以各通道的相对高低是可直接比较的。
private struct HistogramChart: View {

    let histogram: Histogram

    private var channels: [(counts: [Int], color: Color)] {
        [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            context.blendMode = .plusLighter
            let step = size.width / CGFloat(Histogram.binCount - 1)
            for channel in channels {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in histogram.normalized(channel.counts).enumerated() {
                    path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                             y: size.height * (1 - CGFloat(value))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(channel.color.opacity(0.7)))
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .accessibilityLabel("直方图")
    }
}
