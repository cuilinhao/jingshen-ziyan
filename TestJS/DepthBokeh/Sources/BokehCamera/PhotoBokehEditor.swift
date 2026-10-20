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
    @Published public private(set) var focusDistanceMeters: Float = 0

    public let photo: CapturedDepthPhoto
    public var virtualFocalLength: Float = 52
    /// 对焦面前后的全清晰区（对焦距离的比例）
    public var focusTolerance: Float = 0.08
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
            let lens = LensParameters(fNumber: p.fNumber, focusDisparity: focusD,
                                      focalLength35mm: virtualFocalLength, focusTolerance: focusTolerance)
            let out = renderer.renderDetailPreserving(full: photo.image, disparity: photo.disparity, lens: lens,
                                                      lowLongSide: max(320, photo.image.longSide / max(1, blurDownscale)),
                                                      quality: .photo, refinePasses: 2)
            let ui = ImageBridge.uiImage(from: out, orientation: photo.orientation)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                self.image = ui
                self.renderMilliseconds = ms
                self.focusDistanceMeters = 1 / focusD
            }
        }
    }
}
#endif
