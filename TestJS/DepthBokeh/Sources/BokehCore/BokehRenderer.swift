import Foundation

/// 纯 Swift 的合成景深渲染器。
///
/// 输入：线性光彩色图 + 同尺寸视差图（1/米）+ 虚拟镜头参数
/// 输出：模拟大光圈镜头拍出来的图
///
/// 算法（分层散景，layered bokeh）：
///  1. 用镜头公式算出每个像素带符号的弥散圆半径 s（前景为正、背景为负）
///  2. 按 s 把画面切成若干「深度层」，每个像素按 s 线性分配到相邻两层（避免分层断带）
///  3. 每层用「圆盘核」模糊（不是高斯！真镜头的焦外是边缘清晰的圆盘），
///     用逐行前缀和实现，每像素 O(r) 而不是 O(r²)
///  4. 背景层从远到近叠加，然后用 pull-push 把前景遮挡留下的空洞补上
///     （相当于猜出被前景挡住的背景）
///  5. 前景层从远到近 over 合成到补好的背景上 —— 前景虚化会自然地向外扩散、
///     边缘变半透明，盖住后面清晰的背景
///  6. 焦外高光在模糊前提亮，模拟 HDR 场景里亮点被「摊」成光斑的效果
public final class BokehRenderer {

    /// 上一次渲染用了多少层
    public private(set) var lastLayerCount = 0
    /// 上一次渲染耗时（毫秒）
    public private(set) var lastRenderMilliseconds: Double = 0
    /// 调试用：打开后双分辨率渲染会把低分辨率的虚化程度 w 和细化后的视差留下来
    public var captureDebugMaps = false
    /// 各步骤耗时（毫秒），每次 renderDetailPreserving 重新填写
    public var stageTimings: [(String, Double)] = []
    public internal(set) var debugWeights: FloatMap?
    public internal(set) var debugLowDisparity: FloatMap?
    public internal(set) var debugMatte: FloatMap?

    // ---
    

    public init() {}

    public func render(image: PlanarImage, disparity: FloatMap,
                       lens: LensParameters, quality: RenderQuality = .photo,
                       temporal: TemporalState? = nil) -> PlanarImage {
        precondition(image.width == disparity.width && image.height == disparity.height,
                     "视差图需要先缩放到和图像相同的尺寸（见 DepthRefiner.refine）")
        let start = DispatchTime.now()
        defer {
            lastRenderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        }

        let w = image.width, h = image.height, n = w * h
        let L = image.longSide
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let t = DispatchTime.now().uptimeNanoseconds
            renderTimings.append((name, Double(t - mark) / 1e6))
            mark = t
        }
        renderTimings.removeAll(keepingCapacity: true)

