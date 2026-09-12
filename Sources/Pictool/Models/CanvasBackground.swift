import AppKit

/// 画布背景偏好(存入 UserDefaults 的原始值为 rawValue)
enum CanvasBackground: String, CaseIterable, Identifiable {

    case dark
    case light
    /// 磨砂玻璃(2026-09-12 加)。**这一档不做实色填充** —— 它让画布与顶栏都交出底色,
    /// 由窗口最底层那层 `NSVisualEffectView`(见 `GlassBackdrop`)透出并模糊桌面。
    ///
    /// ⚠️ 它和 `.dark` / `.light` **不是同一类东西**:那两档回答「画布是什么颜色」,
    /// 这一档回答「画布没有颜色」。所以凡是在问前一个问题的判断,都别用 `isDark` 去问它 ——
    /// 见 `isTranslucent` 与 `prefersDarkChrome` 这两个分开的属性。
    case frosted

    static let storageKey = "canvasBackground"
    static let defaultValue = CanvasBackground.light

    /// 画布是否透出桌面。为真时必须同时满足三件事,缺一个就看不到磨砂:
    /// ①`color` 无意义、`fill` 不画;②`CanvasClipView.isOpaque` 为 false;
    /// ③`NSScrollView.drawsBackground` 关掉。
    var isTranslucent: Bool { self == .frosted }

    /// 派生界面(侧栏材质明暗、顶栏文字、分隔线)该按深色还是浅色渲染。
    /// **别把它和「画布是不是黑的」当成同一个判断** —— 加磨砂档之前这两件事合用一个
    /// `isDark` 属性,磨砂档一来就分家了:它没有自己的底色,但界面仍要按深色渲染
    /// (macOS「深色磨砂」,本机深色外观下与系统观感一致)。将来若要让它跟随系统外观,只改这一处。
    var prefersDarkChrome: Bool { self == .dark || self == .frosted }

    /// 旧版「棋盘格」收成白色。
    /// 另:`matte` 是同日短暂加过、**未发布就否掉**的一档(哑光灰实色,
    /// dongsheng 要的其实是磨砂玻璃),迁移到磨砂档,免得他本地已选中的设置静默跳回白色。
    static func normalizeStoredValue() {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        if stored == "checkerboard" {
            UserDefaults.standard.set(CanvasBackground.light.rawValue, forKey: storageKey)
        } else if stored == "matte" {
            UserDefaults.standard.set(CanvasBackground.frosted.rawValue, forKey: storageKey)
        }
    }

    var id: String { rawValue }

    var color: NSColor {
        switch self {
        case .dark: NSColor(white: 0.10, alpha: 1)
        // 柔和米白 #FAFAFB，避免纯白与侧栏灰的生硬对比
        case .light: NSColor(red: 0.980, green: 0.980, blue: 0.984, alpha: 1)
        // 磨砂档没有底色,由窗口背后的材质呈现
        case .frosted: NSColor.clear
        }
    }

    var label: String {
        switch self {
        case .dark: "黑色"
        case .light: "白色"
        case .frosted: "磨砂"
        }
    }

    func fill(_ dirtyRect: NSRect) {
        guard !isTranslucent else { return }
        color.setFill()
        dirtyRect.fill()
    }
}
