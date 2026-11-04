// 从 DepthBokehCamera 2 迁移：没有深度硬件的镜头（0.5× 超广角）用 Core ML 的 Depth Anything V2 Small 估计深度。
// 改动：输出直接是 BokehCore 的 FloatMap（传感器方向），并且可以对拍下来的照片（CGImage）估计。
//
//  - 模型输入是竖直的画面（深度网络依赖「地面在下、天空在上」），392×518；结果转回传感器方向
//  - 输出是相对的「逆深度」（越大越近，比例和偏移都未知），每帧按第 2 / 98 百分位归一化到 0.02…1.02，
//    渲染时用 LensParameters.relativeScale 保护相对距离的分母
//  - 相册照片（estimateStill）：任意宽高比，按照片自己的方向转正后送进去，不拉伸（模型接受这个比例就直接用，
//    否则等比缩进去、四周补边），结果只取画面那一块
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
    /// 模型输入允许的尺寸（相册照片按它挑和照片比例最接近的尺寸）
    private let imageConstraint: MLImageConstraint
    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var inputBuffer: CVPixelBuffer?
    /// 相册照片用的输入（尺寸跟着照片比例变，不和视频帧的那块来回重建）
    private var stillBuffer: CVPixelBuffer?

    /// Set to false for a model that outputs metric depth (bigger = farther).
    static let outputIsInverseDepth = true

    /// - Parameter computeUnits: `.all` 会用神经网络引擎（快、省电，但每次装到手机上后第一次加载要编译几十秒）；
    ///   `.cpuAndGPU` 不用神经网络引擎，几秒就能加载好
    init?(compiledModelURL: URL, computeUnits: MLComputeUnits = .all) {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
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
        self.imageConstraint = constraint

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

    // MARK: 相册照片（任意宽高比）

    /// 相册里的照片：`cgImage` 的像素方向由 `orientation`（EXIF 方向）描述。和 `estimate(cgImage:)` 的区别：
    ///  - 画面按自己的方向转正后送进模型，不为了凑模型输入的横竖再多转 90°（那样「天在左边」，深度明显变差）；
    ///  - 不拉伸：模型接受和照片一样比例的尺寸就直接用，否则等比缩进去、四周用边缘像素补齐，结果只取画面那一块。
    ///    相机画面是 4:3，拉到 392×518 几乎不变形；相册里的 16:9、1:1、截图、全景图拉过去会明显变形。
    /// 输出和 `estimate` 一样：`cgImage` 的像素方向，按 2% / 98% 百分位归一化到 0.02…1.02（越大越近）
    func estimateStill(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) -> FloatMap? {
        lock.lock()
        defer { lock.unlock() }
        // 只转不镜像：镜像的画面估出来的深度也是镜像的，sensorMap 按同一个旋转转回去正好对上像素
        let turns = CameraImageOrientation.quarterTurns(for: orientation)
        let rotation = [CGImagePropertyOrientation.up, .right, .down, .left][turns]
        let source = CIImage(cgImage: cgImage)
        let w = Double(cgImage.width), h = Double(cgImage.height)
        let aspect = turns % 2 == 0 ? w / h : h / w   // 转正以后的宽 / 高
        for size in stillInputSizes(uprightAspect: aspect) {
            guard let input = makeStillInput(from: source, size: size, orientation: rotation),
                  let raw = run(input.buffer) else { continue }
            let output = Self.crop(raw, toNormalized: input.valid)
            guard let values = Self.normalizedStill(output.values) else { return nil }
            print("[Depth] 照片 \(cgImage.width)×\(cgImage.height) → 模型输入 \(size.width)×\(size.height)，"
                  + "画面占 \(output.width)×\(output.height)")
            return CameraImageOrientation.sensorMap(values, width: output.width, height: output.height,
                                                    orientation: rotation)
        }
        return nil
    }

    /// 照片要试的模型输入尺寸（宽 × 高，都按转正的画面），好的在前；模型不接受的不列
    private func stillInputSizes(uprightAspect aspect: Double) -> [(width: Int, height: Int)] {
        let short = min(defaultSize.width, defaultSize.height)
        let long = max(defaultSize.width, defaultSize.height)
        let landscape = aspect >= 1
        var sizes: [(width: Int, height: Int)] = []
        // 没有可变尺寸（.unspecified）的模型只接受固定的那一个尺寸（App 里的 Depth Anything 是 518×392）；
        // accepts 对它一律放行（视频那条路靠运行时报错再退回），这里直接只留固定尺寸，不白跑一次失败的推理
        let fixedOnly = imageConstraint.sizeConstraint.type == .unspecified
        func add(_ s: (width: Int, height: Int)) {
            guard s.width >= 14, s.height >= 14,
                  !fixedOnly || (s.width == defaultSize.width && s.height == defaultSize.height),
                  Self.accepts(imageConstraint, width: s.width, height: s.height),
                  !sizes.contains(where: { $0.width == s.width && $0.height == s.height }) else { return }
            sizes.append(s)
        }
        // 1. 可变尺寸的模型：长边不变，短边按照片比例取 14 的倍数（ViT 的 patch 是 14），不用补边
        let other = max(14, Int((Double(long) * (landscape ? 1 / aspect : aspect) / 14).rounded()) * 14)
        add(landscape ? (long, other) : (other, long))
        // 2. 列举了几种尺寸的模型：比例最接近的在前
        if imageConstraint.sizeConstraint.type == .enumerated {
            let listed = imageConstraint.sizeConstraint.enumeratedImageSizes.map { (width: $0.pixelsWide, height: $0.pixelsHigh) }
            let closeness = { (s: (width: Int, height: Int)) in abs(log(Double(s.width) / Double(s.height) / aspect)) }
            for s in listed.sorted(by: { closeness($0) < closeness($1) }) { add(s) }
        }
        // 3. 固定尺寸：和照片横竖一致的那个；都不行就用模型默认的（照片等比缩进去，补边）
        add(landscape ? (long, short) : (short, long))
        add(inputSize)
        add(defaultSize)
        return sizes
    }

    /// 照片 → 模型输入：转正（只转不镜像），等比缩放居中，四周用边缘像素补齐（不用黑边：黑边在深度里是一道很强的边）。
    /// valid：画面在输入里占的那块（归一化，左上角原点）
    private func makeStillInput(from source: CIImage, size: (width: Int, height: Int),
                                orientation: CGImagePropertyOrientation) -> (buffer: CVPixelBuffer, valid: CGRect)? {
        if stillBuffer == nil || CVPixelBufferGetWidth(stillBuffer!) != size.width
            || CVPixelBufferGetHeight(stillBuffer!) != size.height {
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, inputPixelFormat,
                                attributes as CFDictionary, &buffer)
            stillBuffer = buffer
        }
        guard let buffer = stillBuffer else { return nil }
        var image = source.oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let W = CGFloat(size.width), H = CGFloat(size.height)
        let s = min(W / image.extent.width, H / image.extent.height)
        let sw = image.extent.width * s, sh = image.extent.height * s
        let ox = (W - sw) / 2, oy = (H - sh) / 2
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        ciContext.render(image, to: buffer)
        // Core Image 的原点在左下角；画面上下居中，换成左上角原点 y 不变
        return (buffer, CGRect(x: ox / W, y: oy / H, width: sw / W, height: sh / H))
    }

    /// 输出里只留画面那一块（valid：归一化，左上角原点）；边上往里收，不带进补出来的像素
    private static func crop(_ o: Output, toNormalized valid: CGRect) -> Output {
        let fw = CGFloat(o.width), fh = CGFloat(o.height)
        let x0 = max(0, Int((valid.minX * fw - 0.01).rounded(.up)))
        let y0 = max(0, Int((valid.minY * fh - 0.01).rounded(.up)))
        let x1 = min(o.width, Int((valid.maxX * fw + 0.01).rounded(.down)))
        let y1 = min(o.height, Int((valid.maxY * fh + 0.01).rounded(.down)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return o }
        if x0 == 0, y0 == 0, x1 == o.width, y1 == o.height { return o }
        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { values.append(contentsOf: o.values[(y * o.width + x0)..<(y * o.width + x1)]) }
        return Output(values: values, width: x1 - x0, height: y1 - y0)
    }

    /// 和 `estimate` 的归一化一样（照片没有上一帧可以平滑）：2% / 98% 百分位 → 0.02…1.02
    private static func normalizedStill(_ raw: [Float]) -> [Float]? {
        let values = outputIsInverseDepth ? raw : raw.map { $0 > 1e-6 ? 1 / $0 : 0 }
        var sample: [Float] = []
        sample.reserveCapacity(values.count / 16 + 1)
        var i = 0
        while i < values.count {
            if values[i].isFinite { sample.append(values[i]) }
            i += 16
        }
        guard sample.count > 16 else { return nil }
        sample.sort()
        let low = sample[sample.count * 2 / 100]
        let high = sample[min(sample.count - 1, sample.count * 98 / 100)]
        let span = max(high - low, 1e-6)
        return values.map { v in v.isFinite ? min(max((v - low) / span, 0), 1.5) + 0.02 : 0.02 }
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
        guard let input = makeInput(from: pixelBuffer, size: size, orientation: inputOrientation),
              let output = run(input) else { return nil }
        return Prediction(output: output, orientation: inputOrientation)
    }

    /// 跑一次模型，读出输出（第一个平面）
    private func run(_ input: CVPixelBuffer) -> Output? {
        do {
            let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
            let result = try model.prediction(from: features)
            guard let value = result.featureValue(for: outputName) else { return nil }
            if let image = value.imageBufferValue { return Self.read(pixelBuffer: image) }
            if let array = value.multiArrayValue { return Self.read(multiArray: array) }
            return nil
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
