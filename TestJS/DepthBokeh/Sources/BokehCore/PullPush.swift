import Foundation

/// 拉推法（pull-push）补洞。
///
/// 输入是「预乘」的通道值和权重（权重 0 = 这里没有数据）。
/// 先逐级下采样（pull）把有效数据往粗层级汇聚，再逐级上采样（push）
/// 用粗层级的颜色填补细层级里缺数据的地方。复杂度 O(N)。
///
/// 景深渲染里用它来「猜」前景物体背后被挡住的背景：
/// 前景虚化后边缘会变半透明，必须有东西可以透出来。
/// 摄像头没拍到那部分，只能从周围的背景外推 —— iPhone 前景虚化时
/// 物体边缘出现的「拖影/涂抹」感，本质上就是这一步的痕迹。
enum PullPush {
    private struct Level {
        let w: Int, h: Int
        var ch: [[Float]]
        var wt: [Float]
    }

    /// - Returns: 每个通道填补后的「非预乘」值（权重视为 1）
    static func fill(premultiplied channels: [[Float]], weight: [Float], width: Int, height: Int) -> [[Float]] {
        let c = channels.count
        var levels = [Level(w: width, h: height, ch: channels, wt: weight)]

        // pull：逐级 2×2 汇聚
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let prev = levels.last!
            let nw = max(1, (prev.w + 1) / 2), nh = max(1, (prev.h + 1) / 2)
            var nwt = [Float](repeating: 0, count: nw * nh)
            var scales = [Float](repeating: 1, count: nw * nh)
            prev.wt.withUnsafeBufferPointer { wp in
            nwt.withUnsafeMutableBufferPointer { np in
            scales.withUnsafeMutableBufferPointer { sp in
                let W = wp.baseAddress!, N = np.baseAddress!, S = sp.baseAddress!
                parallelFor(nh) { y in
                    for x in 0..<nw {
                        var ws: Float = 0
                        for dy in 0..<2 where 2 * y + dy < prev.h {
                            for dx in 0..<2 where 2 * x + dx < prev.w {
                                ws += W[(2 * y + dy) * prev.w + 2 * x + dx]
                            }
                        }
                        // 权重饱和到 1：有效数据足够的格子不再继续累加
                        let s: Float = ws > 1 ? 1 / ws : 1
                        S[y * nw + x] = s
                        N[y * nw + x] = ws * s
                    }
                }
            }}}
            var nch: [[Float]] = []
            for k in 0..<c {
                var dst = [Float](repeating: 0, count: nw * nh)
                prev.ch[k].withUnsafeBufferPointer { cp in
                scales.withUnsafeBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    let C = cp.baseAddress!, S = sp.baseAddress!, D = dp.baseAddress!
                    parallelFor(nh) { y in
                        for x in 0..<nw {
                            var cs: Float = 0
                            for dy in 0..<2 where 2 * y + dy < prev.h {
                                for dx in 0..<2 where 2 * x + dx < prev.w {
                                    cs += C[(2 * y + dy) * prev.w + 2 * x + dx]
                                }
                            }
                            D[y * nw + x] = cs * S[y * nw + x]
                        }
                    }
                }}}
                nch.append(dst)
            }
            levels.append(Level(w: nw, h: nh, ch: nch, wt: nwt))
        }

        // push：从最粗一级开始往回填
        let top = levels.last!
        var filled: [[Float]] = (0..<c).map { k in
            [top.wt[0] > 0 ? top.ch[k][0] / top.wt[0] : 0]
        }
        var fw = 1, fh = 1
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let L = levels[li]
            var next: [[Float]] = []
            let sx = Float(fw) / Float(L.w), sy = Float(fh) / Float(L.h)
            for k in 0..<c {
                let coarseMap = FloatMap(width: fw, height: fh, values: filled[k])
                var dst = [Float](repeating: 0, count: L.w * L.h)
                L.ch[k].withUnsafeBufferPointer { pp in
                L.wt.withUnsafeBufferPointer { wp in
                dst.withUnsafeMutableBufferPointer { np in
                    let P = pp.baseAddress!, W = wp.baseAddress!, N = np.baseAddress!
                    parallelFor(L.h) { y in
                        let fy = (Float(y) + 0.5) * sy
                        for x in 0..<L.w {
                            let i = y * L.w + x
                            let wi = W[i]
                            if wi >= 1 {
                                N[i] = P[i]
                            } else {
                                let up = coarseMap.sampleBilinear(x: (Float(x) + 0.5) * sx, y: fy)
                                N[i] = P[i] + (1 - wi) * up
                            }
                        }
                    }
                }}}
                next.append(dst)
            }
            filled = next
            fw = L.w; fh = L.h
        }
        return filled
    }

    /// 按颜色引导的拉推补洞（一个通道，比如视差）。
    ///
    /// 普通拉推往回填时只看位置：一大块没数据的地方（白墙、显示器屏幕，双摄在没纹理的地方测不出视差）
    /// 用的是四周所有数据的平均，旁边颜色完全不同、远近也完全不同的东西一起被平均进来。
    /// 这里往回填时，粗一级附近的几个格子还要按颜色加权：每个格子记着「它的值是从什么颜色的像素来的」，
    /// 和这个像素（这一级的格子）自己的颜色差得越多，权重越小。白墙的洞主要从零星测到的那些白墙像素补，
    /// 物体边上被挡住、测不到的那一条背景也主要从背景补。
    /// - Parameters:
    ///   - values / weight: 数值和权重（权重 0 = 没数据，1 = 有）
    ///   - guide: 3 个通道的颜色（建议 sqrt(线性光)），和 values 一样大
    ///   - sigma: 颜色差的尺度（guide 的单位）
    static func fillGuided(values: [Float], weight: [Float], guide: [[Float]], width: Int, height: Int,
                           sigma: Float) -> [Float] {
        // 每一级每个格子 8 个数：预乘的值、权重（饱和到 1）、预乘的「数据像素的颜色」×3、这一级格子的平均颜色×3
        let S = 8
        let n = width * height
        var base = [Float](repeating: 0, count: n * S)
        for i in 0..<n {
            let wi = weight[i], o = i * S
            base[o] = wi > 0 ? values[i] * wi : 0
            base[o + 1] = wi
            for k in 0..<3 {
                let g = guide[k][i]
                base[o + 2 + k] = g * wi
                base[o + 5 + k] = g
            }
        }
        var levels: [(w: Int, h: Int, d: [Float])] = [(width, height, base)]

        // pull：逐级 2×2 汇聚
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let p = levels.last!
            let pw = p.w, ph = p.h
            let nw = max(1, (pw + 1) / 2), nh = max(1, (ph + 1) / 2)
            var dst = [Float](repeating: 0, count: nw * nh * S)
            p.d.withUnsafeBufferPointer { Pp in
            dst.withUnsafeMutableBufferPointer { Dp in
                let P = Pp.baseAddress!, D = Dp.baseAddress!
                parallelFor(nh) { y in
                    for x in 0..<nw {
                        var acc = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
                        var cnt: Float = 0
                        for dy in 0..<2 where 2 * y + dy < ph {
                            for dx in 0..<2 where 2 * x + dx < pw {
                                let j = ((2 * y + dy) * pw + 2 * x + dx) * S
                                acc.0 += P[j]; acc.1 += P[j + 1]; acc.2 += P[j + 2]; acc.3 += P[j + 3]
                                acc.4 += P[j + 4]; acc.5 += P[j + 5]; acc.6 += P[j + 6]; acc.7 += P[j + 7]
                                cnt += 1
                            }
                        }
                        let s: Float = acc.1 > 1 ? 1 / acc.1 : 1
                        let o = (y * nw + x) * S
                        D[o] = acc.0 * s; D[o + 1] = acc.1 * s
                        D[o + 2] = acc.2 * s; D[o + 3] = acc.3 * s; D[o + 4] = acc.4 * s
                        D[o + 5] = acc.5 / cnt; D[o + 6] = acc.6 / cnt; D[o + 7] = acc.7 / cnt
                    }
                }
            }}
            levels.append((nw, nh, dst))
        }

        // push：粗一级最近的 2×2 个格子，双线性权重 × 颜色像不像。
        // 填好的每个格子 4 个数：值、「这个值是从什么颜色的像素来的」×3
        let top = levels.last!.d
        let tw = top[1]
        var filled: [Float] = tw > 0 ? [top[0] / tw, top[2] / tw, top[3] / tw, top[4] / tw] : [0, 0, 0, 0]
        var fw = 1, fh = 1
        let inv2s2 = 1 / max(1e-6, 2 * sigma * sigma)
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let L = levels[li]
            let lw = L.w, lh = L.h, cw = fw, ch = fh
            let sx = Float(cw) / Float(lw), sy = Float(ch) / Float(lh)
            var next = [Float](repeating: 0, count: lw * lh * 4)
            L.d.withUnsafeBufferPointer { Lp in
            filled.withUnsafeBufferPointer { Fp in
            next.withUnsafeMutableBufferPointer { Np in
                let A = Lp.baseAddress!, F = Fp.baseAddress!, N = Np.baseAddress!
                parallelFor(lh) { y in
                    let cy = (Float(y) + 0.5) * sy - 0.5
                    for x in 0..<lw {
                        let i = y * lw + x, a = i * S, o = i * 4
                        let wi = A[a + 1]
                        if wi >= 1 {
                            N[o] = A[a]; N[o + 1] = A[a + 2]; N[o + 2] = A[a + 3]; N[o + 3] = A[a + 4]
                            continue
                        }
                        let cx = (Float(x) + 0.5) * sx - 0.5
                        let g0 = A[a + 5], g1 = A[a + 6], g2 = A[a + 7]
                        var sw: Float = 0, sv: Float = 0, s0: Float = 0, s1: Float = 0, s2: Float = 0
                        // 双线性的 4 个格子，每个再乘颜色权重
                        let x0 = min(max(Int(floorf(cx)), 0), cw - 1), x1 = min(x0 + 1, cw - 1)
                        let y0 = min(max(Int(floorf(cy)), 0), ch - 1), y1 = min(y0 + 1, ch - 1)
                        let fx = min(max(cx - Float(x0), 0), 1), fy = min(max(cy - Float(y0), 0), 1)
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        for t in 0..<4 {
                            let qx = t & 1 == 0 ? x0 : x1, qy = t < 2 ? y0 : y1
                            let ws = t == 0 ? w00 : (t == 1 ? w10 : (t == 2 ? w01 : w11))
                            if ws <= 0 { continue }
                            let q = (qy * cw + qx) * 4
                            let d0 = g0 - F[q + 1], d1 = g1 - F[q + 2], d2 = g2 - F[q + 3]
                            // 颜色权重留一点底：附近全是别的颜色时退化成普通拉推，不会补不上
                            let k = ws * (fastExpNeg((d0 * d0 + d1 * d1 + d2 * d2) * inv2s2) + 1e-3)
                            sw += k; sv += k * F[q]; s0 += k * F[q + 1]; s1 += k * F[q + 2]; s2 += k * F[q + 3]
                        }
                        let r = 1 - wi, invw = sw > 0 ? 1 / sw : 0
                        N[o] = A[a] + r * sv * invw
                        N[o + 1] = A[a + 2] + r * s0 * invw
                        N[o + 2] = A[a + 3] + r * s1 * invw
                        N[o + 3] = A[a + 4] + r * s2 * invw
                    }
                }
            }}}
            filled = next
            fw = lw; fh = lh
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = filled[i * 4] }
        return out
    }

    /// e^(−x)，x ≥ 0。只用来算权重，几个百分点的误差无所谓：直接拼浮点数的指数位（Schraudolph），比 expf 快几倍
    @inline(__always)
    static func fastExpNeg(_ x: Float) -> Float {
        if x >= 80 { return 0 }
        let i = Int32(-x * 12102203.0) + 1065353216 - 366393
        return Float(bitPattern: UInt32(bitPattern: max(0, i)))
    }
}
