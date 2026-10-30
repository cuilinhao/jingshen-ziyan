#if os(iOS)
import Combine
import Metal
import QuartzCore
import UIKit
import BokehCore
import BokehMetal

/// 拍完照之后的「后期调景深」：和 iPhone 相册里改 ƒ 值、换对焦点一样。
/// 原图和深度图都在，每次参数变化就整张重新渲染：在 GPU 上（和实时预览同一套 Metal 着色器，几十毫秒），
/// GPU 不可用时退回 CPU 参考实现。
/// 渲染在后台串行队列上做；拖动滑块时只渲染最新的一组参数（中间的会被合并掉）。
public final class PhotoBokehEditor: ObservableObject, @unchecked Sendable {
    @Published public private(set) var image: UIImage?
    @Published public private(set) var isRendering = false
    @Published public private(set) var renderMilliseconds: Double = 0
    /// 对焦距离（米）；相对深度的照片为 0
    @Published public private(set) var focusDistanceMeters: Float = 0

    public let photo: CapturedDepthPhoto
    /// 只在 `lensModel = .thinLens` 时使用
    public var virtualFocalLength: Float = 52
    /// 对焦面前后的全清晰区（相对对焦距离）
    public var focusTolerance: Float = 0.06
    /// 虚化模型（默认按系统相机标定）
    public var lensModel: LensParameters.Model = .system
    /// 对焦的主体整个保持清晰
    public var keepSubjectSharp = true
    /// 模糊部分在几分之一的分辨率上计算
    public var blurDownscale = 3

    /// 所有编辑器共用一个 GPU 渲染器（着色器只编译一次），只在这个队列上用
    private static let queue = DispatchQueue(label: "depthbokeh.editor", qos: .userInitiated)
    private static var gpu: MetalBokehRenderer?
    private static var gpuUnavailable = false

    private let lock = NSLock()
    private var pending: (fNumber: Float, focus: CGPoint, useLock: Bool)?
    /// 拍照时锁定了对焦：在编辑器里重新点对焦点之前，用锁定的对焦距离（lock 保护）
    private var useLockedFocus = true
    private var busy = false
    // 以下只在 queue 上访问
    private var cpuRenderer: BokehRenderer?
    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var readback: MTLBuffer?
    private var colors: PlanarImage?

    public init(photo: CapturedDepthPhoto) {
        self.photo = photo
        request(fNumber: photo.fNumber, focus: photo.focusPoint)
    }

    deinit {
        // 照片分辨率的中间结果有一两百 MB：编辑器关了就还回去（着色器留着，下次打开不用再编译）
        Self.queue.async { Self.gpu?.purgeIntermediates() }
    }

    /// - Parameter focus: 原图归一化坐标
    public func request(fNumber: Float, focus: CGPoint) {
        lock.lock()
        if focus != photo.focusPoint { useLockedFocus = false }
        pending = (fNumber, focus, useLockedFocus)
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        guard shouldStart else { return }
        DispatchQueue.main.async { self.isRendering = true }
        Self.queue.async { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let p = pending else {
                busy = false
                lock.unlock()
                DispatchQueue.main.async { self.isRendering = false }
                return
            }
            pending = nil
            lock.unlock()

            let t0 = CACurrentMediaTime()
            let (ui, focusD) = render(fNumber: p.fNumber, focus: p.focus,
                                      lockedFocus: p.useLock ? photo.lockedFocusDisparity : nil)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                if let ui { self.image = ui }
                self.renderMilliseconds = ms
                // 相对深度换算不出米，显示 0（界面上显示「相对深度」）
                self.focusDistanceMeters = self.photo.isRelativeDepth ? 0 : 1 / max(focusD, 1e-3)
            }
        }
    }

    /// queue
    private func render(fNumber: Float, focus: CGPoint, lockedFocus: Float?) -> (UIImage?, Float) {
        let img = photo.image
        var settings = LiveFrameAnalyzer.Settings()
        settings.blurDownscale = blurDownscale
        settings.focusTolerance = focusTolerance
        settings.lensModel = lensModel
        settings.virtualFocalLength = virtualFocalLength
        settings.keepSubjectSharp = keepSubjectSharp
        settings.layersPerSide = RenderQuality.photo.layersPerSide
        // 按颜色补主体边缘用的小图（和深度图一样大），每张照片算一次
        let d = photo.disparity
        if colors == nil { colors = img.resized(width: d.width, height: d.height) }
        // 对焦、相对深度的分母、分层、主体种子：和实时预览同一套规则
        let plan = LiveFrameAnalyzer.stillPlan(disparity: d, relativeDepth: photo.isRelativeDepth, colors: colors,
                                               fNumber: fNumber, focusPoint: (Float(focus.x), Float(focus.y)),
                                               personMask: photo.personMask, outputLongSide: img.longSide,
                                               settings: settings, objectLabels: photo.objectLabels,
                                               personInstances: photo.personInstances,
                                               focalLength35mm: photo.focalLength35mm,
                                               lockedFocusDisparity: lockedFocus)
        if let ui = renderOnGPU(plan) { return (ui, plan.focusDisparity) }
        return (renderOnCPU(plan), plan.focusDisparity)
    }

    private func renderOnGPU(_ plan: FramePlan) -> UIImage? {
        if Self.gpu == nil && !Self.gpuUnavailable {
            Self.gpu = try? MetalBokehRenderer()
            Self.gpuUnavailable = Self.gpu == nil
        }
        guard let gpu = Self.gpu else { return nil }
        let img = photo.image
        let w = img.width, h = img.height
        if sourceTexture == nil {
            sourceTexture = gpu.makeTexture(from: img, pixelFormat: .rgba16Float) ?? gpu.makeTexture(from: img)
        }
        if outputTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                                mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            outputTexture = gpu.device.makeTexture(descriptor: desc)
            readback = gpu.device.makeBuffer(length: w * h * 4, options: .storageModeShared)
        }
        guard let source = sourceTexture, let output = outputTexture, let readback,
              let cb = gpu.commandQueue.makeCommandBuffer() else { return nil }
        cb.label = "照片编辑"
        gpu.encode(plan: plan, quality: .photo, refinePasses: 2, source: source, output: output, encodeSRGB: true,
                   temporal: nil, commandBuffer: cb)
        guard let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        // BGRA（小端 32 位 XRGB）→ CGImage
        let data = Data(bytes: readback.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                        | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: photo.orientation)
    }

    /// GPU 不可用时的 CPU 参考实现（慢：整张照片要一两秒）
    private func renderOnCPU(_ plan: FramePlan) -> UIImage? {
        let renderer = cpuRenderer ?? BokehRenderer()
        cpuRenderer = renderer
        let hint = plan.seeds.map { SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: $0) }
        let out = renderer.renderDetailPreserving(full: photo.image, disparity: plan.depth, lens: plan.lens,
                                                  lowLongSide: plan.lowLongSide, quality: .photo, refinePasses: 2,
                                                  subject: hint, layerCenters: plan.layerCenters)
        return ImageBridge.uiImage(from: out, orientation: photo.orientation)
    }
}
#endif
