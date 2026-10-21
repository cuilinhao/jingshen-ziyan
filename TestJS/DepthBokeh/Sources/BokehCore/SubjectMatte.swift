import Foundation

/// 主体遮罩：让「对焦的那个东西」整个保持清晰，边缘贴着它在画面里的真实轮廓。
///
/// 问题：实时深度只有 320×240，物体边缘和彩色画面对不齐（近处更明显）。拍拳头时，
/// 拳头上沿有一圈像素的深度其实是背景的深度，于是这一圈被当成背景虚化掉，
/// 看起来拳头「缺了一块」、半透明。
///
/// 做法（全部在低分辨率上）：
///  1. 深度在对焦面 ±band（相对距离）以内、并且和对焦点连通的区域，作为主体的「核心」
///  2. 用彩色画面做引导滤波，把核心的边界吸附到颜色边缘上 —— 深度缺掉的那一圈，
///     只要颜色和主体一样、和背景不一样，就会被补回来；深度多出来的一圈（主体深度渗到背景上）
///     会被削掉
///  3. 输出 0...1 的遮罩 α：α 越大，越把这个像素的视差拉向对焦面（完全清晰）；
///     核心之外、颜色却被判成「不是主体」的像素，视差推向附近背景，避免主体外面留一圈清晰的光晕
public struct SubjectMatteParameters: Equatable {
    /// 视为主体的深度范围（相对对焦距离，0.25 = ±25%）
    public var band: Float = 0.25
    /// 引导滤波半径（占长边比例）。决定能修正多宽的边缘错位
    public var radiusFraction: Float = 1.0 / 70
    /// 引导滤波正则项（越小越贴颜色边缘）
    public var epsilon: Float = 4e-4
    /// 只要和对焦点连通的部分（排除画面别处碰巧同样远的东西）
    public var connectToFocus = true
    /// 在对焦点附近找连通种子的范围（占长边比例）
    public var seedSearch: Float = 0.08
    /// 按颜色把主体边缘补回来的最大宽度（占长边比例，0 = 关闭）。双摄视差（尤其 4× 长焦）分辨率低、边缘糊，
    /// 主体的深度边界会往里缩一圈：盒子顶面、侧边这一圈拿到的是背景的深度，被虚化成一层「蒙层」。
    /// 这一圈里的像素，颜色更像旁边的主体、不像更外面的背景时，算回主体
    /// LiDAR 的深度边缘本身就准，LivePreviewPipeline 只在相对深度（双摄 / AI）时打开
    public var colorGrowth: Float = 1.0 / 24

    public init() {}
}

public enum SubjectMatte {

    /// 计算主体遮罩并修正视差。
    /// - Parameters:
    ///   - disparity: 低分辨率、已经细化过的视差
    ///   - image: 同尺寸的彩色图（线性光）
    ///   - focusDisparity: 对焦视差
    ///   - focusPoint: 对焦点（归一化坐标），用于连通性
    ///   - scale: 相对距离的分母（见 LensParameters.relativeScale），nil = 对焦视差
    ///   - personMask: 人像分割（任意分辨率，和视差图同一画面）。对焦点在人身上时，和对焦点连着的那个人整体清晰
    /// - Returns: (修正后的视差, 遮罩 α)
    public static func apply(disparity: FloatMap, image: PlanarImage, focusDisparity df: Float,
                             focusPoint: (Float, Float)?, parameters p: SubjectMatteParameters,
                             scale: Float? = nil, personMask: FloatMap? = nil) -> (FloatMap, FloatMap) {
        let w = disparity.width, h = disparity.height, n = w * h
        precondition(image.width == w && image.height == h)
        guard df > 0 else { return (disparity, FloatMap(width: w, height: h)) }
        let d = disparity.values
        let norm = max(scale ?? df, 1e-3)

        // 1. 核心：对焦面附近的深度
        var core = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let rel = (d[i] - df) / norm
            if abs(rel) < p.band { core[i] = 1 }
        }
        if p.connectToFocus, let fp = focusPoint {
            core = keepConnected(core, width: w, height: h, near: fp, searchFraction: p.seedSearch)
        }
        let depthCore = core
        // 深度边界往里缩的那一圈：按颜色补回主体
        if p.colorGrowth > 0 {
            let grown = growByColor(core: core, disparity: d, focusDisparity: df, norm: norm, band: p.band,
                                    image: image, width: w, height: h, fraction: p.colorGrowth)
            for i in 0..<n where grown[i] > 0.5 { core[i] = 1 }
        }
        // 对焦在人身上：和对焦点连着的那个人整个算主体（人像分割比深度更懂「哪些是这个人」：眼镜、头发边缘）
        let person = personMask.flatMap { personRegion($0, width: w, height: h, focusPoint: focusPoint) }
        if let person {
            for i in 0..<n where person[i] > 0.5 { core[i] = 1 }
        }

