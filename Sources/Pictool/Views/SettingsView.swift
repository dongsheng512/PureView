import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 偏好设置窗口(⌘,)
struct SettingsView: View {

    @AppStorage(CanvasBackground.storageKey) private var canvasBackground = CanvasBackground.defaultValue
    @AppStorage(SidebarTopStyle.storageKey) private var sidebarTopStyle = SidebarTopStyle.defaultValue
    @AppStorage(OpenZoomMode.storageKey) private var openZoomMode = OpenZoomMode.defaultValue
    @AppStorage(WrapNavigation.storageKey) private var wrapNavigation = WrapNavigation.defaultValue
    @AppStorage(ImageSortKey.storageKey) private var sortKey = ImageSortKey.defaultValue
    @AppStorage(ImageSortDirection.storageKey) private var sortDirection = ImageSortDirection.defaultValue
    @AppStorage(SlideShowInterval.storageKey) private var slideshowInterval = SlideShowInterval.defaultValue
    @State private var watermark = WatermarkSettings.load()

    var body: some View {
        Form {
            Section("外观") {
                Picker("画布背景", selection: $canvasBackground) {
                    ForEach(CanvasBackground.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("侧栏顶栏", selection: $sidebarTopStyle) {
                    ForEach(SidebarTopStyle.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section("浏览") {
                Picker("打开时缩放", selection: $openZoomMode) {
                    ForEach(OpenZoomMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("到首尾后循环", isOn: $wrapNavigation)
                Picker("排序", selection: $sortKey) {
                    ForEach(ImageSortKey.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("顺序", selection: $sortDirection) {
                    ForEach(ImageSortDirection.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("幻灯片间隔", selection: $slideshowInterval) {
                    ForEach(SlideShowInterval.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            // R5:原标题「水印(标记导出时生效)」把语义说窄了 —— 这份设置同时也是编辑、
            // 拼版打印用的水印,而且在编辑态改动会回写保存。标题改为「默认」,关系写进脚注。
            Section {
                WatermarkSettingsForm(settings: $watermark)
            } header: {
                Text("水印(编辑导出时的默认)")
            } footer: {
                Text("进入编辑后,也可在顶栏的水印按钮里直接调整 —— 改动同样会保存为默认。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { CanvasBackground.normalizeStoredValue() }
        .onChange(of: watermark) { _, value in value.save() }
    }
}

/// 水印表单。偏好窗口和编辑顶栏弹层共用;不要从模态 sheet 去唤系统设置窗口。
struct WatermarkSettingsForm: View {
    @Binding var settings: WatermarkSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用水印", isOn: $settings.enabled)
            TextField("水印文字", text: $settings.text)
                .textFieldStyle(.roundedBorder)
                .disabled(settings.useLogo && settings.logoPath != nil)
            Toggle("使用图片水印", isOn: $settings.useLogo)
            if settings.useLogo {
                logoRow
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    sliderRow("透明度", value: $settings.opacity, range: 0.15...1.0)
                    sliderRow("大小", value: $settings.sizeFraction, range: 0.012...0.10)
                    Toggle("平铺", isOn: $settings.tiled)
                    if settings.tiled {
                        sliderRow("间距", value: $settings.tileSpacing, range: 0.08...0.55)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    WatermarkPositionGrid(position: $settings.position) {
                        settings.tiled = false
                    }
                    .opacity(settings.tiled ? 0.4 : 1)
                    if settings.tiled {
                        Text("点选关闭平铺")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            settings.sizeFraction = min(max(settings.sizeFraction, 0.012), 0.10)
            settings.tileSpacing = min(max(settings.tileSpacing, 0.08), 0.55)
        }
    }

    private var logoRow: some View {
        HStack(spacing: 8) {
            Text(settings.logoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未选择 logo")
                .font(.caption)
                .foregroundStyle(settings.logoPath == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("选择 PNG…") { pickLogo() }
                .controlSize(.small)
            if settings.logoPath != nil {
                Button("清除") {
                    WatermarkSettings.clearLogoFile()
                    settings.logoPath = nil
                }
                .controlSize(.small)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let path = try? WatermarkSettings.installLogo(from: url) {
            settings.logoPath = path
        } else {
            settings.logoPath = url.path
        }
    }
}

/// 九宫格锚点。点选某一格时关掉平铺,否则位置看起来像调了其实没生效。
private struct WatermarkPositionGrid: View {
    @Binding var position: WatermarkPosition
    var onPick: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        let item = WatermarkPosition.allCases[row * 3 + col]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(position == item ? Color.pvAccent : Color.primary.opacity(0.14))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPick()
                                position = item
                            }
                            .help(item.label)
                    }
                }
            }
        }
        .padding(5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}


