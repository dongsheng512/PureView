import CoreImage
import CoreGraphics

/// CoreImage GPU 调色管线：预览与导出共用同一套滤镜链，保证所见即所得。
enum ImageAdjustmentService {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 对位图应用调色参数。处于 identity 时直接原图返回（零拷贝）。
    static func apply(_ adjustments: ImageAdjustments, to image: CGImage) -> CGImage {
        guard !adjustments.isIdentity else { return image }
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if adjustments.autoEnhanced {
            let filters = ci.autoAdjustmentFilters(options: [.redEye: false])
            for filter in filters {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    ci = output
                }
            }
        }

        if abs(adjustments.exposure) >= 0.001,
           let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(adjustments.exposure, forKey: kCIInputEVKey)
            if let output = filter.outputImage { ci = output }
        }

        if abs(adjustments.contrast) >= 0.001 || abs(adjustments.saturation) >= 0.001,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(max(0.25, 1.0 + adjustments.contrast), forKey: kCIInputContrastKey)
            filter.setValue(max(0.0, 1.0 + adjustments.saturation), forKey: kCIInputSaturationKey)
            if let output = filter.outputImage { ci = output }
        }

        if abs(adjustments.warmth) >= 0.001,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            // inputNeutral 设为源白点色温，映射到目标 6500K：
            // 源白点偏高（如 8500K）校正到 6500K 会补暖色（+warmth 偏暖）；反之偏冷。
            let neutralTemp = 6500.0 + adjustments.warmth * 2200.0
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: neutralTemp, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let output = filter.outputImage { ci = output }
        }

        if adjustments.sharpness >= 0.001,
           let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(adjustments.sharpness * 0.85, forKey: kCIInputSharpnessKey)
            if let output = filter.outputImage { ci = output }
        }

        return ciContext.createCGImage(ci.cropped(to: extent), from: extent) ?? image
    }
}