        // 2. 彩色引导滤波（三个通道分别做引导，取平均，比只用亮度更能区分肤色和粉色屏幕这类亮度接近的颜色）
        let r = max(2, Int(Float(max(w, h)) * p.radiusFraction))
        var alpha = colorGuidedAverage(image: image, input: core, width: w, height: h, radius: r, epsilon: p.epsilon)
        // 收紧过渡带，边缘更利落
        for i in 0..<n { alpha[i] = smoothstep(0.25, 0.75, alpha[i]) }
        if let person {
            for i in 0..<n { alpha[i] = max(alpha[i], smoothstep(0.3, 0.7, person[i])) }
        }

        // 3. 修正视差
        //    α 高：拉到对焦面（主体整体清晰，包括深度缺掉的边）
        //    核心内但 α 低（颜色说不是主体，是深度渗出来的）：换成附近较远的视差，按背景虚化
        let farNearby = minFilter(d, width: w, height: h, radius: r)
        var out = d
        for i in 0..<n {
            let a = alpha[i]
            var v = d[i] + a * (df - d[i])
            let leak = max(0, depthCore[i] - a)
            if leak > 0 && farNearby[i] < df - p.band * norm {
                v += leak * (farNearby[i] - v)
            }
            out[i] = v
        }
        return (FloatMap(width: w, height: h, values: out), FloatMap(width: w, height: h, values: alpha))
    }

    /// 三个颜色通道分别做引导滤波（引导图是 sqrt(线性光)，近似感知亮度），结果取平均。
    /// 和逐通道调用 DepthRefiner.guidedFilter 结果相同，只是共用输入的均值、逐行并行
    static func colorGuidedAverage(image: PlanarImage, input p: [Float], width w: Int, height h: Int,
                                   radius r: Int, epsilon eps: Float) -> [Float] {
        let n = w * h
        let meanP = BoxFilter.mean(p, width: w, height: h, radius: r)
        var alpha = [Float](repeating: 0, count: n)
        var I = [Float](repeating: 0, count: n), Ip = I, II = I
        for ch in 0..<3 {
            let src = ch == 0 ? image.r : (ch == 1 ? image.g : image.b)
            src.withUnsafeBufferPointer { sp in
            p.withUnsafeBufferPointer { pp in
            I.withUnsafeMutableBufferPointer { ip in
            Ip.withUnsafeMutableBufferPointer { ipp in
            II.withUnsafeMutableBufferPointer { iip in
                let S = sp.baseAddress!, P = pp.baseAddress!, G = ip.baseAddress!, GP = ipp.baseAddress!, GG = iip.baseAddress!
                parallelFor(h) { y in
                    for i in (y * w)..<(y * w + w) {
                        let g = sqrtf(max(0, S[i]))
                        G[i] = g; GP[i] = g * P[i]; GG[i] = g * g
                    }
                }
            }}}}}
            let meanI = BoxFilter.mean(I, width: w, height: h, radius: r)
            let meanIp = BoxFilter.mean(Ip, width: w, height: h, radius: r)
            let meanII = BoxFilter.mean(II, width: w, height: h, radius: r)
            var a = [Float](repeating: 0, count: n), b = a
            a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                let A = ap.baseAddress!, B = bp.baseAddress!
                parallelFor(h) { y in
                    for i in (y * w)..<(y * w + w) {
                        let cov = meanIp[i] - meanI[i] * meanP[i]
                        let varI = meanII[i] - meanI[i] * meanI[i]
                        A[i] = cov / (varI + eps)
                        B[i] = meanP[i] - A[i] * meanI[i]
                    }
                }
            }}
            let meanA = BoxFilter.mean(a, width: w, height: h, radius: r)
            let meanB = BoxFilter.mean(b, width: w, height: h, radius: r)
            alpha.withUnsafeMutableBufferPointer { op in
            I.withUnsafeBufferPointer { ip in
                let O = op.baseAddress!, G = ip.baseAddress!
                parallelFor(h) { y in
                    for i in (y * w)..<(y * w + w) { O[i] += (meanA[i] * G[i] + meanB[i]) / 3 }
                }
            }}
        }
        return alpha
    }

    /// 主体边缘按颜色补回：在 1/2 分辨率上，对主体（core）外面 D 以内、不比对焦面更近的像素，
    /// 分别找附近颜色最接近的「主体像素」和「D 以外的背景像素」，明显更像主体的算回主体。
    /// 背景样本只取 D 以外的，因为 D 以内的深度本身就不可信（正是要修的那一圈）
    static func growByColor(core: [Float], disparity d: [Float], focusDisparity df: Float, norm: Float, band: Float,
                            image: PlanarImage, width w: Int, height h: Int, fraction: Float) -> [Float] {
        let hw = max(1, w / 2), hh = max(1, h / 2), hn = hw * hh
        var out = [Float](repeating: 0, count: w * h)
        guard hw >= 16, hh >= 12 else { return out }
        // 1/2 分辨率：主体、颜色（sqrt 线性光 ≈ 感知）、相对距离
        var c = [Float](repeating: 0, count: hn)
        var cr = [Float](repeating: 0, count: hn), cg = cr, cb = cr
        var rel = [Float](repeating: 0, count: hn)
        for y in 0..<hh {
            for x in 0..<hw {
                var sc: Float = 0, sr: Float = 0, sg: Float = 0, sb: Float = 0, sd: Float = 0, nd: Float = 0
                for yy in 0..<2 {
                    for xx in 0..<2 {
                        let i = min(h - 1, 2 * y + yy) * w + min(w - 1, 2 * x + xx)
                        sc += core[i]; sr += image.r[i]; sg += image.g[i]; sb += image.b[i]
                        if d[i].isFinite { sd += d[i]; nd += 1 }
                    }
                }
                let j = y * hw + x
                c[j] = sc >= 2 ? 1 : 0
                cr[j] = sqrtf(max(0, sr / 4)); cg[j] = sqrtf(max(0, sg / 4)); cb[j] = sqrtf(max(0, sb / 4))
                rel[j] = nd > 0 ? (sd / nd - df) / norm : -1
            }
        }
        let D = max(3, Int(Float(max(hw, hh)) * fraction))
        // 离主体 D 以内（方形窗口近似）
        let near = maxFilter(c, width: hw, height: hh, radius: D)
        guard c.contains(1) else { return out }
        // 每 4×4 一格，分别记主体像素和背景样本（D 以外）的平均颜色
        let cs = 4, gw = (hw + cs - 1) / cs, gh = (hh + cs - 1) / cs, gn = gw * gh
        var fC = [Float](repeating: 0, count: gn * 3), fN = [Float](repeating: 0, count: gn)
        var bC = [Float](repeating: 0, count: gn * 3), bN = [Float](repeating: 0, count: gn)
        for y in 0..<hh {
            for x in 0..<hw {
                let j = y * hw + x, g = (y / cs) * gw + x / cs
                if c[j] > 0 {
                    fC[3 * g] += cr[j]; fC[3 * g + 1] += cg[j]; fC[3 * g + 2] += cb[j]; fN[g] += 1
                } else if near[j] == 0 {
                    bC[3 * g] += cr[j]; bC[3 * g + 1] += cg[j]; bC[3 * g + 2] += cb[j]; bN[g] += 1
                }
            }
        }
        for g in 0..<gn {
            if fN[g] > 0 { let k = 1 / fN[g]; fC[3 * g] *= k; fC[3 * g + 1] *= k; fC[3 * g + 2] *= k }
            if bN[g] > 0 { let k = 1 / bN[g]; bC[3 * g] *= k; bC[3 * g + 1] *= k; bC[3 * g + 2] *= k }
        }
        let Rc = max(1, (2 * D + cs - 1) / cs)
        var grown = [Float](repeating: 0, count: hn)
        grown.withUnsafeMutableBufferPointer { gp in
            let G = gp.baseAddress!
            parallelFor(hh) { y in
                for x in 0..<hw {
                    let j = y * hw + x
                    guard near[j] > 0, c[j] == 0, rel[j] < band else { continue }
                    let pr = cr[j], pg = cg[j], pb = cb[j]
                    var dF = Float.infinity, dB = Float.infinity
                    let gx = x / cs, gy = y / cs
                    for yy in max(0, gy - Rc)...min(gh - 1, gy + Rc) {
                        for xx in max(0, gx - Rc)...min(gw - 1, gx + Rc) {
                            let g = yy * gw + xx
                            if fN[g] >= 2 {
                                let er = fC[3 * g] - pr, eg = fC[3 * g + 1] - pg, eb = fC[3 * g + 2] - pb
                                dF = min(dF, er * er + eg * eg + eb * eb)
                            }
                            if bN[g] >= 2 {
                                let er = bC[3 * g] - pr, eg = bC[3 * g + 1] - pg, eb = bC[3 * g + 2] - pb
                                dB = min(dB, er * er + eg * eg + eb * eb)
                            }
                        }
                    }
                    // 附近没有背景样本（主体占满）或没有主体样本：不判断。明显更像主体（距离不到背景的 1/4）才算回去
                    guard dF.isFinite, dB.isFinite else { continue }
                    if dF * 4 + 0.0004 < dB { G[j] = 1 }
                }
            }
        }
        // 只要和主体连着的（一块一块孤立长出来的多半是背景里碰巧同色的东西）
        var seedMask = grown
        for j in 0..<hn where c[j] > 0 { seedMask[j] = 1 }
        let connected = keepConnectedAll(seedMask, from: c, width: hw, height: hh)
        for y in 0..<h {
            for x in 0..<w {
                let j = min(hh - 1, y / 2) * hw + min(hw - 1, x / 2)
                if grown[j] > 0 && connected[j] > 0 { out[y * w + x] = 1 }
            }
        }
        return out
    }

    /// 从所有种子（seeds > 0 的像素）出发，在 mask > 0 的区域里 4 连通扩散
    static func keepConnectedAll(_ mask: [Float], from seeds: [Float], width w: Int, height h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        var stack: [Int] = []
        for i in 0..<(w * h) where seeds[i] > 0 && mask[i] > 0 { out[i] = 1; stack.append(i) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0, mask[i - 1] > 0, out[i - 1] == 0 { out[i - 1] = 1; stack.append(i - 1) }
            if x < w - 1, mask[i + 1] > 0, out[i + 1] == 0 { out[i + 1] = 1; stack.append(i + 1) }
            if y > 0, mask[i - w] > 0, out[i - w] == 0 { out[i - w] = 1; stack.append(i - w) }
            if y < h - 1, mask[i + w] > 0, out[i + w] == 0 { out[i + w] = 1; stack.append(i + w) }
        }
        return out
    }

    /// 方形窗口最大值（可分离）
    static func maxFilter(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        let neg = src.map { -$0 }
        return minFilter(neg, width: w, height: h, radius: r).map { -$0 }
    }

    /// 人像遮罩里和对焦点连着的那个人（缩放到 w×h）。对焦点不在人身上（附近没有遮罩值 > 0.5 的像素）返回 nil
    static func personRegion(_ mask: FloatMap, width w: Int, height h: Int, focusPoint: (Float, Float)?) -> [Float]? {
        guard let fp = focusPoint else { return nil }
        let m = mask.resized(width: w, height: h).values
        // 对焦点本身要在人身上（允许偏一点：点在眼镜、头发边上）
        let cx = min(w - 1, max(0, Int(fp.0 * Float(w)))), cy = min(h - 1, max(0, Int(fp.1 * Float(h))))
        let r = max(1, max(w, h) / 100)
        var onPerson = false
        for y in max(0, cy - r)...min(h - 1, cy + r) {
            for x in max(0, cx - r)...min(w - 1, cx + r) where m[y * w + x] > 0.5 { onPerson = true }
        }
        guard onPerson else { return nil }
        var binary = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where m[i] > 0.5 { binary[i] = 1 }
        let connected = keepConnected(binary, width: w, height: h, near: fp, searchFraction: 0.02)
        // 只保留这个人（连通区域附近）的软边遮罩
        let near = BoxFilter.mean(connected, width: w, height: h, radius: max(1, max(w, h) / 120))
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where near[i] > 0 { out[i] = m[i] }
        return out
    }

    /// 只保留和对焦点连通的核心区域（4 连通）。对焦点本身不在核心里时，在附近找最近的核心像素当种子；
    /// 找不到就不做连通限制
    static func keepConnected(_ core: [Float], width w: Int, height h: Int,
                              near fp: (Float, Float), searchFraction: Float) -> [Float] {
        let cx = min(w - 1, max(0, Int(fp.0 * Float(w)))), cy = min(h - 1, max(0, Int(fp.1 * Float(h))))
        let R = max(1, Int(Float(max(w, h)) * searchFraction))
        var seed = -1
        var best = Int.max
        for y in max(0, cy - R)...min(h - 1, cy + R) {
            for x in max(0, cx - R)...min(w - 1, cx + R) where core[y * w + x] > 0 {
                let dd = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if dd < best { best = dd; seed = y * w + x }
            }
        }
        guard seed >= 0 else { return core }
        var out = [Float](repeating: 0, count: w * h)
        var stack = [seed]
        out[seed] = 1
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0, core[i - 1] > 0, out[i - 1] == 0 { out[i - 1] = 1; stack.append(i - 1) }
            if x < w - 1, core[i + 1] > 0, out[i + 1] == 0 { out[i + 1] = 1; stack.append(i + 1) }
            if y > 0, core[i - w] > 0, out[i - w] == 0 { out[i - w] = 1; stack.append(i - w) }
            if y < h - 1, core[i + w] > 0, out[i + w] == 0 { out[i + w] = 1; stack.append(i + w) }
        }
        return out
    }

    /// 方形窗口最小值（可分离），用来找「附近最远的视差」
    static func minFilter(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { sp in
        tmp.withUnsafeMutableBufferPointer { tp in
            let S = sp.baseAddress!, T = tp.baseAddress!
            parallelFor(h) { y in
                let row = y * w
                for x in 0..<w {
                    var m = Float.infinity
                    for xx in max(0, x - r)...min(w - 1, x + r) { m = min(m, S[row + xx]) }
                    T[row + x] = m
                }
            }
        }}
        tmp.withUnsafeBufferPointer { tp in
        out.withUnsafeMutableBufferPointer { op in
            let T = tp.baseAddress!, O = op.baseAddress!
            // 按行处理（内层沿 x 连续访问内存）
            parallelFor(h) { y in
                let dst = O + y * w
                for x in 0..<w { dst[x] = Float.infinity }
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    let src = T + yy * w
                    for x in 0..<w { dst[x] = min(dst[x], src[x]) }
                }
            }
        }}
        return out
    }

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
