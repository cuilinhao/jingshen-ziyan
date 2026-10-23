import Foundation

/// 实时预览的跨帧状态：让静止的画面在相邻帧之间保持稳定。
///
/// 实测（手机不动的 3 秒里）闪烁集中在两类地方：
///  - 深度边缘：深度流每帧的噪声让边缘处的模糊半径来回变，轮廓「呼吸」
///  - 焦外光斑：亮点在高光阈值附近的噪声被提亮倍数放大，光斑一闪一闪
/// 处理：在低分辨率上，把这一帧细化后的视差和高光提亮系数，向上一帧的值靠一部分。
/// 靠多少由这个像素的亮度变化决定 —— 画面没变（静止）就多沿用上一帧，
/// 画面变了（物体移动、手机移动）就完全用新值，所以运动时不会拖影。
public final class TemporalState {
    /// 画面完全静止的像素沿用上一帧的比例（0 = 关闭）
    public var strength: Float = 0.6
    /// 亮度（sRGB 0...1）变化的尺度：变化达到它时沿用比例降到 e⁻¹ 倍左右
    public var sigma: Float = 0.025

    var width = 0, height = 0
    var luma: [Float] = []
    var disparity: [Float] = []
    var boost: [Float] = []
    /// 当前帧每个像素沿用上一帧的比例（由 prepare 算出，render 里给高光用）
    var blend: [Float] = []
    /// 焦外区域的时间平滑强度（0 = 关闭）。只作用在已经虚化的地方：
    /// 灯管在卷帘快门下的明暗条纹、深度噪声、高光提亮的小波动都会让焦外光斑一闪一闪，
    /// 而焦外本来就没有细节，沿用一部分上一帧看不出拖影；清晰的主体完全不受影响
    public var backgroundStrength: Float = 0.7
    /// 相邻两帧焦外颜色的相对差异超过它，就认为是画面真的变了（运动），不再沿用
    public var backgroundSigma: Float = 0.25
    var bokehR: [Float] = [], bokehG: [Float] = [], bokehB: [Float] = []
    /// 手机移动（扫、晃）时整幅画面的平移量（低分辨率像素 / 帧）。由 prepare 估计
    public private(set) var cameraShift: Float = 0
    /// 平移达到多少像素（低分辨率、每帧）时完全不沿用上一帧。手持微抖约 0–1 像素，上下扫镜头 3–20 像素：
    /// 扫的时候还按静止的比例沿用上一帧，焦外和深度会拖在画面后面，看起来就是延迟
    public var motionCutoff: Float = 2
    /// 当前帧整体还能沿用上一帧的比例（1 = 静止，0 = 在扫镜头）
    var stillness: Float = 1
    /// 测试用：最近一次重新对齐时「变了」的区域
    public private(set) var debugUnreliable: FloatMap?
    /// 上一帧的低分辨率画面（线性光）：沿用旧深度时，和这一帧比哪里变了、东西往哪儿动
    var colors: PlanarImage?
    /// 从上一张新深度以来，被重新对齐过的区域（各帧「变了」的最大值）。新深度来的那一帧，这些地方不沿用上一帧的深度：
    /// 搬过来的深度难免有错，时间平滑会把错的再拖好几帧
    var suspect: [Float] = []

    public init() {}

    public func reset() {
        width = 0; height = 0
        luma = []; disparity = []; boost = []; blend = []
        bokehR = []; bokehG = []; bokehB = []
        cameraShift = 0; stillness = 1
        colors = nil; suspect = []
    }

    /// 这一帧没有新深度（depthAge ≥ 1，沿用旧的）时：不用那张旧深度，而是把上一帧已经对齐好的深度
    /// 按这一帧的画面再对齐一次（StaleDepth）。每次只差一帧，手挥得快也追得上；新深度一来就重新开始。
    /// 没有上一帧（第一帧、刚换相机）就原样返回
    func realignStaleDepth(_ d: FloatMap, colors now: PlanarImage, guideLuma: FloatMap, gfRadius: Int,
                           depthAge: Int) -> FloatMap {
        let previous = colors
        colors = now
        let n = d.width * d.height
        guard depthAge > 0, strength > 0, width == d.width, height == d.height, disparity.count == n, let previous,
              previous.width == d.width, previous.height == d.height else { return d }
        let r = StaleDepth.realign(depth: FloatMap(width: width, height: height, values: disparity), now: now,
                                   previous: previous, guideLuma: guideLuma, gfRadius: gfRadius)
        debugUnreliable = FloatMap(width: d.width, height: d.height, values: r.changed)
        if suspect.count == n {
            for i in 0..<n { suspect[i] = max(suspect[i], r.changed[i]) }
        } else {
            suspect = r.changed
        }
        return r.depth
    }

    /// 低分辨率虚化结果的时间平滑。w 是每个像素的虚化程度（0 清晰 … 1 完全虚化）
    func stabilizeBokeh(_ img: inout PlanarImage, defocus w: [Float]) {
        let n = img.pixelCount
        guard backgroundStrength > 0, bokehR.count == n, w.count == n else {
            bokehR = img.r; bokehG = img.g; bokehB = img.b
            return
        }
        let s = backgroundStrength * stillness, inv = 1 / backgroundSigma
        for i in 0..<n {
            let wi = w[i]
            if wi <= 0.01 { continue }
            let r = img.r[i], g = img.g[i], b = img.b[i]
            let pr = bokehR[i], pg = bokehG[i], pb = bokehB[i]
            let ref = 0.04 + max(max(r, g), max(b, max(pr, max(pg, pb))))
            let d = max(abs(r - pr), max(abs(g - pg), abs(b - pb))) / ref * inv
            let beta = s * wi * expf(-d * d)
            img.r[i] = r + beta * (pr - r)
            img.g[i] = g + beta * (pg - g)
            img.b[i] = b + beta * (pb - b)
        }
        bokehR = img.r; bokehG = img.g; bokehB = img.b
    }

