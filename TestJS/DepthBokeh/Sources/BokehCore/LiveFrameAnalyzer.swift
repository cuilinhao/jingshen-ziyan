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
    /// 深度是几帧之前的（这一帧没有新深度、沿用了旧的）。≥ 1 时渲染不用旧深度，而是把上一帧对齐好的深度
    /// 按这一帧的画面再对齐一次（StaleDepth）。0 = 深度是这一帧的，或者和上一帧裁得不一样、没法对齐
    public var depthAge: Int = 0
    /// 人像遮罩算的那一帧到现在，人那块（往外扩一点）画面变了不少（人在动），该重新分割了。
    /// 手抖造成的整体平移不算（遮罩已经跟着挪过来了）。nil = 没有人像遮罩
    public var personMaskStale: Bool?
    /// 同上，对焦的那个物体。nil = 对焦点上没有物体
    public var objectMaskStale: Bool?
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
        /// 算遮罩用的那一帧画面（整个相机画面，任意小尺寸，线性光）。
        /// 分割在别的线程上跑，遮罩总是晚几帧：画面从那以后变了的地方（人在动）不再相信遮罩；nil = 不检查
        public var personMaskColors: PlanarImage?
        /// 输出画面的长边（像素），决定模糊部分的分辨率
        public var outputLongSide: Int
        /// 深度是几帧之前的（这一帧没有新深度、沿用了旧的）。0 = 这一帧的
        public var depthAge: Int
        /// 物体分割的标签图（Vision 前景实例，整个相机画面，任意分辨率；0 = 背景，1…N = 各个物体）。
        /// 对焦点落在某个物体上、深度也对得上时，整个物体保持清晰（和人像遮罩一样）：
        /// 斜着看到的盒子顶面在深度图里拿到的是背景的深度，靠它补回来
        public var objectLabels: FloatMap?
        /// 算物体分割那一帧的画面（同 personMaskColors）
        public var objectColors: PlanarImage?
        /// 物体标签图的版本号（每次重新分割加 1）：版本、对焦点、裁切都没变时直接用上一帧选好的物体。0 = 每帧重新选
        public var objectRevision: Int
        /// 人像实例分割的标签图（Vision 的 VNGeneratePersonInstanceMaskRequest，整个相机画面，任意分辨率；
        /// 0 = 不是人，1…N = 各个人）。人像遮罩把画面里所有人当成一片：对焦的人和后面的人在画面上挨着时，
        /// 后面的人也会被当成主体保持清晰。有了它，不是对焦的那个人、深度也和对焦面对不上的，从人像遮罩里去掉
        public var personInstances: FloatMap?
        /// 算人像实例那一帧的画面（同 personMaskColors）
        public var personInstanceColors: PlanarImage?
        /// 人像实例标签图的版本号（每次重新分割加 1）：版本、裁切都没变时直接用上次拆好的遮罩。0 = 每帧重新拆
        public var personInstanceRevision: Int
        /// 渲染出来的画面的 35mm 等效焦距（毫米，已含数码裁切；1× = 24mm）。`.system` 模型按它放大虚化
        /// （LensParameters.scaleForFocalLength）；nil = 按 1× 的标定
        public var focalLength35mm: Float?

        public init(disparity: FloatMap, relativeDepth: Bool, crop: Float, fNumber: Float,
                    focusPoint: (x: Float, y: Float), focusTapped: Bool, time: Double,
                    colors: PlanarImage?, personMask: FloatMap?, outputLongSide: Int,
                    personMaskColors: PlanarImage? = nil, depthAge: Int = 0,
                    objectLabels: FloatMap? = nil, objectColors: PlanarImage? = nil, objectRevision: Int = 0,
                    personInstances: FloatMap? = nil, personInstanceColors: PlanarImage? = nil,
                    personInstanceRevision: Int = 0, focalLength35mm: Float? = nil) {
            self.focalLength35mm = focalLength35mm
            self.personInstances = personInstances
            self.personInstanceColors = personInstanceColors
            self.personInstanceRevision = personInstanceRevision
            self.objectLabels = objectLabels
            self.objectColors = objectColors
            self.objectRevision = objectRevision
            self.disparity = disparity
            self.relativeDepth = relativeDepth
            self.crop = crop
            self.fNumber = fNumber
            self.focusPoint = focusPoint
            self.focusTapped = focusTapped
            self.time = time
            self.colors = colors
            self.personMask = personMask
            self.personMaskColors = personMaskColors
            self.outputLongSide = outputLongSide
            self.depthAge = depthAge
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
    /// 上一帧的裁切比例：裁得不一样，上一帧的深度就没法直接和这一帧对齐
    private var lastCrop: Float?
    /// 上一次选出来的物体（已裁切、缩放到深度图大小）和那一帧的小图（已裁切）。标签图没更新、对焦点和裁切没变时直接用
    private var objectCache: (revision: Int, point: (Float, Float), crop: Float, w: Int, h: Int,
                              mask: FloatMap?, colors: PlanarImage?)?
    /// 上一次按编号拆开的人像实例（已裁切、缩放到深度图大小）和那一帧的小图（已裁切）。标签图没更新、裁切没变时直接用
    private var personInstanceCache: (revision: Int, crop: Float, w: Int, h: Int,
                                      parts: [(label: Int, mask: FloatMap)], colors: PlanarImage?)?

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
        lastCrop = nil
        objectCache = nil
        personInstanceCache = nil
    }

    public func analyze(_ frame: Frame) -> FramePlan {
        let c = max(frame.crop, 1)
        var depthAge = max(0, frame.depthAge)
        if let lc = lastCrop, abs(lc - c) > 0.002 * c { depthAge = 0 }
        if lastCrop == nil { depthAge = 0 }
        lastCrop = c
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
        // 长焦：同样的视差差虚化更大、全清晰区更窄（标定是 1× 的）
        if let f = frame.focalLength35mm { lens.scaleForFocalLength(f) }
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
        // 按颜色补主体边缘：LiDAR 的边缘比双摄准，只补窄一点的一圈（盒子顶面这种只有十来个深度像素高的面）
        if !frame.relativeDepth { matte.colorGrowth = matte.absoluteColorGrowth }
        var seeds: SubjectSeeds?
        var personStale: Bool?, objectStale: Bool?
        if settings.keepSubjectSharp {
            let colors = frame.colors.map { $0.width == map.width && $0.height == map.height
                ? $0 : $0.resized(width: map.width, height: map.height) }
            // 人像、物体遮罩的小图一般一样大：这一帧缩小到比较尺寸只做一次
            var colorsSmall: PlanarImage?
            func small(for then: PlanarImage, _ colors: PlanarImage) -> PlanarImage {
                let (cw, ch) = Self.compareSize(then)
                if let s = colorsSmall, s.width == cw, s.height == ch { return s }
                let s = colors.resized(width: cw, height: ch)
                colorsSmall = s
                return s
            }
            var person = frame.personMask?.centerCropped(by: c)
            if let pm = person, let then = frame.personMaskColors?.centerCropped(by: c), let colors {
                let aligned = Self.alignMask(pm, maskColors: then, colors: colors, colorsSmall: small(for: then, colors))
                person = aligned.mask
                personStale = aligned.changed >= Self.maskStaleFraction
            }
            // 人像遮罩分不出是谁：对焦的人和后面的同事在画面上挨着时连成一片，后面的人也被一起保持清晰。
            // 用人像实例把不是对焦的那个人、深度也和对焦面对不上的去掉（照常按深度虚化）
            if let pm = person, let labels = frame.personInstances {
                let parts: [(label: Int, mask: FloatMap)]
                let then: PlanarImage?
                if let k = personInstanceCache, frame.personInstanceRevision != 0,
                   k.revision == frame.personInstanceRevision, k.crop == c, k.w == map.width, k.h == map.height {
                    parts = k.parts
                    then = k.colors
                } else {
                    parts = Self.instanceMasks(labels, crop: c, width: map.width, height: map.height)
                    then = frame.personInstanceColors?.centerCropped(by: c)
                    personInstanceCache = (frame.personInstanceRevision, c, map.width, map.height, parts, then)
                }
                if var others = Self.otherPeople(parts, focusLabel: SubjectMatte.instanceLabel(labels, point: p),
                                                 depth: map, focusDisparity: focusD,
                                                 norm: max(relativeScale ?? focusD, 1e-3), matte: matte, lens: lens) {
                    // 实例也是几帧之前算的：和遮罩一样按整体平移挪到这一帧
                    if let then, let colors {
                        others = Self.alignMask(others, maskColors: then, colors: colors,
                                                colorsSmall: small(for: then, colors)).mask
                    }
                    person = Self.removing(others, from: pm)
                }
            }
            // 对焦的那个物体（在整个相机画面上按对焦点选，再裁）。标签图几秒才更新一次：没变就用上次选好的
            var selected: (mask: FloatMap?, colors: PlanarImage?) = (nil, nil)
            if let labels = frame.objectLabels {
                if let k = objectCache, frame.objectRevision != 0, k.revision == frame.objectRevision,
                   k.point == p, k.crop == c, k.w == map.width, k.h == map.height {
                    selected = (k.mask, k.colors)
                } else {
                    let inst = SubjectMatte.instanceAt(labels, point: p)
                    selected = (inst?.centerCropped(by: c).resized(width: map.width, height: map.height),
                                frame.objectColors?.centerCropped(by: c))
                    objectCache = (frame.objectRevision, p, c, map.width, map.height, selected.mask, selected.colors)
                }
            }
            if var object = selected.mask {
                if let then = selected.colors, let colors {
                    let aligned = Self.alignMask(object, maskColors: then, colors: colors,
                                                 colorsSmall: small(for: then, colors))
                    object = aligned.mask
                    objectStale = aligned.changed >= Self.maskStaleFraction
                }
                // 细条最宽：整张深度图长边的 1/40（裁切后按原来的像素算，320 宽时 8 像素）
                let reach = max(2, Int((Float(max(frame.disparity.width, frame.disparity.height)) / 40).rounded()))
                person = Self.addObject(object, to: person, depth: map, focusDisparity: focusD,
                                        norm: max(relativeScale ?? focusD, 1e-3), matte: matte, reach: reach)
            }
            seeds = SubjectMatte.seeds(depth: map, colors: colors, focusDisparity: focusD, focusPoint: (fx, fy),
                                       parameters: matte, scale: relativeScale, personMask: person)
        }

        return FramePlan(lens: lens, focusPoint: (fx, fy), streamFocusPoint: p, focusRecentered: recentered,
                         focusDisparity: focusD, focusDistance: distance, tooClose: tooClose, cameraMoving: moving,
                         cameraShift: shift, stillness: stillness, renderEffect: effectAmount >= 0.02,
                         layerCenters: centers, seeds: seeds, matte: matte, depth: map, lowLongSide: lowLongSide,
                         changedFraction: changed, depthAge: depthAge, personMaskStale: personStale,
                         objectMaskStale: objectStale)
    }

    /// 人像实例标签图（整个相机画面，任意分辨率；0 = 不是人，1…N = 各个人）按编号拆开：每个人一张遮罩，
    /// 中心裁切 crop 倍、缩放到 w×h（0…1）
    static func instanceMasks(_ labels: FloatMap, crop c: Float, width w: Int,
                              height h: Int) -> [(label: Int, mask: FloatMap)] {
        var ids = Set<Int>()
        for v in labels.values where v > 0.5 { ids.insert(Int(v.rounded())) }
        return ids.sorted().map { id in
            let m = FloatMap(width: labels.width, height: labels.height,
                             values: labels.values.map { Int($0.rounded()) == id ? 1 : 0 })
            return (id, m.centerCropped(by: c).resized(width: w, height: h))
        }
    }

    /// 不该和对焦的人一起保持清晰的人：不是对焦点所在的那个人，并且
    ///  - 深度在对焦面 ±band 以内的不到 personDepthAgreement（对焦的人后面站着的同事），或者
    ///  - 按镜头算会明显虚化（lensBlurred）：双摄 / AI 的相对视差带着未知的偏移（+0.2…0.4），对焦在远处时 band 被放得很宽
    ///    （4× 对焦 3.75 m 的人，2.4–8 m 都算「差不多远」），近处的人光看 band 留不住
    /// 站在旁边、和对焦的人差不多远的人照样保持清晰（系统相机也是这样）。
    /// 返回这些人合起来的遮罩（和深度图一样大，0…1）；没有返回 nil
    static func otherPeople(_ parts: [(label: Int, mask: FloatMap)], focusLabel: Int?, depth: FloatMap,
                            focusDisparity df: Float, norm: Float, matte: SubjectMatteParameters,
                            lens: LensParameters? = nil) -> FloatMap? {
        let w = depth.width, h = depth.height, n = w * h
        var out: [Float]?
        for part in parts where part.label != focusLabel && part.mask.width == w && part.mask.height == h {
            let agree = SubjectMatte.depthAgreement(part.mask.values, depth: depth.values, focusDisparity: df,
                                                    norm: norm, band: matte.band)
            guard agree < matte.personDepthAgreement
                    || lensBlurred(part.mask.values, depth: depth.values, lens: lens, limit: matte.personMaxBlur,
                                   share: matte.personDepthAgreement) else { continue }
            var v = out ?? [Float](repeating: 0, count: n)
            for i in 0..<n { v[i] = max(v[i], part.mask.values[i]) }
            out = v
        }
        return out.map { FloatMap(width: w, height: h, values: $0) }
    }

    /// 遮罩里的像素按镜头算会不会明显虚化：虚化半径不超过长边 limit 的像素不到 share（大部分都会糊）。lens 为 nil 时 false
    static func lensBlurred(_ mask: [Float], depth: [Float], lens: LensParameters?, limit: Float, share: Float) -> Bool {
        guard let lens, limit > 0 else { return false }
        let L = 1000, maxR = limit * Float(L)
        var n = 0, sharp = 0
        for i in 0..<min(mask.count, depth.count) where mask[i] > 0.5 {
            n += 1
            if depth[i].isFinite && abs(lens.signedBlurRadius(disparity: depth[i], imageLongSide: L)) <= maxR { sharp += 1 }
        }
        return n >= 12 && Float(sharp) < share * Float(n)
    }

    /// 人像遮罩里去掉 others（任意分辨率，0…1），返回和人像遮罩一样大的
    static func removing(_ others: FloatMap, from person: FloatMap) -> FloatMap {
        let o = others.resized(width: person.width, height: person.height).values
        var v = person.values
        for i in 0..<v.count { v[i] *= 1 - min(1, max(0, o[i])) }
        return FloatMap(width: person.width, height: person.height, values: v)
    }

    /// 物体遮罩（和深度图一样大）的深度和对焦面对得上，就并进人像遮罩（两者取大）；对不上原样返回人像遮罩
    static func addObject(_ object: FloatMap, to person: FloatMap?, depth: FloatMap, focusDisparity df: Float,
                          norm: Float, matte: SubjectMatteParameters, reach: Int = 8) -> FloatMap? {
        let agree = SubjectMatte.depthAgreement(object.values, depth: depth.values, focusDisparity: df, norm: norm,
                                                band: matte.band)
        guard agree >= matte.objectDepthAgreement else { return person }
        let object = refineObject(object, depth: depth, focusDisparity: df, norm: norm, band: matte.band, reach: reach)
        guard let person else { return object }
        let pm = person.resized(width: object.width, height: object.height)
        var v = object.values
        for i in 0..<v.count { v[i] = max(v[i], pm.values[i]) }
        return FloatMap(width: object.width, height: object.height, values: v)
    }

    /// 物体遮罩里深度对不上（不在对焦面 ±band 里）的部分，哪些还算物体：
    ///  - 细条（贴着深度对得上的那部分、不到 2·reach 宽）：盒子顶面这种，深度被滤波抹成了到背景的过渡，正要靠物体分割补回来；
    ///  - 成块、但深度和旁边的背景一样：也是深度从背景渗进来的（顶面整个拿到了背景的深度），算物体；
    ///  - 成块、深度既不是对焦面也不是旁边的背景：是另一个东西。Vision 会把画面上挨着的东西算进同一个物体
    ///    （盒子后面的罐子），它有自己的深度，应该照常虚化，去掉。
    /// reach：细条最宽多少（深度图像素，按整张深度图算，裁切后也一样）
    static func refineObject(_ object: FloatMap, depth: FloatMap, focusDisparity df: Float, norm: Float,
                             band: Float, reach: Int) -> FloatMap {
        let w = object.width, h = object.height, n = w * h
        guard depth.width == w, depth.height == h, n > 0 else { return object }
        let o = object.values, d = depth.values
        var inBand = [Float](repeating: 0, count: n), outside = [Float](repeating: 0, count: n)
        var notOutside = [Float](repeating: 1, count: n)
        var anyOutside = false
        for i in 0..<n where o[i] > 0.5 {
            if d[i].isFinite && abs((d[i] - df) / norm) < band {
                inBand[i] = 1
            } else {
                outside[i] = 1; notOutside[i] = 0; anyOutside = true
            }
        }
        guard anyOutside else { return object }
        let r = max(1, reach)
        // 腐蚀 reach 以后还剩下的：比 2·reach 宽的成块部分
        let notEroded = SubjectMatte.dilateBinary(notOutside, width: w, height: h, radius: r)
        let near = SubjectMatte.dilateBinary(inBand, width: w, height: h, radius: r)
        var keep = inBand
        var label = [Int32](repeating: 0, count: n)
        var next: Int32 = 0
        func median(_ v: inout [Float]) -> Float? {
            guard !v.isEmpty else { return nil }
            v.sort()
            return v[v.count / 2]
        }
        for start in 0..<n where outside[start] > 0 && label[start] == 0 {
            // 4 连通的一块
            next += 1
            var members: [Int] = [start]
            label[start] = next
            var k = 0
            while k < members.count {
                let i = members[k]; k += 1
                let x = i % w, y = i / w
                for (q, ok) in [(i - 1, x > 0), (i + 1, x < w - 1), (i - w, y > 0), (i + w, y < h - 1)]
                where ok && outside[q] > 0 && label[q] == 0 {
                    label[q] = next
                    members.append(q)
                }
            }
            let thick = members.contains { notEroded[$0] == 0 }
            var keepAll = !thick
            if thick {
                // 和旁边（物体外面 3 像素以内）的背景比深度
                var own = members.compactMap { d[$0].isFinite ? d[$0] : nil }
                var ring: [Float] = []
                var seen = Set<Int>()
                for i in members {
                    let x = i % w, y = i / w
                    for yy in max(0, y - 3)...min(h - 1, y + 3) {
                        for xx in max(0, x - 3)...min(w - 1, x + 3) {
                            let j = yy * w + xx
                            if o[j] <= 0.5, d[j].isFinite, seen.insert(j).inserted { ring.append(d[j]) }
                        }
                    }
                }
                if let dc = median(&own), let dr = median(&ring) {
                    keepAll = abs(dc - dr) < 0.5 * band * norm
                }
            }
            for i in members where keepAll && (thick || near[i] > 0) { keep[i] = 1 }
        }
        // 往外留 1 像素：遮罩缩放后的软边
        let soft = SubjectMatte.dilateBinary(keep, width: w, height: h, radius: 1)
        var v = o
        for i in 0..<n where soft[i] == 0 || (outside[i] > 0 && keep[i] == 0) { v[i] = 0 }
        return FloatMap(width: w, height: h, values: v)
    }

    /// 遮罩那块（往外扩一点）里变了的比例达到多少算「该重新分割了」
    static let maskStaleFraction: Float = 0.02

    /// 人像遮罩是几帧之前的画面算的：从那以后画面变了的地方（人在动，手离开的地方）不再相信遮罩。
    /// 不然手挥走以后，手原来的位置还被当成「人」保持清晰，背景在那里清清楚楚地露出来，像重影。
    /// 返回和 colors 一样大的遮罩
    static func dropStaleMask(_ mask: FloatMap, maskColors: PlanarImage, colors: PlanarImage) -> FloatMap {
        alignMask(mask, maskColors: maskColors, colors: colors).mask
    }

    /// 几帧之前算的遮罩对到这一帧：整幅画面平移了（手抖）就把遮罩跟着挪过去，变了的地方扔掉。
    /// - Returns: 对齐后的遮罩（和 colors 一样大）；遮罩那块（往外扩一点）里有多少变了（0…1，决定要不要重新分割）
    static func alignMask(_ mask: FloatMap, maskColors: PlanarImage, colors: PlanarImage,
                          colorsSmall: PlanarImage? = nil) -> (mask: FloatMap, changed: Float) {
        let w = colors.width, h = colors.height
        let m = mask.resized(width: w, height: h)
        // 在很小的尺寸上比（长边约 80）：两张图的分辨率、取样位置不一样，边缘上的细微差别不算「变了」；
        // 手抖造成的整体平移、一两个像素的错位也不算（长焦手持时一直在抖）。人挥手这种大变化照样看得出来
        let (cw, ch) = compareSize(maskColors)
        let now = colorsSmall.flatMap { $0.width == cw && $0.height == ch ? $0 : nil }
            ?? colors.resized(width: cw, height: ch)
        let r = StaleDepth.changeAndShift(now, since: maskColors.resized(width: cw, height: ch))
        // 遮罩跟着整体平移挪过来（遮罩是那一帧的位置：现在的 (x, y) 对应那一帧的 (x + 平移, y + 平移)）。
        // 不到 1/4 像素的不挪（估计本身就有这么大的误差）
        var dx = r.shift.x * Float(w) / Float(cw), dy = r.shift.y * Float(h) / Float(ch)
        if abs(dx) < 0.25 { dx = 0 }
        if abs(dy) < 0.25 { dy = 0 }
        let shifted = Self.translated(m, dx: dx, dy: dy)
        var v = shifted.values
        // 哪儿都没变（画面静止时的常态）：不用放大变化图
        if r.changed.contains(where: { $0 > 0 }) {
            let u = FloatMap(width: cw, height: ch, values: r.changed).resized(width: w, height: h).values
            for i in 0..<(w * h) { v[i] *= 1 - u[i] }
        }
        // 遮罩那块往外扩 2 个小图像素，里面变了多少
        let ms = shifted.resized(width: cw, height: ch).values
        var region: Float = 0, hit: Float = 0
        for y in 0..<ch {
            for x in 0..<cw {
                var inside = false
                for yy in max(0, y - 2)...min(ch - 1, y + 2) where !inside {
                    for xx in max(0, x - 2)...min(cw - 1, x + 2) where ms[yy * cw + xx] > 0.5 { inside = true; break }
                }
                if inside { region += 1; hit += r.changed[y * cw + x] }
            }
        }
        return (FloatMap(width: w, height: h, values: v), region > 0 ? hit / region : 0)
    }

    /// 和算遮罩那一帧的小图比较时用的尺寸（长边约 80）
    static func compareSize(_ maskColors: PlanarImage) -> (Int, Int) {
        let s = min(1, 80 / Float(max(maskColors.width, maskColors.height, 1)))
        return (max(8, Int((Float(maskColors.width) * s).rounded())), max(8, Int((Float(maskColors.height) * s).rounded())))
    }

    /// 整张图平移（双线性，取样点 (x + dx, y + dy)，出界取边上的值）
    static func translated(_ m: FloatMap, dx: Float, dy: Float) -> FloatMap {
        guard abs(dx) > 1e-3 || abs(dy) > 1e-3 else { return m }
        let w = m.width, h = m.height
        var out = [Float](repeating: 0, count: w * h)
        m.values.withUnsafeBufferPointer { src in
            for y in 0..<h {
                let sy = min(max(Float(y) + dy, 0), Float(h - 1))
                let y0 = Int(sy), y1 = min(y0 + 1, h - 1), ty = sy - Float(y0)
                for x in 0..<w {
                    let sx = min(max(Float(x) + dx, 0), Float(w - 1))
                    let x0 = Int(sx), x1 = min(x0 + 1, w - 1), tx = sx - Float(x0)
                    let a = src[y0 * w + x0] + (src[y0 * w + x1] - src[y0 * w + x0]) * tx
                    let b = src[y1 * w + x0] + (src[y1 * w + x1] - src[y1 * w + x0]) * tx
                    out[y * w + x] = a + (b - a) * ty
                }
            }
        }
        return FloatMap(width: w, height: h, values: out)
    }

    /// 拍下来的照片：没有时间历史，对焦点直接取中位数
    public static func stillPlan(disparity: FloatMap, relativeDepth: Bool, colors: PlanarImage?, fNumber: Float,
                                 focusPoint: (x: Float, y: Float), personMask: FloatMap?, outputLongSide: Int,
                                 settings: Settings, objectLabels: FloatMap? = nil,
                                 personInstances: FloatMap? = nil, focalLength35mm: Float? = nil) -> FramePlan {
        let map = DepthRefiner.fillInvalid(disparity)
        let lowLongSide = max(320, outputLongSide / max(1, settings.blurDownscale))
        let focusD = DepthRefiner.focusDisparity(in: map, nx: focusPoint.x, ny: focusPoint.y)
        var relativeScale: Float?
        if relativeDepth, let range = map.percentiles(0.05, 0.95) {
            relativeScale = max(focusD, 0.25 * (range.high - range.low))
        }
        var lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, model: settings.lensModel,
                                  focalLength35mm: settings.virtualFocalLength, focusTolerance: settings.focusTolerance,
                                  relativeScale: relativeScale)
        // 拍照时的焦距（同 analyze）
        if let f = focalLength35mm { lens.scaleForFocalLength(f) }
        var dMin = Float.infinity, dMax = -Float.infinity
        for v in map.values where v.isFinite { dMin = min(dMin, v); dMax = max(dMax, v) }
        if !dMin.isFinite { dMin = focusD; dMax = focusD }
        let sMin = min(0, lens.signedBlurRadius(disparity: dMin, imageLongSide: lowLongSide))
        let sMax = max(0, lens.signedBlurRadius(disparity: dMax, imageLongSide: lowLongSide))
        let centers = BokehRenderer.layerCenters(sMin: sMin, sMax: sMax, perSide: settings.layersPerSide)
        var matte = settings.matte
        if !relativeDepth { matte.colorGrowth = matte.absoluteColorGrowth }
        var seeds: SubjectSeeds?
        if settings.keepSubjectSharp {
            let c = colors.map { $0.width == map.width && $0.height == map.height
                ? $0 : $0.resized(width: map.width, height: map.height) }
            var person = personMask
            // 后面挨着的别人（深度对不上的）不和对焦的人一起保持清晰（同 analyze）
            if let pm = person, let labels = personInstances,
               let others = otherPeople(instanceMasks(labels, crop: 1, width: map.width, height: map.height),
                                        focusLabel: SubjectMatte.instanceLabel(labels, point: focusPoint), depth: map,
                                        focusDisparity: focusD, norm: max(relativeScale ?? focusD, 1e-3),
                                        matte: matte, lens: lens) {
                person = removing(others, from: pm)
            }
            if let labels = objectLabels, let inst = SubjectMatte.instanceAt(labels, point: focusPoint) {
                person = addObject(inst.resized(width: map.width, height: map.height), to: person, depth: map,
                                   focusDisparity: focusD, norm: max(relativeScale ?? focusD, 1e-3), matte: matte,
                                   reach: max(2, Int((Float(max(map.width, map.height)) / 40).rounded())))
            }
            seeds = SubjectMatte.seeds(depth: map, colors: c, focusDisparity: focusD, focusPoint: focusPoint,
                                       parameters: matte, scale: relativeScale, personMask: person)
        }
        return FramePlan(lens: lens, focusPoint: focusPoint, streamFocusPoint: focusPoint, focusRecentered: false,
                         focusDisparity: focusD, focusDistance: relativeDepth ? nil : 1 / max(focusD, 1e-3),
                         tooClose: false, cameraMoving: false, cameraShift: 0, stillness: nil, renderEffect: true,
                         layerCenters: centers, seeds: seeds, matte: matte, depth: map, lowLongSide: lowLongSide)
    }
}
