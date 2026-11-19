import Foundation

/// 非破坏图像调色参数。所有字段默认 0 / false，处于 identity 时渲染管线零开销直通。
struct ImageAdjustments: Equatable, Sendable {
    /// 系统 CoreImage 一键自动增强（曝光 / 对比 / 白平衡）
    var autoEnhanced: Bool = false
    /// 曝光 (-2.0 ... +2.0 EV)
    var exposure: Double = 0
    /// 对比度 (-0.5 ... +0.5，映射为 CIColorControls.inputContrast = 1 + contrast)
    var contrast: Double = 0
    /// 饱和度 (-1.0 ... +1.0，映射为 CIColorControls.inputSaturation = 1 + saturation)
    var saturation: Double = 0
    /// 色温 (-1.0 冷 ... +1.0 暖)
    var warmth: Double = 0
    /// 锐化 (0 ... 1.0)
    var sharpness: Double = 0

    var isIdentity: Bool {
        !autoEnhanced
            && abs(exposure) < 0.001
            && abs(contrast) < 0.001
            && abs(saturation) < 0.001
            && abs(warmth) < 0.001
            && sharpness < 0.001
    }
}
