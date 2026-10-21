import Foundation

/// 实时预览每一帧的处理：对焦、主体太近检测、相对深度保护、双分辨率虚化渲染、跨帧稳定。
///
/// 纯 Swift，不依赖任何 Apple 框架：iOS 上由 DepthCameraController 每帧调用，
/// 电脑上由 bokeh-cli `--live` 用录好的视频 + 深度跑同一份代码（包括变焦裁切、换相机、双摄相对视差），
/// 所以在云主机上测出来的问题和手机上是同一个问题。
///
/// 坐标约定：对焦点用「相机画面」（未裁切）的归一化坐标，传感器方向；
/// image 是已经按 crop 从相机画面中间裁好的图，disparity 是整个相机画面的视差图（这里再按同样的比例裁）。
public final class LivePreviewPipeline {

    public struct Settings {
        /// 模糊部分在几分之一的分辨率上计算（3 = 1440 → 480）
        public var blurDownscale = 3
        /// 对焦面前后的全清晰区（相对对焦距离）
        public var focusTolerance: Float = 0.06
        public var lensModel: LensParameters.Model = .system
        /// 只在 `.thinLens` 时使用
        public var virtualFocalLength: Float = 52
        /// 对焦的主体整个保持清晰（SubjectMatte）
        public var keepSubjectSharp = true
        /// 主体比这更近（米）时关掉景深并提示离远一点。只对绝对深度（LiDAR）生效
        public var minSubjectDistance: Float = 0.30
        public var quality: RenderQuality = .preview
        /// 主体遮罩参数（SubjectMatte）
        public var matte = SubjectMatteParameters()
        public init() {}
    }

    public struct Frame {
        /// 已经从相机画面中间裁到当前倍率的图（线性光）
        public var image: PlanarImage
        /// 整个相机画面的视差图；nil = 没有深度（直接显示原图）
        public var disparity: FloatMap?
        /// 视差只有相对值（双摄视差 / AI 深度）：不能换算成米，相对距离的分母要有下限
        public var relativeDepth: Bool
        /// image 相对相机画面裁了多少（≥ 1）
        public var crop: Float
        public var fNumber: Float
        /// 对焦点（相机画面坐标）
        public var focusPoint: (x: Float, y: Float)
        /// 用户刚点了新的对焦点
        public var focusTapped: Bool
        /// 时间戳（秒）
        public var time: Double
        /// 人像分割遮罩（整个相机画面，任意分辨率，0…1）；对焦点落在人身上时，整个人（包括眼镜）保持清晰
        public var personMask: FloatMap?

        public init(image: PlanarImage, disparity: FloatMap?, relativeDepth: Bool, crop: Float, fNumber: Float,
                    focusPoint: (x: Float, y: Float), focusTapped: Bool, time: Double, personMask: FloatMap? = nil) {
            self.image = image
            self.disparity = disparity
            self.relativeDepth = relativeDepth
            self.crop = crop
            self.fNumber = fNumber
            self.focusPoint = focusPoint
            self.focusTapped = focusTapped
            self.time = time
            self.personMask = personMask
        }
    }

    public struct Result {
        public var image: PlanarImage
        /// 实际用的对焦点（相机画面坐标）。原来的点被裁到画面外时回到中心，`focusRecentered = true`
        public var focusPoint: (x: Float, y: Float)
        public var focusRecentered: Bool
        public var focusDisparity: Float?
        /// 对焦距离（米）；相对深度时为 nil
        public var focusDistance: Float?
        public var tooClose: Bool
        /// 手机在动（扫镜头）
        public var cameraMoving: Bool
        /// 各步骤耗时（毫秒）
        public var timings: [(String, Double)]
    }

    public var settings = Settings()
    /// 测试用：覆盖对焦稳定器的最长坚持时间
    public var maxHoldOverride: Double?
    public let renderer = BokehRenderer()
    public let temporal = TemporalState()
    private var stabilizer = FocusStabilizer()
    private var effectAmount: Float = 1
    private var tooClose = false
    private var lastTime: Double?
    private var smoothedNear: Float?
    private var smoothedFar: Float?
    private var movingUntil: Double = -1

    public init() {}

    /// 换了相机或相机倍率：所有和旧画面绑定的历史都不能再用
    public func resetHistory() {
        temporal.reset()
        stabilizer = FocusStabilizer()
        smoothedNear = nil
        smoothedFar = nil
        lastTime = nil
        movingUntil = -1
    }

