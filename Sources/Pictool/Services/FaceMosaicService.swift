import CoreGraphics
import Vision

/// 使用 macOS 原生 Vision 框架检测人脸，返回归一化坐标(左上原点 0...1)的遮盖矩形。
enum FaceMosaicService {

    /// 检测图像中的人脸区域并外扩少量边距，直接对应 PureView 归一化坐标系。
    static func detectFaceRects(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results, !results.isEmpty else { return [] }
        return results.compactMap { face in
            let b = face.boundingBox
            guard b.width > 0.005, b.height > 0.005 else { return nil }
            // Vision 坐标系原点在左下，转成左上原点，并四周外扩 12% 完整遮盖脸部
            let topLeft = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let padX = topLeft.width * 0.12
            let padY = topLeft.height * 0.12
            let expanded = topLeft.insetBy(dx: -padX, dy: -padY)
            let minX = max(0, expanded.minX)
            let minY = max(0, expanded.minY)
            let maxX = min(1, expanded.maxX)
            let maxY = min(1, expanded.maxY)
            guard maxX > minX, maxY > minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
