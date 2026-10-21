#if os(iOS)
import CoreGraphics
import CoreVideo
import Foundation
import Vision
import BokehCore

/// 系统自带的人像分割（Vision 的 VNGeneratePersonSegmentationRequest）。
///
/// 深度测不到细的、伸出去的东西：侧脸时远处那片眼镜伸出脸的轮廓，后面就是背景，深度图上那里全是背景的深度，
/// 于是镜框和镜片被当成背景虚化掉，看起来蒙了一层。系统相机人像模式也是靠人像分割把整个人（包括眼镜、头发边缘）
/// 留在清晰范围里。对焦点落在人身上时，SubjectMatte 用这张遮罩把和对焦点连着的那个人整体保持清晰。
///
/// 实时预览：在单独的队列上跑，每帧用上一次算好的结果，不增加这一帧的延迟；上一次还没算完就跳过这一帧。
final class PersonSegmenter: @unchecked Sendable {   // 可变状态都由 lock 保护
    private let queue = DispatchQueue(label: "depthbokeh.segmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var mask: FloatMap?
    private var generation = 0
    private let handler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// 最近一次的遮罩（传感器方向，0…1）；画面里没人时全是 0
    var latestMask: FloatMap? {
        lock.lock()
        defer { lock.unlock() }
        return mask
    }

    /// 换了相机：旧画面的遮罩不能再用
    func reset() {
        lock.lock()
        mask = nil
        generation &+= 1
        lock.unlock()
    }

    /// 用这一帧更新遮罩（异步）
    func update(with pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        let gen = generation
        lock.unlock()
        queue.async {
            let result = self.segment(pixelBuffer)
            self.lock.lock()
            if gen == self.generation { self.mask = result }
            self.busy = false
            self.lock.unlock()
        }
    }

    private func segment(_ pixelBuffer: CVPixelBuffer) -> FloatMap? {
        do {
            // 按竖拍方向交给 Vision（.right），它才认得出人
            try handler.perform([request], on: pixelBuffer, orientation: .right)
            guard let out = request.results?.first?.pixelBuffer else { return nil }
            let landscape = CVPixelBufferGetWidth(pixelBuffer) >= CVPixelBufferGetHeight(pixelBuffer)
            return Self.sensorMask(out, sensorLandscape: landscape)
        } catch {
            return nil
        }
    }

    /// 拍下来的照片（传感器方向）用高质量的分割
    static func photoMask(_ image: CGImage) -> FloatMap? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil, let out = request.results?.first?.pixelBuffer else { return nil }
        return sensorMask(out, sensorLandscape: image.width >= image.height)
    }

    /// Vision 输出的遮罩可能是竖的（按竖拍方向）：转回传感器方向（横）。
    /// 传感器 (x, y) 顺时针转 90° 后在竖图的 (列 = 竖图宽 − 1 − y, 行 = x)
    static func sensorMask(_ buffer: CVPixelBuffer, sensorLandscape: Bool) -> FloatMap? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard mw > 1, mh > 1 else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        let rotated = (mw >= mh) != sensorLandscape
        let ow = rotated ? mh : mw, oh = rotated ? mw : mh
        var values = [Float](repeating: 0, count: ow * oh)
        for y in 0..<oh {
            for x in 0..<ow {
                let v = rotated ? src[x * bpr + (mw - 1 - y)] : src[y * bpr + x]
                values[y * ow + x] = Float(v) / 255
            }
        }
        return FloatMap(width: ow, height: oh, values: values)
    }
}
#endif