    public func process(_ frame: Frame) -> Result {
        var timings: [(String, Double)] = []
        var mark = Self.now()
        func lap(_ name: String) {
            let t = Self.now()
            timings.append((name, (t - mark) * 1000))
            mark = t
        }
        let c = max(frame.crop, 1)
        var p = frame.focusPoint
        var recentered = false
        // 对焦点被裁到画面外了：回到中心
        if abs(p.x - 0.5) * c > 0.5 || abs(p.y - 0.5) * c > 0.5 {
            p = (0.5, 0.5)
            recentered = true
        }
        let moving = frame.time < movingUntil
        guard let full = frame.disparity else {
            return Result(image: frame.image, focusPoint: p, focusRecentered: recentered, focusDisparity: nil,
                          focusDistance: nil, tooClose: false, cameraMoving: moving, timings: timings)
        }
        let map = full.centerCropped(by: c)
        lap("裁深度")

        // 1. 对焦（裁出来的画面坐标）。点按或回到中心时重新锁定；手机在动时变远也只坚持 0.3 秒
        let fx = 0.5 + (p.x - 0.5) * c, fy = 0.5 + (p.y - 0.5) * c
        if frame.focusTapped || recentered { stabilizer.reset() }
        let dt = lastTime.map { min(0.2, max(0, frame.time - $0)) } ?? (1.0 / 30)
        lastTime = frame.time
        stabilizer.cameraMoving = moving
        if let h = maxHoldOverride { stabilizer.maxHold = h }
        let focusD = stabilizer.update(map: map, nx: fx, ny: fy, dt: dt)

        // 2. 主体太近：关掉景深（0.15 秒淡出 / 淡入，进出留 12% 回差）。只有绝对深度能换算成米
        let distance: Float? = frame.relativeDepth ? nil : 1 / max(focusD, 1e-3)
        if let d = distance {
            if tooClose {
                if d > settings.minSubjectDistance * 1.12 { tooClose = false }
            } else if d < settings.minSubjectDistance {
                tooClose = true
            }
        } else {
            tooClose = false
        }
        effectAmount += ((tooClose ? 0 : 1) - effectAmount) * Float(1 - exp(-dt / 0.15))

        // 3. 相对深度：相对距离的分母用 max(d_f, 0.25 × (近端 − 远端))
        var relativeScale: Float?
        if frame.relativeDepth, let range = map.percentiles(0.05, 0.95) {
            let near = smoothedNear.map { $0 + (range.high - $0) * 0.15 } ?? range.high
            let far = smoothedFar.map { $0 + (range.low - $0) * 0.15 } ?? range.low
            smoothedNear = near
            smoothedFar = far
            relativeScale = max(focusD, 0.25 * (near - far))
        }
        lap("对焦")

        // 4. 双分辨率渲染
        var lens = LensParameters(fNumber: frame.fNumber, focusDisparity: focusD, model: settings.lensModel,
                                  focalLength35mm: settings.virtualFocalLength, focusTolerance: settings.focusTolerance,
                                  relativeScale: relativeScale)
        lens.blurK *= effectAmount
        lens.maxBlurFraction *= effectAmount
        let image = frame.image
        let out: PlanarImage
        if effectAmount < 0.02 {
            out = image
        } else {
            var hint: SubjectHint?
            if settings.keepSubjectSharp {
                var matte = settings.matte
                // 按颜色补主体边缘只用在相对深度（双摄视差 / AI）上：LiDAR 的边缘本来就准，
                // 补了反而可能把紧挨着主体、颜色相近的后面的东西（比如后面的人）也拉清晰
                if !frame.relativeDepth { matte.colorGrowth = 0 }
                hint = SubjectHint(point: (fx, fy), parameters: matte)
                if let mask = frame.personMask {
                    hint?.personMask = mask.centerCropped(by: c)
                }
            }
            let lowSide = max(160, image.longSide / max(1, settings.blurDownscale))
            out = renderer.renderDetailPreserving(full: image, disparity: map, lens: lens, lowLongSide: lowSide,
                                                  quality: settings.quality, refinePasses: 1,
                                                  temporal: temporal, subject: hint)
        }
        lap("渲染")
        if effectAmount >= 0.02 { timings += renderer.stageTimings.map { ("渲染." + $0.0, $0.1) } }
        // 扫镜头的判断留给下一帧的对焦用（延续 0.25 秒，避免两次扫之间的停顿又变回长时间坚持）
        if temporal.cameraShift >= 2 { movingUntil = frame.time + 0.25 }
        return Result(image: out, focusPoint: p, focusRecentered: recentered, focusDisparity: focusD,
                      focusDistance: distance, tooClose: tooClose, cameraMoving: moving, timings: timings)
    }

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
}
