#if os(iOS)
import Combine
import QuartzCore
import UIKit
import BokehCore

/// 拍完照之后的「后期调景深」：和 iPhone 相册里改 ƒ 值、换对焦点一样。
/// 原图和深度图都在，每次参数变化就整张重新渲染。
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

    private let queue = DispatchQueue(label: "depthbokeh.editor", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (fNumber: Float, focus: CGPoint)?
    private var busy = false
    private let renderer = BokehRenderer()

    public init(photo: CapturedDepthPhoto) {
        self.photo = photo
        request(fNumber: photo.fNumber, focus: photo.focusPoint)
    }

    /// - Parameter focus: 原图归一化坐标
    public func request(fNumber: Float, focus: CGPoint) {
        lock.lock()
        pending = (fNumber, focus)
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        guard shouldStart else { return }
        DispatchQueue.main.async { self.isRendering = true }
        queue.async { self.drain() }
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
            let focusD = DepthRefiner.focusDisparity(in: photo.disparity, nx: Float(p.focus.x), ny: Float(p.focus.y))
            // 相对深度（双摄视差 / AI 深度）：相对距离的分母有下限，和实时预览一致
            var scale: Float?
            if photo.isRelativeDepth, let range = photo.disparity.percentiles(0.05, 0.95) {
                scale = max(focusD, 0.25 * (range.high - range.low))
            }
            let lens = LensParameters(fNumber: p.fNumber, focusDisparity: focusD, model: lensModel,
                                      focalLength35mm: virtualFocalLength, focusTolerance: focusTolerance,
                                      relativeScale: scale)
            let hint = keepSubjectSharp ? SubjectHint(point: (Float(p.focus.x), Float(p.focus.y))) : nil
            let out = renderer.renderDetailPreserving(full: photo.image, disparity: photo.disparity, lens: lens,
                                                      lowLongSide: max(320, photo.image.longSide / max(1, blurDownscale)),
                                                      quality: .photo, refinePasses: 2, subject: hint)
            let ui = ImageBridge.uiImage(from: out, orientation: photo.orientation)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                self.image = ui
                self.renderMilliseconds = ms
                // 相对深度换算不出米，显示 0（界面上显示「相对深度」）
                self.focusDistanceMeters = self.photo.isRelativeDepth ? 0 : 1 / focusD
            }
        }
    }
}
#endif
