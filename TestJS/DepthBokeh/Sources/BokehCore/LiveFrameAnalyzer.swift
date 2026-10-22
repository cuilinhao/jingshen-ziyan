import Foundation

/// 一帧要怎么渲染：CPU 上算好的所有「小」东西。渲染（逐像素的重活）交给 CPU 参考实现或 GPU（Metal），
/// 两边拿到的是同一份计划，所以效果一致。
public struct FramePlan {
    /// 镜头参数（对焦视差、相对深度的分母、主体太近时的淡出都已经算进去）
    public var lens: LensParameters
    /// 对焦点（裁切后的画面坐标）
    public var focusPoint: (x: Float, y: Float)
    /// 实际用的对焦点（相机画面坐标）。原来的点被裁到画面外时回到中心
    public var streamFocusPoint: (x: Float, y: Float)
    public var focusRecentered: Bool
    public var focusDisparity: Float
    /// 对焦距离（米）；相对深度时为 nil
    public var focusDistance: Float?
    public var tooClose: Bool
    /// 手机在动（扫镜头）
    public var cameraMoving: Bool
    /// 这一帧整幅画面的平移量（低分辨率像素）
    public var cameraShift: Float
    /// 沿用上一帧的比例（1 = 静止，0 = 在扫镜头）；nil = 没有颜色输入，渲染时自己估计
    public var stillness: Float?
    /// false = 景深淡出到几乎没有（主体太近），直接显示原图
    public var renderEffect: Bool
    /// 分层位置（模糊半径，低分辨率像素）
    public var layerCenters: [Float]
    /// 主体种子；nil = 不做主体遮罩
    public var seeds: SubjectSeeds?
    public var matte: SubjectMatteParameters
    /// 已裁切、已补洞的视差图（深度图分辨率），交给渲染
    public var depth: FloatMap
    /// 模糊部分的分辨率（长边）
    public var lowLongSide: Int
    /// 和上一帧比，亮度明显变了（> 0.04）的像素占多少（画面里有东西在动；手机整体平移看 cameraShift）。
    /// 没有颜色输入或第一帧为 0
    public var changedFraction: Float = 0
}