    /// 根据这一帧的亮度算出 blend，并把视差向上一帧靠拢。返回稳定后的视差
    /// - Parameters:
    ///   - stillness: 外面已经估计好的「画面整体静止程度」（LiveFrameAnalyzer），nil = 这里自己估计
    ///   - freshDepth: 这一帧的深度是新的（不是沿用、重新对齐的）。之前被重新对齐过的区域这一帧不沿用上一帧
    func prepare(luma now: [Float], disparity d: FloatMap, stillness given: Float? = nil,
                 freshDepth: Bool = true) -> FloatMap {
        let n = d.width * d.height
        let gate = freshDepth && suspect.count == n ? suspect : nil
        if freshDepth { suspect = [] }
        guard strength > 0, width == d.width, height == d.height, luma.count == n, disparity.count == n else {
            width = d.width; height = d.height
            blend = [Float](repeating: 0, count: n)
            luma = now; disparity = d.values; boost = []
            return d
        }
        // 3×3 平均后的亮度差，避免单像素噪声
        let w = d.width, h = d.height
        // 整幅画面在平移（手机在动）：按平移量减少沿用上一帧的比例
        if let given {
            stillness = given
        } else {
            cameraShift = Self.globalShift(now, luma, width: w, height: h)
            stillness = Self.stillness(shift: cameraShift, cutoff: motionCutoff)
        }
        var diff = [Float](repeating: 0, count: n)
        for i in 0..<n { diff[i] = abs(now[i] - luma[i]) }
        let dm = BoxFilter.mean(diff, width: w, height: h, radius: 1)
        var out = d.values
        let s = strength * stillness, inv = 1 / sigma
        for i in 0..<n {
            let x = dm[i] * inv
            var b = s * expf(-x * x)
            if let gate { b *= 1 - gate[i] }
            blend[i] = b
            out[i] += b * (disparity[i] - out[i])
        }
        luma = now
        disparity = out
        return FloatMap(width: w, height: h, values: out)
    }

    /// 平移量（低分辨率像素 / 帧）→ 沿用上一帧的比例：0.5 像素以内全沿用，到 cutoff 完全不沿用
    public static func stillness(shift: Float, cutoff: Float) -> Float {
        min(1, max(0, 1 - (shift - 0.5) / max(cutoff - 0.5, 0.1)))
    }

    /// 两帧亮度之间的整体平移（像素，当前分辨率）。先在 1/4 分辨率上 ±3 搜索，再在 1/2 分辨率上 ±1 细化。
    /// 纹理太少（平移前后差别不明显）时返回 0
    public static func globalShift(_ a: [Float], _ b: [Float], width w: Int, height h: Int) -> Float {
        guard a.count == w * h, b.count == w * h else { return 0 }
        func down(_ s: [Float], _ f: Int) -> (v: [Float], w: Int, h: Int) {
            let sw = w / f, sh = h / f
            var out = [Float](repeating: 0, count: sw * sh)
            let inv = 1 / Float(f * f)
            for y in 0..<sh {
                for x in 0..<sw {
                    var sum: Float = 0
                    for yy in 0..<f { let row = (y * f + yy) * w + x * f; for xx in 0..<f { sum += s[row + xx] } }
                    out[y * sw + x] = sum * inv
                }
            }
            return (out, sw, sh)
        }
        func sad(_ A: [Float], _ B: [Float], _ sw: Int, _ sh: Int, _ dx: Int, _ dy: Int, _ m: Int) -> Float {
            var sum: Float = 0
            for y in m..<(sh - m) {
                let ra = y * sw, rb = (y + dy) * sw + dx
                for x in m..<(sw - m) { sum += abs(A[ra + x] - B[rb + x]) }
            }
            return sum
        }
        let q1 = down(a, 4), q2 = down(b, 4)
        guard q1.w >= 24, q1.h >= 16 else { return 0 }
        let R = 3
        var best = Float.infinity, bx = 0, by = 0
        let zero = sad(q1.v, q2.v, q1.w, q1.h, 0, 0, R)
        for dy in -R...R {
            for dx in -R...R {
                let v = sad(q1.v, q2.v, q1.w, q1.h, dx, dy, R)
                if v < best { best = v; bx = dx; by = dy }
            }
        }
        guard best < zero * 0.9 else { return 0 }
        // 1/2 分辨率上细化
        let h1 = down(a, 2), h2 = down(b, 2)
        let m = 2 * R + 1
        var best2 = Float.infinity, fx = 2 * bx, fy = 2 * by
        for dy in (2 * by - 1)...(2 * by + 1) {
            for dx in (2 * bx - 1)...(2 * bx + 1) {
                let v = sad(h1.v, h2.v, h1.w, h1.h, dx, dy, m)
                if v < best2 { best2 = v; fx = dx; fy = dy }
            }
        }
        return 2 * sqrtf(Float(fx * fx + fy * fy))
    }

    /// 高光提亮系数的时间稳定（在 render 里调用）
    func stabilizeBoost(_ b: inout [Float]) {
        if boost.count == b.count && blend.count == b.count {
            for i in 0..<b.count { b[i] += blend[i] * (boost[i] - b[i]) }   // blend 已含 stillness
        }
        boost = b
    }
}