        // ---- 1. 每个像素带符号的模糊半径 ----
        var s = [Float](repeating: 0, count: n)
        s.withUnsafeMutableBufferPointer { sp in
            disparity.values.withUnsafeBufferPointer { dp in
                let S = sp.baseAddress!, D = dp.baseAddress!
                parallelFor(h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let d = D[i]
                        S[i] = d.isFinite ? lens.signedBlurRadius(disparity: d, imageLongSide: L) : 0
                    }
                }
            }
        }
        var sMin: Float = 0, sMax: Float = 0
        for v in s { sMin = min(sMin, v); sMax = max(sMax, v) }

        // ---- 2. 深度分层：靠近对焦面的层更密（小半径之间的差别肉眼更敏感）----
        let centers = Self.layerCenters(sMin: sMin, sMax: sMax, perSide: quality.layersPerSide)
        let zeroIndex = centers.firstIndex(of: 0)!
        lastLayerCount = centers.count

        // 每个像素落在哪两层之间：lo 层权重 (1 - t)，lo+1 层权重 t
        var lo = [Int32](repeating: 0, count: n)
        var tt = [Float](repeating: 0, count: n)
        let layerCount = centers.count
        var minX = [Int](repeating: w, count: layerCount), maxX = [Int](repeating: -1, count: layerCount)
        var minY = [Int](repeating: h, count: layerCount), maxY = [Int](repeating: -1, count: layerCount)
        // 按行并行：每行记下各层出现的最左 / 最右列，最后再汇总成每层的包围盒
        var rowMinX = [Int32](repeating: Int32(w), count: h * layerCount)
        var rowMaxX = [Int32](repeating: -1, count: h * layerCount)
        s.withUnsafeBufferPointer { sp in
        lo.withUnsafeMutableBufferPointer { lp in
        tt.withUnsafeMutableBufferPointer { tp in
        rowMinX.withUnsafeMutableBufferPointer { mnp in
        rowMaxX.withUnsafeMutableBufferPointer { mxp in
        centers.withUnsafeBufferPointer { cp in
            let S = sp.baseAddress!, LO = lp.baseAddress!, TT = tp.baseAddress!
            let MN = mnp.baseAddress!, MX = mxp.baseAddress!, C = cp.baseAddress!
            parallelFor(h) { y in
                let rb = y * layerCount
                for x in 0..<w {
                    let i = y * w + x
                    let v = S[i]
                    var j = 0
                    var t: Float = 0
                    if v <= C[0] {
                        j = 0
                    } else if v >= C[layerCount - 1] {
                        j = layerCount - 1
                    } else {
                        while j + 1 < layerCount && C[j + 1] <= v { j += 1 }
                        if j + 1 < layerCount {
                            t = (v - C[j]) / (C[j + 1] - C[j])
                        }
                    }
                    LO[i] = Int32(j)
                    TT[i] = t
                    let xi = Int32(x)
                    if t < 1 {
                        if xi < MN[rb + j] { MN[rb + j] = xi }
                        if xi > MX[rb + j] { MX[rb + j] = xi }
                    }
                    if t > 0 {
                        if xi < MN[rb + j + 1] { MN[rb + j + 1] = xi }
                        if xi > MX[rb + j + 1] { MX[rb + j + 1] = xi }
                    }
                }
            }
        }}}}}}
        for y in 0..<h {
            for j in 0..<layerCount where rowMaxX[y * layerCount + j] >= 0 {
                minX[j] = min(minX[j], Int(rowMinX[y * layerCount + j]))
                maxX[j] = max(maxX[j], Int(rowMaxX[y * layerCount + j]))
                minY[j] = min(minY[j], y); maxY[j] = max(maxY[j], y)
            }
        }

        lap("分层")
        // ---- 3. 高光提亮 ----
        // 照片里的灯珠、反光点在传感器上早就过曝了，真实亮度可能是它的几十倍。
        // 不提亮的话，模糊后它们会被平均成灰蒙蒙的一片，而不是明亮的光斑。
        // 只提亮「比周围亮得多」的地方：大块的白墙、白纸不算高光（否则整张图焦外发白）。
        var br = image.r, bg = image.g, bb = image.b
        let thr = quality.highlightThreshold, gain = quality.highlightGain
        if gain > 0 {
            var maxC = [Float](repeating: 0, count: n)
            var brightMask = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let m = max(br[i], max(bg[i], bb[i]))
                maxC[i] = m
                brightMask[i] = m > thr ? 1 : 0
            }
            // 窗口要比常见灯具的尺寸大（长边的 1/25），否则一盏椭圆形筒灯中间会被当成「大面积」
            let windowR = max(3, L / 25)
            // 局部平均亮度：真正的光源比周围亮得多
            var localMean = BoxFilter.mean(maxC, width: w, height: h, radius: windowR)
            var brightFraction = [Float](repeating: 0, count: n)
            if !quality.smoothHighlights {
                // 旧算法：再加「亮像素占比」和按深度分组的统计。门限是硬的，灯管这类亮度在门限附近的光源
                // 会随噪声、曝光一段一段地亮暗跳变（实测预览里灯管一节一节地闪）
                brightFraction = BoxFilter.mean(brightMask, width: w, height: h, radius: windowR)
                let groups = min(7, layerCount)
                if groups > 1 {
                    var bin = [UInt8](repeating: 0, count: n)
                    var hasCandidate = [Bool](repeating: false, count: groups)
                    let scale = Float(groups - 1) / Float(max(1, layerCount - 1))
                    for i in 0..<n {
                        let b = min(groups - 1, max(0, Int(((Float(lo[i]) + tt[i]) * scale).rounded())))
                        bin[i] = UInt8(b)
                        if maxC[i] > thr { hasCandidate[b] = true }
                    }
                    for b in 0..<groups where hasCandidate[b] {
                        var mask = [Float](repeating: 0, count: n)
                        var mb = [Float](repeating: 0, count: n)
                        var mx = [Float](repeating: 0, count: n)
                        for i in 0..<n where Int(bin[i]) == b { mask[i] = 1; mb[i] = brightMask[i]; mx[i] = maxC[i] }
                        let cnt = BoxFilter.mean(mask, width: w, height: h, radius: windowR)
                        let fb = BoxFilter.mean(mb, width: w, height: h, radius: windowR)
                        let fm = BoxFilter.mean(mx, width: w, height: h, radius: windowR)
                        for i in 0..<n where Int(bin[i]) == b && maxC[i] > thr && cnt[i] > 0.25 {
                            let inv = 1 / cnt[i]
                            brightFraction[i] = max(brightFraction[i], fb[i] * inv)
                            localMean[i] = max(localMean[i], fm[i] * inv)
                        }
                    }
                }
            }
            let smooth = quality.smoothHighlights
            var boost = [Float](repeating: 1, count: n)
            boost.withUnsafeMutableBufferPointer { op in
            s.withUnsafeBufferPointer { sp in
                let O = op.baseAddress!, S = sp.baseAddress!
                parallelFor(h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let m = maxC[i]
                        if m <= thr { continue }
                        // 只对要被虚化的像素提亮，清晰区域保持原样
                        let blurAmount = min(1, abs(S[i]) / 2)
                        if smooth {
                            // 新算法：提亮量随亮度、对比度平滑变化（过渡带宽 0.4，旧的只有 0.1），
                            // 亮度有 1% 的波动，提亮量只变 2–3%，而不是 20%
                            let k = Self.smoothstep(thr, 1, m)
                            let contrast = Self.smoothstep(0.1, 0.4, m - localMean[i])
                            O[i] = 1 + gain * k * k * contrast * blurAmount
                        } else {
                            let k = Self.smoothstep(thr, 1, m)
                            let small = 1 - Self.smoothstep(0.15, 0.5, brightFraction[i])
                            let contrast = Self.smoothstep(0.1, 0.3, m - localMean[i])
                            O[i] = 1 + gain * k * small * contrast * blurAmount
                        }
                    }
                }
            }}
            // 实时预览：提亮系数向上一帧靠拢，光斑不闪
            temporal?.stabilizeBoost(&boost)
            for i in 0..<n where boost[i] != 1 {
                br[i] *= boost[i]; bg[i] *= boost[i]; bb[i] *= boost[i]
            }
        }

        lap("高光")
        // ---- 4/5. 逐层模糊并合成 ----
        prefixBuf.ensure(4 * h * (w + 1))
        planeBuf.ensure(4 * n)
        lowBuf.ensure(4 * n)
        // 背景累加器（over 合成）和前景累加器（加法合成）
        var accR = [Float](repeating: 0, count: n)
        var accG = [Float](repeating: 0, count: n)
        var accB = [Float](repeating: 0, count: n)
        var accA = [Float](repeating: 0, count: n)

        func runLayers(_ layers: [Int], additive: Bool) {
            br.withUnsafeBufferPointer { rp in
            bg.withUnsafeBufferPointer { gp in
            bb.withUnsafeBufferPointer { bp in
            lo.withUnsafeBufferPointer { lp in
            tt.withUnsafeBufferPointer { tp in
            accR.withUnsafeMutableBufferPointer { ar in
            accG.withUnsafeMutableBufferPointer { ag in
            accB.withUnsafeMutableBufferPointer { ab in
            accA.withUnsafeMutableBufferPointer { aa in
                let acc = Accumulator(R: ar.baseAddress!, G: ag.baseAddress!, B: ab.baseAddress!,
                                      A: aa.baseAddress!, additive: additive)
                for k in layers where maxX[k] >= 0 {
                    let src = LayerSource(R: rp.baseAddress!, G: gp.baseAddress!, B: bp.baseAddress!,
                                          lo: lp.baseAddress!, t: tp.baseAddress!, layer: Int32(k))
                    Self.renderLayer(src: src, radius: abs(centers[k]), width: w, height: h,
                                     bbox: (minX[k], maxX[k], minY[k], maxY[k]),
                                     prefix: prefixBuf.pointer, planes: planeBuf.pointer,
                                     lowOut: lowBuf.pointer, acc: acc)
                }
            }}}}}}}}}
        }

        // ---- 背景层 + 对焦层：从远到近 over 合成 ----
        // 用 over 是为了让清晰的主体完全挡住后面虚化背景「溢出」的部分，主体边缘才不会有光晕
        runLayers(Array(0...zeroIndex), additive: false)

        // 归一化 + 补洞。
        // 一个像素被拆到相邻两层（权重 1-t 和 t）时，over 合成后的覆盖率是 1 - t(1-t) < 1，
        // 所以要除以覆盖率恢复原色；覆盖率很低的地方（被前景挡住的空洞）用 pull-push 外推的背景填。
        lap("背景层")
        let filled = PullPush.fill(premultiplied: [accR, accG, accB], weight: accA, width: w, height: h)
        lap("补洞")
        var outR = filled[0], outG = filled[1], outB = filled[2]
        func compose(_ body: (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>,
                              UnsafePointer<Float>, UnsafePointer<Float>, UnsafePointer<Float>, UnsafePointer<Float>) -> Void) {
            outR.withUnsafeMutableBufferPointer { orp in
            outG.withUnsafeMutableBufferPointer { ogp in
            outB.withUnsafeMutableBufferPointer { obp in
            accR.withUnsafeBufferPointer { arp in
            accG.withUnsafeBufferPointer { agp in
            accB.withUnsafeBufferPointer { abp in
            accA.withUnsafeBufferPointer { aap in
                let OR = orp.baseAddress!, OG = ogp.baseAddress!, OB = obp.baseAddress!
                let AR = arp.baseAddress!, AG = agp.baseAddress!, AB = abp.baseAddress!, AA = aap.baseAddress!
                parallelFor(h) { y in
                    for i in (y * w)..<(y * w + w) { body(i, OR, OG, OB, AR, AG, AB, AA) }
                }
            }}}}}}}
        }
        compose { i, OR, OG, OB, AR, AG, AB, AA in
            let a = AA[i]
            if a > 0.3 {
                let s = Self.smoothstep(0.3, 0.7, a), inv = 1 / a
                OR[i] = AR[i] * inv * s + OR[i] * (1 - s)
                OG[i] = AG[i] * inv * s + OG[i] * (1 - s)
                OB[i] = AB[i] * inv * s + OB[i] * (1 - s)
            }
        }

        // ---- 前景层：加法累积，再整体盖到背景上 ----
        // 同一个表面被拆到两层时权重相加正好是 1，不会变透明；点光源的能量也守恒
        if zeroIndex + 1 < layerCount {
            accR = [Float](repeating: 0, count: n); accG = [Float](repeating: 0, count: n)
            accB = [Float](repeating: 0, count: n); accA = [Float](repeating: 0, count: n)
            runLayers(Array((zeroIndex + 1)..<layerCount), additive: true)
            compose { i, OR, OG, OB, AR, AG, AB, AA in
                let a = AA[i]
                if a <= 1e-5 { return }
                // 覆盖率超过 1（不同前景物体的虚化互相重叠）时按权重平均颜色
                let coverage = min(a, 1), scale = coverage / a
                let k = 1 - coverage
                OR[i] = OR[i] * k + AR[i] * scale
                OG[i] = OG[i] * k + AG[i] * scale
                OB[i] = OB[i] * k + AB[i] * scale
            }
        }

        lap("前景")
        return PlanarImage(width: w, height: h, r: outR, g: outG, b: outB)
    }

    /// render 内部各步骤耗时（毫秒）
    public var renderTimings: [(String, Double)] = []

    // 复用的工作缓冲区
    private let prefixBuf = FloatBuffer()
    private let planeBuf = FloatBuffer()
    private let lowBuf = FloatBuffer()

    // MARK: - 分层

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func layerCenters(sMin: Float, sMax: Float, perSide K: Int) -> [Float] {
        let minSpacing: Float = 0.35
        var neg: [Float] = []
        for k in stride(from: K, through: 1, by: -1) {
            let f = Float(k) / Float(K)
            let c = sMin * f * f
            if c < -minSpacing, neg.last.map({ c - $0 >= minSpacing }) ?? true { neg.append(c) }
        }
        var pos: [Float] = []
        for k in 1...max(1, K) {
            let f = Float(k) / Float(K)
            let c = sMax * f * f
            if c > minSpacing, (pos.last ?? 0) + minSpacing <= c { pos.append(c) }
        }
        return neg + [0] + pos
    }

    // MARK: - 单层：（降采样）-> 圆盘模糊 ->（上采样）-> 合成

    struct LayerSource {
        let R: UnsafePointer<Float>, G: UnsafePointer<Float>, B: UnsafePointer<Float>
        let lo: UnsafePointer<Int32>, t: UnsafePointer<Float>
        let layer: Int32

        /// 像素 i 属于这一层的权重
        @inline(__always) func weight(_ i: Int) -> Float {
            let l = lo[i]
            if l == layer { return 1 - t[i] }
            if l + 1 == layer { return t[i] }
            return 0
        }
    }

    struct Accumulator {
        let R: UnsafeMutablePointer<Float>, G: UnsafeMutablePointer<Float>
        let B: UnsafeMutablePointer<Float>, A: UnsafeMutablePointer<Float>
        /// true：加法累积；false：over 合成
        let additive: Bool

        /// 预乘 alpha 的 over 合成（新层盖在已有内容上），或加法累积
        @inline(__always) func over(_ i: Int, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            if additive {
                R[i] += r; G[i] += g; B[i] += b; A[i] += a
                return
            }
            let k = 1 - a
            R[i] = R[i] * k + r
            G[i] = G[i] * k + g
            B[i] = B[i] * k + b
            A[i] = A[i] * k + a
        }
    }

    /// 大半径的层先降采样再模糊：半径 r 的圆盘在 1/q 分辨率下半径只有 r/q，
    /// 计算量降到约 1/q³。只在 r/q ≥ 8 时降，保证光斑边缘仍然够锐。
    static func downsampleFactor(forRadius r: Float) -> Int {
        var q = 1
        while q < 8 && r / Float(q * 2) >= 8 { q *= 2 }
        return q
    }

    static func renderLayer(src: LayerSource, radius r: Float, width w: Int, height h: Int,
                            bbox: (Int, Int, Int, Int), prefix: UnsafeMutablePointer<Float>,
                            planes: UnsafeMutablePointer<Float>, lowOut: UnsafeMutablePointer<Float>,
                            acc: Accumulator) {
        let (bx0, bx1, by0, by1) = bbox

        // 半径小于半个像素：不需要模糊，直接按权重合成
        if r < 0.5 {
            parallelFor(by1 - by0 + 1) { yi in
                let y = by0 + yi
                for x in bx0...bx1 {
                    let i = y * w + x
                    let a = src.weight(i)
                    if a > 0 { acc.over(i, src.R[i] * a, src.G[i] * a, src.B[i] * a, a) }
                }
            }
            return
        }

        let q = downsampleFactor(forRadius: r)
        let lw = (w + q - 1) / q, lh = (h + q - 1) / q, ln = lw * lh
        let PR = planes, PG = planes + ln, PB = planes + 2 * ln, PA = planes + 3 * ln
        let lx0 = bx0 / q, lx1 = bx1 / q, ly0 = by0 / q, ly1 = by1 / q

        // 这一层的预乘颜色（q > 1 时同时做 q×q 盒式降采样）
        parallelFor(ly1 - ly0 + 1) { yi in
            let ly = ly0 + yi
            for lx in lx0...lx1 {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0, sa: Float = 0, cnt: Float = 0
                for y in (ly * q)..<min(h, ly * q + q) {
                    for x in (lx * q)..<min(w, lx * q + q) {
                        let i = y * w + x
                        let a = src.weight(i)
                        sr += src.R[i] * a; sg += src.G[i] * a; sb += src.B[i] * a; sa += a
                        cnt += 1
                    }
                }
                let inv = 1 / cnt, j = ly * lw + lx
                PR[j] = sr * inv; PG[j] = sg * inv; PB[j] = sb * inv; PA[j] = sa * inv
            }
        }

        if q == 1 {
            diskBlur(R: PR, G: PG, B: PB, A: PA, width: w, height: h, bbox: (lx0, lx1, ly0, ly1),
                     radius: r, prefix: prefix) { x, y, cr, cg, cb, a in
                acc.over(y * w + x, cr, cg, cb, a)
            }
            return
        }

        // 低分辨率模糊
        let OR = lowOut, OG = lowOut + ln, OB = lowOut + 2 * ln, OA = lowOut + 3 * ln
        lowOut.update(repeating: 0, count: 4 * ln)
        let region = diskBlur(R: PR, G: PG, B: PB, A: PA, width: lw, height: lh, bbox: (lx0, lx1, ly0, ly1),
                              radius: r / Float(q), prefix: prefix) { x, y, cr, cg, cb, a in
            let j = y * lw + x
            OR[j] = cr; OG[j] = cg; OB[j] = cb; OA[j] = a
        }

        // 双线性上采样回原分辨率并合成
        let fx0 = max(0, (region.0 - 1) * q), fx1 = min(w - 1, (region.1 + 2) * q - 1)
        let fy0 = max(0, (region.2 - 1) * q), fy1 = min(h - 1, (region.3 + 2) * q - 1)
        let invQ = 1 / Float(q)
        let maxLX = Float(lw - 1), maxLY = Float(lh - 1)
        parallelFor(fy1 - fy0 + 1) { yi in
            let y = fy0 + yi
            let sy = min(max((Float(y) + 0.5) * invQ - 0.5, 0), maxLY)
            let y0 = Int(sy), y1 = min(y0 + 1, lh - 1), ty = sy - Float(y0)
            let r0 = y0 * lw, r1 = y1 * lw
            for x in fx0...fx1 {
                let sx = min(max((Float(x) + 0.5) * invQ - 0.5, 0), maxLX)
                let x0 = Int(sx), x1 = min(x0 + 1, lw - 1), tx = sx - Float(x0)
                @inline(__always) func bil(_ P: UnsafeMutablePointer<Float>) -> Float {
                    let a = P[r0 + x0] + (P[r0 + x1] - P[r0 + x0]) * tx
                    let b = P[r1 + x0] + (P[r1 + x1] - P[r1 + x0]) * tx
                    return a + (b - a) * ty
                }
                let a = bil(OA)
                if a <= 1e-5 { continue }
                acc.over(y * w + x, bil(OR), bil(OG), bil(OB), min(a, 1))
            }
        }
    }

    /// 圆盘模糊（逐行前缀和，每像素 O(r)）。
    /// 输入是预乘的 4 个平面，只有 bbox 内有数据；对输出区域内每个像素回调 emit（已归一化）。
    /// - Returns: 输出区域 (x0, x1, y0, y1)
    @discardableResult
    static func diskBlur(R: UnsafePointer<Float>, G: UnsafePointer<Float>, B: UnsafePointer<Float>,
                         A: UnsafePointer<Float>, width w: Int, height h: Int,
                         bbox: (Int, Int, Int, Int), radius r: Float, prefix P: UnsafeMutablePointer<Float>,
                         emit: (Int, Int, Float, Float, Float, Float) -> Void) -> (Int, Int, Int, Int) {
        let (bx0, bx1, by0, by1) = bbox

        // 逐行前缀和：P[x] = 本行 [bx0, x) 区间的累加值（只在 bbox 内计算，外面全是 0）
        let rowStride = w + 1
        let planeStride = h * rowStride
        let PR = P, PG = P + planeStride, PB = P + 2 * planeStride, PA = P + 3 * planeStride
        parallelFor(by1 - by0 + 1) { yi in
            let y = by0 + yi
            let base = y * rowStride
            var sr: Float = 0, sg: Float = 0, sb: Float = 0, sa: Float = 0
            PR[base + bx0] = 0; PG[base + bx0] = 0; PB[base + bx0] = 0; PA[base + bx0] = 0
            for x in bx0...bx1 {
                let i = y * w + x
                sr += R[i]; sg += G[i]; sb += B[i]; sa += A[i]
                PR[base + x + 1] = sr; PG[base + x + 1] = sg; PB[base + x + 1] = sb; PA[base + x + 1] = sa
            }
        }

        // 圆盘每一行的半宽：hw(dy) = sqrt(r² - dy²)，带小数，实现抗锯齿的圆形边缘
        let Ri = Int(r)
        let halfWidths: [Float] = (-Ri...Ri).map { dy in (max(0, r * r - Float(dy * dy))).squareRoot() }

        // 输出区域 = bbox 向外扩 R+1
        let ox0 = max(0, bx0 - Ri - 1), ox1 = min(w - 1, bx1 + Ri + 1)
        let oy0 = max(0, by0 - Ri - 1), oy1 = min(h - 1, by1 + Ri + 1)
        let ow = ox1 - ox0 + 1
        let lowClamp = Float(bx0), highClamp = Float(bx1 + 1)
        let fw = Float(w)

        // 稀疏优化：按 32×32 分块，只计算「有数据的块」周围 R+1 范围内的输出。
        // 平滑过的深度图在物体边缘会产生很多中间值，几乎每一层都会在边缘处分到一点像素，
        // 包围盒很大但里面大部分是空的。
        let runs = activeRuns(A: A, width: w, height: h, bbox: bbox, reach: Ri + 1,
                              clipX: (ox0, ox1))

        halfWidths.withUnsafeBufferPointer { hwp in
            let HW = hwp.baseAddress!
            parallelChunks(oy1 - oy0 + 1) { rows in
                // 线程私有累加器
                let sums = UnsafeMutablePointer<Float>.allocate(capacity: ow * 5)
                defer { sums.deallocate() }
                let SR = sums, SG = sums + ow, SB = sums + 2 * ow, SA = sums + 3 * ow, SN = sums + 4 * ow
                for yi in rows {
                    let y = oy0 + yi
                    let rowRuns = runs[y / tileSize]
                    if rowRuns.isEmpty { continue }
                    sums.update(repeating: 0, count: ow * 5)
                    for dy in -Ri...Ri {
                        let yy = y + dy
                        if yy < 0 || yy >= h { continue }
                        let hw = HW[dy + Ri]
                        let hasData = yy >= by0 && yy <= by1
                        let base = yy * rowStride
                        for run in rowRuns {
                            for xi in (run.0 - ox0)...(run.1 - ox0) {
                                let x = Float(ox0 + xi)
                                // 圆盘这一行覆盖的连续区间 [a, b)
                                let a = x - hw, b = x + 1 + hw
                                // 图像范围内的核权重（用于图像边缘的归一化）
                                SN[xi] += min(b, fw) - max(a, 0)
                                if hasData {
                                    let ca = min(max(a, lowClamp), highClamp)
                                    let cb = min(max(b, lowClamp), highClamp)
                                    if cb > ca {
                                        // 小数位置的前缀和用线性插值
                                        let ia = Int(ca), ib = Int(cb)
                                        let fa = ca - Float(ia), fb = cb - Float(ib)
                                        let ja = min(ia + 1, bx1 + 1), jb = min(ib + 1, bx1 + 1)
                                        let pa = base + ia, pb = base + ib
                                        let qa = base + ja, qb = base + jb
                                        SR[xi] += (PR[pb] + (PR[qb] - PR[pb]) * fb) - (PR[pa] + (PR[qa] - PR[pa]) * fa)
                                        SG[xi] += (PG[pb] + (PG[qb] - PG[pb]) * fb) - (PG[pa] + (PG[qa] - PG[pa]) * fa)
                                        SB[xi] += (PB[pb] + (PB[qb] - PB[pb]) * fb) - (PB[pa] + (PB[qa] - PB[pa]) * fa)
                                        SA[xi] += (PA[pb] + (PA[qb] - PA[pb]) * fb) - (PA[pa] + (PA[qa] - PA[pa]) * fa)
                                    }
                                }
                            }
                        }
                    }
                    // 归一化后交给调用方
                    for run in rowRuns {
                        for xi in (run.0 - ox0)...(run.1 - ox0) {
                            let norm = SN[xi]
                            if norm <= 0 { continue }
                            let inv = 1 / norm
                            let a = SA[xi] * inv
                            if a <= 1e-5 { continue }
                            emit(ox0 + xi, y, SR[xi] * inv, SG[xi] * inv, SB[xi] * inv, min(a, 1))
                        }
                    }
                }
            }
        }
        return (ox0, ox1, oy0, oy1)
    }
    static let tileSize = 32

    /// 找出每一行「需要计算」的 x 区间：有数据的分块向外膨胀 reach 像素后覆盖的范围
    static func activeRuns(A: UnsafePointer<Float>, width w: Int, height h: Int,
                           bbox: (Int, Int, Int, Int), reach: Int, clipX: (Int, Int)) -> [[(Int, Int)]] {
        let T = tileSize
        let tx = (w + T - 1) / T, ty = (h + T - 1) / T
        let (bx0, bx1, by0, by1) = bbox
        var src = [UInt8](repeating: 0, count: tx * ty)
        src.withUnsafeMutableBufferPointer { sp in
            let S = sp.baseAddress!
            let t0 = by0 / T, t1 = by1 / T
            parallelFor(t1 - t0 + 1) { k in
                let tyi = t0 + k
                for y in max(by0, tyi * T)...min(by1, tyi * T + T - 1) {
                    for x in bx0...bx1 where A[y * w + x] > 0 {
                        S[tyi * tx + x / T] = 1
                    }
                }
            }
        }
        // 膨胀
        let D = (reach + T - 1) / T
        var dil = [UInt8](repeating: 0, count: tx * ty)
        for j in 0..<ty {
            for i in 0..<tx where src[j * tx + i] != 0 {
                for jj in max(0, j - D)...min(ty - 1, j + D) {
                    for ii in max(0, i - D)...min(tx - 1, i + D) { dil[jj * tx + ii] = 1 }
                }
            }
        }
        // 每个分块行合并成连续区间
        var runs = [[(Int, Int)]](repeating: [], count: ty)
        for j in 0..<ty {
            var i = 0
            while i < tx {
                if dil[j * tx + i] == 0 { i += 1; continue }
                var e = i
                while e + 1 < tx && dil[j * tx + e + 1] != 0 { e += 1 }
                let x0 = max(clipX.0, i * T), x1 = min(clipX.1, min(w, (e + 1) * T) - 1)
                if x0 <= x1 { runs[j].append((x0, x1)) }
                i = e + 1
            }
        }
        return runs
    }
}

/// 手动管理的浮点缓冲区（避免每帧重新分配大数组）
final class FloatBuffer {
    private(set) var pointer: UnsafeMutablePointer<Float>
    private(set) var capacity: Int

    init() {
        capacity = 1
        pointer = .allocate(capacity: 1)
    }

    func ensure(_ n: Int) {
        if n > capacity {
            pointer.deallocate()
            pointer = .allocate(capacity: n)
            capacity = n
        }
    }

    deinit { pointer.deallocate() }
}
