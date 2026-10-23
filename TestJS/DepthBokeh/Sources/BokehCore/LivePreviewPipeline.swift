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
        /// 算人像遮罩那一帧的画面（整个相机画面，任意小尺寸）；画面从那以后变了的地方不再相信遮罩
        public var personMaskColors: PlanarImage?
        /// 深度是几帧之前的（沿用旧深度）。0 = 这一帧的
        public var depthAge: Int

        public init(image: PlanarImage, disparity: FloatMap?, relativeDepth: Bool, crop: Float, fNumber: Float,
                    focusPoint: (x: Float, y: Float), focusTapped: Bool, time: Double, personMask: FloatMap? = nil,
                    personMaskColors: PlanarImage? = nil, depthAge: Int = 0) {
            self.personMaskColors = personMaskColors
            self.depthAge = depthAge
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
    public var maxHoldOverride: Double? {
        get { analyzer.maxHoldOverride }
        set { analyzer.maxHoldOverride = newValue }
    }
    /// CPU 上的分析（和 iOS 上的 Metal 渲染共用）
    public let analyzer = LiveFrameAnalyzer()
    public let renderer = BokehRenderer()
    public let temporal = TemporalState()
    /// 最近一帧的计划（测试用）
    public private(set) var lastPlan: FramePlan?

    public init() {}

    /// 换了相机或相机倍率：所有和旧画面绑定的历史都不能再用
    public func resetHistory() {
        temporal.reset()
        analyzer.resetHistory()
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
        guard let full = frame.disparity else {
            var p = frame.focusPoint
            var recentered = false
            if abs(p.x - 0.5) * c > 0.5 || abs(p.y - 0.5) * c > 0.5 { p = (0.5, 0.5); recentered = true }
            return Result(image: frame.image, focusPoint: p, focusRecentered: recentered, focusDisparity: nil,
                          focusDistance: nil, tooClose: false, cameraMoving: false, timings: timings)
        }
        var a = analyzer.settings
        a.blurDownscale = settings.blurDownscale
        a.focusTolerance = settings.focusTolerance
        a.lensModel = settings.lensModel
        a.virtualFocalLength = settings.virtualFocalLength
        a.keepSubjectSharp = settings.keepSubjectSharp
        a.minSubjectDistance = settings.minSubjectDistance
        a.layersPerSide = settings.quality.layersPerSide
        a.matte = settings.matte
        a.motionCutoff = temporal.motionCutoff
        analyzer.settings = a
        // 裁切后的那块画面的小图（和裁切后的深度图一样大）：按颜色补边、估计手机是否在动
        let cw = max(1, Int((Float(full.width) / c).rounded())), ch = max(1, Int((Float(full.height) / c).rounded()))
        let colors = frame.image.resized(width: cw, height: ch)
        let plan = analyzer.analyze(LiveFrameAnalyzer.Frame(
            disparity: full, relativeDepth: frame.relativeDepth, crop: c, fNumber: frame.fNumber,
            focusPoint: frame.focusPoint, focusTapped: frame.focusTapped, time: frame.time,
            colors: colors, personMask: frame.personMask, outputLongSide: frame.image.longSide,
            personMaskColors: frame.personMaskColors, depthAge: frame.depthAge))
        lastPlan = plan
        lap("分析")

        let out: PlanarImage
        if !plan.renderEffect {
            out = frame.image
        } else {
            let hint = plan.seeds.map { SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: $0) }
            out = renderer.renderDetailPreserving(full: frame.image, disparity: plan.depth, lens: plan.lens,
                                                  lowLongSide: plan.lowLongSide, quality: settings.quality,
                                                  refinePasses: 1, temporal: temporal, subject: hint,
                                                  layerCenters: plan.layerCenters, stillness: plan.stillness,
                                                  depthAge: plan.depthAge)
        }
        lap("渲染")
        if plan.renderEffect { timings += renderer.stageTimings.map { ("渲染." + $0.0, $0.1) } }
        return Result(image: out, focusPoint: plan.streamFocusPoint, focusRecentered: plan.focusRecentered,
                      focusDisparity: plan.focusDisparity, focusDistance: plan.focusDistance,
                      tooClose: plan.tooClose, cameraMoving: plan.cameraMoving, timings: timings)
    }

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
}
