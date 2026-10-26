// 从 DepthBokehCamera 2 迁移：没有深度硬件的镜头（0.5× 超广角）用 Core ML 的 Depth Anything V2 Small 估计深度。
// 改动：输出直接是 BokehCore 的 FloatMap（传感器方向），并且可以对拍下来的照片（CGImage）估计。
//
//  - 模型输入是竖直的画面（深度网络依赖「地面在下、天空在上」），392×518；结果转回传感器方向
//  - 输出是相对的「逆深度」（越大越近，比例和偏移都未知），每帧按第 2 / 98 百分位归一化到 0.02…1.02，
//    渲染时用 LensParameters.relativeScale 保护相对距离的分母
#if os(iOS)
import Foundation
import CoreML
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import BokehCore

/// Normalisation range of the model output (2nd / 98th percentile), smoothed over video frames.
struct DepthRange {
    var low: Float
    var high: Float
}

final class MonocularDepthEstimator: @unchecked Sendable {   // all mutable state is guarded by `lock`

    let modelName: String
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let inputPixelFormat: OSType
    private let defaultSize: (width: Int, height: Int)
    private var inputSize: (width: Int, height: Int)
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var inputBuffer: CVPixelBuffer?

    /// Set to false for a model that outputs metric depth (bigger = farther).
    static let outputIsInverseDepth = true

    init?(compiledModelURL: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: compiledModelURL, configuration: config) else {
            print("[Depth] cannot load \(compiledModelURL.lastPathComponent)")
            return nil
        }
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.values.first(where: { $0.type == .image }),
              let constraint = input.imageConstraint,
              let output = description.outputDescriptionsByName.values.first(where: { $0.type == .image || $0.type == .multiArray })
                ?? description.outputDescriptionsByName.values.first else {
            print("[Depth] model has no image input")
            return nil
        }
        self.model = model
        self.modelName = compiledModelURL.deletingPathExtension().lastPathComponent
        self.inputName = input.name
        self.outputName = output.name
        self.inputPixelFormat = constraint.pixelFormatType
        self.defaultSize = (max(constraint.pixelsWide, 14), max(constraint.pixelsHigh, 14))