/// 实时预览每一帧在 CPU 上的分析：对焦稳定、主体太近、相对深度保护、分层范围、主体种子、手机是否在动。
/// 只处理深度图分辨率（≤ 320×240）的数据，几毫秒；逐像素的渲染不在这里。
public final class LiveFrameAnalyzer {

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
        /// 每侧分几层（决定分层位置）
        public var layersPerSide = RenderQuality.preview.layersPerSide
        /// 主体遮罩参数
        public var matte = SubjectMatteParameters()
        /// 平移达到多少像素（低分辨率、每帧）时完全不沿用上一帧
        public var motionCutoff: Float = 2
        public init() {}
    }

    public struct Frame {
        /// 整个相机画面的视差图（深度图分辨率，可以含 NaN）
        public var disparity: FloatMap
        /// 视差只有相对值（双摄视差 / AI 深度）
        public var relativeDepth: Bool
        /// 渲染的画面相对相机画面裁了多少（≥ 1）
        public var crop: Float
        public var fNumber: Float
        /// 对焦点（相机画面坐标）
        public var focusPoint: (x: Float, y: Float)
        /// 用户刚点了新的对焦点
        public var focusTapped: Bool
        /// 时间戳（秒）
        public var time: Double
        /// 裁切后的那块画面的小图（线性光，任意小尺寸，建议和裁切后的深度图一样大）。
        /// 用来按颜色补主体边缘、估计手机是否在动；nil = 不做这两件事
        public var colors: PlanarImage?
        /// 人像分割遮罩（整个相机画面，任意分辨率，0…1）
        public var personMask: FloatMap?
        /// 输出画面的长边（像素），决定模糊部分的分辨率
        public var outputLongSide: Int

        public init(disparity: FloatMap, relativeDepth: Bool, crop: Float, fNumber: Float,
                    focusPoint: (x: Float, y: Float), focusTapped: Bool, time: Double,
                    colors: PlanarImage?, personMask: FloatMap?, outputLongSide: Int) {
            self.disparity = disparity
            self.relativeDepth = relativeDepth
            self.crop = crop
            self.fNumber = fNumber
            self.focusPoint = focusPoint
            self.focusTapped = focusTapped
            self.time = time
            self.colors = colors
            self.personMask = personMask
            self.outputLongSide = outputLongSide
        }
    }

    public var settings = Settings()
    /// 测试用：覆盖对焦稳定器的最长坚持时间
    public var maxHoldOverride: Double?
    private var stabilizer = FocusStabilizer()
    private var effectAmount: Float = 1
    private var tooClose = false
    private var lastTime: Double?
    private var smoothedNear: Float?
    private var smoothedFar: Float?
    private var movingUntil: Double = -1
    private var previousLuma: [Float] = []
    private var previousLumaSize = (0, 0)

    public init() {}

    /// 换了相机或相机倍率：所有和旧画面绑定的历史都不能再用
    public func resetHistory() {
        stabilizer = FocusStabilizer()
        smoothedNear = nil
        smoothedFar = nil
        lastTime = nil
        movingUntil = -1
        previousLuma = []
        previousLumaSize = (0, 0)
    }

    public func analyze(_ frame: Frame) -> FramePlan {
        let c = max(frame.crop, 1)
        var p = frame.focusPoint
        var recentered = false
        // 对焦点被裁到画面外了：回到中心
        if abs(p.x - 0.5) * c > 0.5 || abs(p.y - 0.5) * c > 0.5 {
            p = (0.5, 0.5)
            recentered = true
        }
        let moving = frame.time < movingUntil
        let map = DepthRefiner.fillInvalid(frame.disparity.centerCropped(by: c))
        let lowLongSide = max(160, frame.outputLongSide / max(1, settings.blurDownscale))

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
        var lens = LensParameters(fNumber: frame.fNumber, focusDisparity: focusD, model: settings.lensModel,
                                  focalLength35mm: settings.virtualFocalLength, focusTolerance: settings.focusTolerance,
                                  relativeScale: relativeScale)
        lens.blurK *= effectAmount
        lens.maxBlurFraction *= effectAmount

        // 4. 分层位置：按这一帧的深度范围（模糊半径单调随视差变化，范围两端就是最远 / 最近）
        var dMin = Float.infinity, dMax = -Float.infinity
        for v in map.values where v.isFinite { dMin = min(dMin, v); dMax = max(dMax, v) }
        if !dMin.isFinite { dMin = focusD; dMax = focusD }
        let sMin = min(0, lens.signedBlurRadius(disparity: dMin, imageLongSide: lowLongSide))
        let sMax = max(0, lens.signedBlurRadius(disparity: dMax, imageLongSide: lowLongSide))
        let centers = BokehRenderer.layerCenters(sMin: sMin, sMax: sMax, perSide: settings.layersPerSide)

        // 5. 手机是否在动：裁切后小图的亮度和上一帧比，整体平移多少
        var shift: Float = 0
        var stillness: Float?
        var changed: Float = 0
        if let colors = frame.colors {
            let luma = colors.perceptualLuma().values
            if previousLumaSize == (colors.width, colors.height) {
                let s = TemporalState.globalShift(luma, previousLuma, width: colors.width, height: colors.height)
                shift = s * Float(lowLongSide) / Float(max(1, colors.longSide))
                var n = 0
                for i in 0..<luma.count where abs(luma[i] - previousLuma[i]) > 0.04 { n += 1 }
                changed = Float(n) / Float(max(1, luma.count))
            }
            previousLuma = luma
            previousLumaSize = (colors.width, colors.height)
            stillness = TemporalState.stillness(shift: shift, cutoff: settings.motionCutoff)
        }
        // 扫镜头的判断留给后面几帧的对焦用（延续 0.25 秒，避免两次扫之间的停顿又变回长时间坚持）
        if shift >= 2 { movingUntil = frame.time + 0.25 }

        // 6. 主体种子（深度图分辨率）
        var matte = settings.matte
        // 按颜色补主体边缘只用在相对深度（双摄视差 / AI）上：LiDAR 的边缘本来就准，
        // 补了反而可能把紧挨着主体、颜色相近的后面的东西（比如后面的人）也拉清晰
        if !frame.relativeDepth { matte.colorGrowth = 0 }
        var seeds: SubjectSeeds?
        if settings.keepSubjectSharp {
            let colors = frame.colors.map { $0.width == map.width && $0.height == map.height
                ? $0 : $0.resized(width: map.width, height: map.height) }
            seeds = SubjectMatte.seeds(depth: map, colors: colors, focusDisparity: focusD, focusPoint: (fx, fy),
                                       parameters: matte, scale: relativeScale,
                                       personMask: frame.personMask?.centerCropped(by: c))
        }

        return FramePlan(lens: lens, focusPoint: (fx, fy), streamFocusPoint: p, focusRecentered: recentered,
                         focusDisparity: focusD, focusDistance: distance, tooClose: tooClose, cameraMoving: moving,
                         cameraShift: shift, stillness: stillness, renderEffect: effectAmount >= 0.02,
                         layerCenters: centers, seeds: seeds, matte: matte, depth: map, lowLongSide: lowLongSide,
                         changedFraction: changed)
    }

    /// 拍下来的照片：没有时间历史，对焦点直接取中位数
    public static func stillPlan(disparity: FloatMap, relativeDepth: Bool, colors: PlanarImage?, fNumber: Float,
                                 focusPoint: (x: Float, y: Float), personMask: FloatMap?, outputLongSide: Int,
                                 settings: Settings) -> FramePlan {
        let map = DepthRefiner.fillInvalid(disparity)
        let lowLongSide = max(320, outputLongSide / max(1, settings.blurDownscale))
        let focusD = DepthRefiner.focusDisparity(in: map, nx: focusPoint.x, ny: focusPoint.y)
        var relativeScale: Float?
        if relativeDepth, let range = map.percentiles(0.05, 0.95) {
            relativeScale = max(focusD, 0.25 * (range.high - range.low))
        }
        let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, model: settings.lensModel,
                                  focalLength35mm: settings.virtualFocalLength, focusTolerance: settings.focusTolerance,
                                  relativeScale: relativeScale)
        var dMin = Float.infinity, dMax = -Float.infinity
        for v in map.values where v.isFinite { dMin = min(dMin, v); dMax = max(dMax, v) }
        if !dMin.isFinite { dMin = focusD; dMax = focusD }
        let sMin = min(0, lens.signedBlurRadius(disparity: dMin, imageLongSide: lowLongSide))
        let sMax = max(0, lens.signedBlurRadius(disparity: dMax, imageLongSide: lowLongSide))
        let centers = BokehRenderer.layerCenters(sMin: sMin, sMax: sMax, perSide: settings.layersPerSide)
        var matte = settings.matte
        if !relativeDepth { matte.colorGrowth = 0 }
        var seeds: SubjectSeeds?
        if settings.keepSubjectSharp {
            let c = colors.map { $0.width == map.width && $0.height == map.height
                ? $0 : $0.resized(width: map.width, height: map.height) }
            seeds = SubjectMatte.seeds(depth: map, colors: c, focusDisparity: focusD, focusPoint: focusPoint,
                                       parameters: matte, scale: relativeScale, personMask: personMask)
        }
        return FramePlan(lens: lens, focusPoint: focusPoint, streamFocusPoint: focusPoint, focusRecentered: false,
                         focusDisparity: focusD, focusDistance: relativeDepth ? nil : 1 / max(focusD, 1e-3),
                         tooClose: false, cameraMoving: false, cameraShift: 0, stillness: nil, renderEffect: true,
                         layerCenters: centers, seeds: seeds, matte: matte, depth: map, lowLongSide: lowLongSide)
    }
}
