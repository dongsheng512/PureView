import SwiftUI
import AppKit

/// 拼版打印的选项。
///
/// 纯值类型 + 无 AppKit 状态 → 自动 `Sendable`,可以直接跨线程交给解码任务。
///
/// - Note: 排期文档里原本给这一项留的名字是「统一方向」,但它没有可执行含义——
///   格网里的格子**永远**是等大的,「统一图片方向」无从谈起。真正需要用户决定的是
///   「几行几列」,所以这里落成 `rows` / `columns`,并把方向交由格网形状自动推导
///   (见 `ContactSheetLayout.metrics`)。
struct ContactSheetOptions: Equatable, Sendable {

    /// 从当前图起连续取多少张。
    var count: Int = 20
    /// 每页列数。
    var columns: Int = 4
    /// 每页行数。
    var rows: Int = 5
    /// 每张图下方标出文件名。
    var showFilenames: Bool = true
    /// 纸张内边距(点)。留出打印机硬件不可印边,避免最外圈被裁掉。
    var inset: CGFloat = 22
    /// 格间距(点)。
    var spacing: CGFloat = 10

    var perPage: Int { max(1, columns) * max(1, rows) }

    // MARK: 合法范围

    static let countRange = 1...200
    static let columnsRange = 1...10
    static let rowsRange = 1...10

    // MARK: 跨会话记忆

    static let countKey = "contactSheetCount"
    static let columnsKey = "contactSheetColumns"
    static let rowsKey = "contactSheetRows"
    static let filenamesKey = "contactSheetShowFilenames"

    /// 把各字段夹进合法范围。用户手改 UserDefaults 或可用图片数变少时都要走一遍,
    /// 否则会出现「0 张」「0 列」这种把版式算成空帧的取值。
    func clamped(availableCount: Int) -> ContactSheetOptions {
        var out = self
        let upper = max(1, min(availableCount, ContactSheetOptions.countRange.upperBound))
        out.count = min(max(count, 1), upper)
        out.columns = min(max(columns, ContactSheetOptions.columnsRange.lowerBound),
                          ContactSheetOptions.columnsRange.upperBound)
        out.rows = min(max(rows, ContactSheetOptions.rowsRange.lowerBound),
                       ContactSheetOptions.rowsRange.upperBound)
        out.inset = inset.isFinite ? max(0, inset) : 22
        out.spacing = spacing.isFinite ? max(0, spacing) : 10
        return out
    }

    /// 从 UserDefaults 读回上次用的选项;没存过就保持默认值。
    /// 没记 `inset` / `spacing`(它们没有 UI,记了也只是多两份可能被改坏的状态)。
    static func loadFromDefaults(_ defaults: UserDefaults = .standard) -> ContactSheetOptions {
        var out = ContactSheetOptions()
        if defaults.object(forKey: countKey) != nil { out.count = defaults.integer(forKey: countKey) }
        if defaults.object(forKey: columnsKey) != nil { out.columns = defaults.integer(forKey: columnsKey) }
        if defaults.object(forKey: rowsKey) != nil { out.rows = defaults.integer(forKey: rowsKey) }
        if defaults.object(forKey: filenamesKey) != nil { out.showFilenames = defaults.bool(forKey: filenamesKey) }
        return out
    }

    func saveToDefaults(_ defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: Self.countKey)
        defaults.set(columns, forKey: Self.columnsKey)
        defaults.set(rows, forKey: Self.rowsKey)
        defaults.set(showFilenames, forKey: Self.filenamesKey)
    }
}

/// 拼版选项弹层。
struct ContactSheetOptionsForm: View {

    @Binding var options: ContactSheetOptions
    /// 当前图起还剩几张可选,决定「张数」上限。
    let availableCount: Int
    /// 版式指标(用于显示「几列 × 几行 · 共 N 页」)。
    let metrics: ContactSheetLayout.Metrics
    /// 正在解码/准备中,禁用按钮防止连点。
    var preparing: Bool
    var onCancel: () -> Void
    var onPrint: () -> Void

    private var effectiveCount: Int {
        min(max(options.count, 1), max(1, availableCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拼版打印")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 10) {
                optionRow("张数") {
                    Stepper(value: $options.count,
                            in: 1...max(1, availableCount),
                            step: 1) {
                        Text("\(effectiveCount) 张")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
                optionRow("格网") {
                    HStack(spacing: 6) {
                        Stepper(value: $options.columns,
                                in: ContactSheetOptions.columnsRange,
                                step: 1) {
                            Text("\(options.columns) 列")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .controlSize(.small)
                        Stepper(value: $options.rows,
                                in: ContactSheetOptions.rowsRange,
                                step: 1) {
                            Text("\(options.rows) 行")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .controlSize(.small)
                    }
                }
                optionRow("文件名") {
                    Toggle("在每张图下标注", isOn: $options.showFilenames)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }

            Divider()

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("打印…", action: onPrint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preparing)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var summary: String {
        let direction = metrics.isLandscape ? "横向" : "纵向"
        let total = effectiveCount
        return "\(metrics.columns) 列 × \(metrics.rows) 行 · \(direction)纸 · "
            + "共 \(total) 张 → \(metrics.pageCount) 页"
    }

    private func optionRow<Content: View>(_ label: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
    }
}
