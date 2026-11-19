import SwiftUI

/// 幻灯片控制条:底部居中悬浮玻璃面板，包含文件名/进度拖拽、随机/循环、
/// 带倒计时圆环的播放/暂停、间隔切换、Ken Burns 动态缓动缩放开关及结束会话。
/// **只在幻灯片会话里存在** —— 会话开始浮现一次、静止 2.5 秒淡出、鼠标移到窗口底边可再叫出来。
struct SlideshowHUD: View {
    let playing: Bool
    var canPlay: Bool = true
    let fileName: String
    let currentIndex: Int
    let totalCount: Int
    let intervalLabel: String
    let intervalSeconds: Double
    let tickStart: Date
    let tickToken: Int
    let shuffle: Bool
    let loop: Bool
    let kenBurns: Bool
    let onPrev: () -> Void
    let onToggle: () -> Void
    let onNext: () -> Void
    let onJump: (Int) -> Void
    let onCycleInterval: () -> Void
    let onToggleShuffle: () -> Void
    let onToggleLoop: () -> Void
    let onToggleKenBurns: () -> Void
    let onExit: () -> Void

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var positionText: String {
        "\(min(max(currentIndex + 1, 1), max(totalCount, 1))) / \(max(totalCount, 1))"
    }

    var body: some View {
        VStack(spacing: 6) {
            // 顶部信息与进度拖拽条
            if totalCount > 1 {
                HStack(spacing: 8) {
                    Text(fileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(positionText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : Double(max(currentIndex, 0)) },
                        set: { newValue in
                            scrubValue = newValue
                            let target = Int(newValue.rounded())
                            if target != currentIndex {
                                onJump(target)
                            }
                        }
                    ),
                    in: 0...Double(max(totalCount - 1, 1)),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if editing { scrubValue = Double(max(currentIndex, 0)) }
                    }
                )
                .controlSize(.mini)
            }

            // 主控制行
            HStack(spacing: 10) {
                hudToggleButton("shuffle", active: shuffle, help: "随机播放", action: onToggleShuffle)
                hudToggleButton("repeat", active: loop, help: "循环播放", action: onToggleLoop)

                Divider().frame(height: 16)

                hudButton("chevron.left", help: "上一张 (←)", action: onPrev)
                playPauseRingButton
                hudButton("chevron.right", help: "下一张 (→)", action: onNext)

                Divider().frame(height: 16)

                Button(action: onCycleInterval) {
                    Text(intervalLabel)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, minHeight: 22)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("播放间隔(点击切换)")

                hudToggleButton("sparkles", active: kenBurns, help: "动态缓动缩放 (Ken Burns)", action: onToggleKenBurns)

                Divider().frame(height: 16)

                hudButton("xmark", help: "退出幻灯片 (Esc)", action: onExit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 368)
        .background {
            AdaptiveGlassSurface(
                shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                legacyStroke: AnyShapeStyle(.separator),
                shadowOpacity: 0.14
            )
        }
    }

    /// 带平滑倒计时进度圆环的播放/暂停按钮
    private var playPauseRingButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1.8)
                if playing, intervalSeconds > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(tickStart))
                        let progress = min(1, elapsed / intervalSeconds)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .id(tickToken)
                }
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .offset(x: playing ? 0 : 1)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : 0.35)
        .help(playing ? "暂停 (空格)" : "继续播放 (空格)")
    }

    private func hudButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }

    private func hudToggleButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 24)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
