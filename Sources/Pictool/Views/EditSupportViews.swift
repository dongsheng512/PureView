import SwiftUI
import AppKit

/// 右键菜单 action 的 target:NSMenuItem 不持有 target,由调用方保活。
@MainActor
final class ContextActionBox: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: NSMenuItem?) {
        handler()
    }
}

/// 导出选项小弹层。选完格式、尺寸与隐私开关后再弹出系统存储面板只选路径。
struct ExportOptionsForm: View {
    @Binding var format: CropFormat
    @Binding var quality: Double
    @Binding var resizePreset: ExportResizePreset
    @Binding var customLongestSide: String
    @Binding var includeGPS: Bool
    @Binding var stripMetadata: Bool
    @Binding var watermark: WatermarkSettings
    var sourcePixelSize: CGSize
    var estimatedSizeText: String?
    var exporting: Bool
    var onExport: () -> Void
    var onWatermarkSettings: () -> Void

    private var customPixels: Int {
        Int(customLongestSide.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var outputSize: CGSize {
        resizePreset.outputPixelSize(sourcePixelSize: sourcePixelSize, customPixels: customPixels)
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 7) {
                HStack {
                    Text("格式")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("格式", selection: $format) {
                        ForEach(CropFormat.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
                // PNG / TIFF 无损,没有质量可言,整行不出现(而不是留个灰控件)
                if format.isLossy {
                    HStack(spacing: 8) {
                        Text("质量")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(value: $quality, in: ExportQuality.range)
                            .controlSize(.small)
                        Text(ExportQuality.percentLabel(quality))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                HStack {
                    Text("尺寸")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("尺寸", selection: $resizePreset) {
                        ForEach(ExportResizePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
                if resizePreset == .custom {
                    HStack(spacing: 6) {
                        Text("长边")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("像素", text: $customLongestSide)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                        Text("px")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Text("抹除 EXIF")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("抹除全部 EXIF 与隐私信息", isOn: $stripMetadata)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("开启后导出文件不携带相机参数、拍摄时间与 GPS 定位")
                }
                if !stripMetadata {
                    HStack {
                        Text("位置信息")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("包含位置信息", isOn: $includeGPS)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .labelsHidden()
                            .help("关闭后导出文件不带 GPS 坐标,EXIF 其余部分保留")
                    }
                }
                HStack {
                    Text("水印")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("启用水印", isOn: $watermark.enabled)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!watermark.hasContent)
                        .help(watermark.hasContent ? "导出时把水印烙进像素(画布已实时预览)"
                              : "先在「设置…」里配置水印文字或 Logo")
                    Button("设置…") { onWatermarkSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
            }

            if sourcePixelSize.width >= 1 {
                HStack(spacing: 4) {
                    Text("\(Int(outputSize.width)) × \(Int(outputSize.height))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let estimatedSizeText {
                        Text("≈ \(estimatedSizeText)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }

            Button(action: onExport) {
                Text("存储…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(exporting)
        }
        .padding(12)
        .frame(width: 224)
    }
}


/// 工具条内联 chip(文字档):小/中/大、实线/荧光、像素/平滑。
struct TextChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11))
                .frame(minWidth: 26)
                .frame(height: 20)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.14 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
    }
}

/// 工具条内联 chip(图标档):形状种类。
struct SymbolChip: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.14 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
    }
}

/// 调色弹层:一键自动增强 + 5 项常用 CoreImage 参数滑块。
struct AdjustmentsForm: View {
    @Binding var adjustments: ImageAdjustments
    let onBeginEditing: () -> Void
    let onToggleAutoEnhance: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("调色")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    onToggleAutoEnhance()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10, weight: .medium))
                        Text("自动增强")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(adjustments.autoEnhanced ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(adjustments.autoEnhanced
                                  ? Color.accentColor.opacity(0.14)
                                  : Color.primary.opacity(0.06))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("CoreImage 一键自动修正曝光、对比与白平衡")

                Button("重置") { onReset() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(adjustments.isIdentity ? .tertiary : .secondary)
                    .disabled(adjustments.isIdentity)
            }

            Divider()

            sliderRow(
                label: "曝光",
                value: $adjustments.exposure,
                range: -2.0...2.0,
                display: String(format: "%+.1f", adjustments.exposure),
                defaultValue: 0
            )
            sliderRow(
                label: "对比度",
                value: $adjustments.contrast,
                range: -0.5...0.5,
                display: String(format: "%+.0f", adjustments.contrast * 100),
                defaultValue: 0
            )
            sliderRow(
                label: "饱和度",
                value: $adjustments.saturation,
                range: -1.0...1.0,
                display: String(format: "%+.0f", adjustments.saturation * 100),
                defaultValue: 0
            )
            sliderRow(
                label: "色温",
                value: $adjustments.warmth,
                range: -1.0...1.0,
                display: String(format: "%+.0f", adjustments.warmth * 100),
                defaultValue: 0
            )
            sliderRow(
                label: "锐化",
                value: $adjustments.sharpness,
                range: 0.0...1.0,
                display: String(format: "%.0f", adjustments.sharpness * 100),
                defaultValue: 0
            )
        }
        .padding(12)
        .frame(width: 264)
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String,
        defaultValue: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
                .onTapGesture(count: 2) {
                    guard abs(value.wrappedValue - defaultValue) >= 0.001 else { return }
                    onBeginEditing()
                    value.wrappedValue = defaultValue
                }
                .help("双击重置\(label)")
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing { onBeginEditing() }
            })
            .controlSize(.small)
            Text(display)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