        // Prefer an upright portrait input (short side × long side) if the model accepts it.
        let short = min(defaultSize.width, defaultSize.height)
        let long = max(defaultSize.width, defaultSize.height)
        if Self.accepts(constraint, width: short, height: long) {
            inputSize = (short, long)
        } else {
            inputSize = defaultSize
        }
        print("[Depth] \(modelName): input \(inputName) \(inputSize.width)×\(inputSize.height), output \(outputName)")
    }

    private static func accepts(_ constraint: MLImageConstraint, width: Int, height: Int) -> Bool {
        let size = constraint.sizeConstraint
        switch size.type {
        case .unspecified:
            return true
        case .range:
            let w = size.pixelsWideRange
            let h = size.pixelsHighRange
            return width >= w.location && width <= w.location + w.length
                && height >= h.location && height <= h.location + h.length
        case .enumerated:
            return size.enumeratedImageSizes.contains { $0.pixelsWide == width && $0.pixelsHigh == height }
        @unknown default:
            return false
        }
    }

    /// Disparity-like depth for a camera buffer in sensor orientation.
    /// Returns a map in the same (sensor) orientation plus the range used.
    /// Pass the previous frame's range to smooth the normalisation over video (nil for photos).
    func estimate(_ pixelBuffer: CVPixelBuffer, previous: DepthRange?,
                  orientation: CGImagePropertyOrientation = .right) -> (map: FloatMap, range: DepthRange)? {
        estimate(image: CIImage(cvPixelBuffer: pixelBuffer), previous: previous, orientation: orientation)
    }

    /// Same for a still photo (sensor orientation, EXIF orientation not applied).
    func estimate(cgImage: CGImage, orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        estimate(image: CIImage(cgImage: cgImage), previous: nil, orientation: orientation)?.map
    }

    private func estimate(image source: CIImage, previous: DepthRange?,
                          orientation: CGImagePropertyOrientation = .right) -> (map: FloatMap, range: DepthRange)? {
        lock.lock()
        defer { lock.unlock() }

        guard let prediction = predict(source, orientation: orientation) else { return nil }
        var output = prediction.output
        if !Self.outputIsInverseDepth {
            output.values = output.values.map { $0 > 1e-6 ? 1 / $0 : 0 }
        }

        // Robust range: 2nd / 98th percentile on a sub-sampled grid.
        var sample: [Float] = []
        sample.reserveCapacity(output.values.count / 16 + 1)
        var i = 0
        while i < output.values.count {
            let v = output.values[i]
            if v.isFinite { sample.append(v) }
            i += 16
        }
        guard sample.count > 16 else { return nil }
        sample.sort()
        var low = sample[sample.count * 2 / 100]
        var high = sample[min(sample.count - 1, sample.count * 98 / 100)]
        if let previous {
            low = previous.low + (low - previous.low) * 0.25
            high = previous.high + (high - previous.high) * 0.25
        }
        let span = max(high - low, 1e-6)

        let values = output.values.map { v in
            v.isFinite ? min(max((v - low) / span, 0), 1.5) + 0.02 : 0.02
        }
        // Invert the actual input rotation, including a fallback to a landscape model size.
        let map = CameraImageOrientation.sensorMap(values, width: output.width, height: output.height,
                                                   orientation: prediction.orientation)
        return (map, DepthRange(low: low, high: high))
    }

    // MARK: Inference

    private func predict(_ pixelBuffer: CIImage, orientation: CGImagePropertyOrientation) -> Prediction? {
        if let result = runModel(pixelBuffer, size: inputSize, orientation: orientation) { return result }
        // The preferred (portrait) size was rejected at runtime: fall back to the model's default.
        if inputSize != defaultSize {
            print("[Depth] \(inputSize) rejected, falling back to \(defaultSize)")
            inputSize = defaultSize
            inputBuffer = nil
            return runModel(pixelBuffer, size: inputSize, orientation: orientation)
        }
        return nil
    }

    private func runModel(_ pixelBuffer: CIImage, size: (width: Int, height: Int),
                          orientation: CGImagePropertyOrientation) -> Prediction? {
        let inputOrientation = Self.inputOrientation(for: orientation,
                                                     sourceLandscape: pixelBuffer.extent.width >= pixelBuffer.extent.height,
                                                     inputLandscape: size.width >= size.height)
        guard let input = makeInput(from: pixelBuffer, size: size, orientation: inputOrientation) else { return nil }
        do {
            let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
            let result = try model.prediction(from: features)
            guard let value = result.featureValue(for: outputName) else { return nil }
            let output: Output?
            if let image = value.imageBufferValue {
                output = Self.read(pixelBuffer: image)
            } else if let array = value.multiArrayValue {
                output = Self.read(multiArray: array)
            } else {
                output = nil
            }
            return output.map { Prediction(output: $0, orientation: inputOrientation) }
        } catch {
            print("[Depth] prediction failed: \(error)")
            return nil
        }
    }

    /// Preserve the original landscape-model fallback: upright portrait turned left is its basis.
    static func inputOrientation(for orientation: CGImagePropertyOrientation,
                                 sourceLandscape: Bool, inputLandscape: Bool) -> CGImagePropertyOrientation {
        var turns = CameraImageOrientation.quarterTurns(for: orientation)
        let uprightLandscape = turns % 2 == 0 ? sourceLandscape : !sourceLandscape
        if uprightLandscape != inputLandscape { turns = (turns + 3) % 4 }
        return [CGImagePropertyOrientation.up, .right, .down, .left][turns]
    }

    /// Camera buffer → model input, using the exact rotation also recorded for the output map.
    private func makeInput(from source: CIImage, size: (width: Int, height: Int),
                           orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        if inputBuffer == nil || CVPixelBufferGetWidth(inputBuffer!) != size.width || CVPixelBufferGetHeight(inputBuffer!) != size.height {
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, inputPixelFormat, attributes as CFDictionary, &buffer)
            inputBuffer = buffer
        }
        guard let inputBuffer else { return nil }

        var image = source.oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / image.extent.width,
                                                        y: CGFloat(size.height) / image.extent.height))
        ciContext.render(image, to: inputBuffer)
        return inputBuffer
    }

    // MARK: Reading model output

    private struct Prediction {
        let output: Output
        let orientation: CGImagePropertyOrientation
    }

    private struct Output {
        var values: [Float]
        var width: Int
        var height: Int
    }

    private static func read(pixelBuffer: CVPixelBuffer) -> Output? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), width > 1, height > 1 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [Float](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) / 255 }
            }
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            // Grey image stored as colour: R = G = B, so any colour byte works (offset 1).
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x * 4 + 1]) / 255 }
            }
        default:
            print("[Depth] unsupported output pixel format \(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            return nil
        }
        return Output(values: values, width: width, height: height)
    }

    /// Uses the last two dimensions as (height, width) of the first plane.
    private static func read(multiArray: MLMultiArray) -> Output? {
        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2]
        let colStride = strides[strides.count - 1]
        guard width > 1, height > 1 else { return nil }
        var values = [Float](repeating: 0, count: width * height)

        switch multiArray.dataType {
        case .float32:
            multiArray.withUnsafeBufferPointer(ofType: Float.self) { ptr in
                for y in 0..<height { for x in 0..<width { values[y * width + x] = ptr[y * rowStride + x * colStride] } }
            }
        case .float16:
            multiArray.withUnsafeBufferPointer(ofType: Float16.self) { ptr in
                for y in 0..<height { for x in 0..<width { values[y * width + x] = Float(ptr[y * rowStride + x * colStride]) } }
            }
        case .double:
            multiArray.withUnsafeBufferPointer(ofType: Double.self) { ptr in
                for y in 0..<height { for x in 0..<width { values[y * width + x] = Float(ptr[y * rowStride + x * colStride]) } }
            }
        default:
            return nil
        }
        return Output(values: values, width: width, height: height)
    }
}
#endif
