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
}
