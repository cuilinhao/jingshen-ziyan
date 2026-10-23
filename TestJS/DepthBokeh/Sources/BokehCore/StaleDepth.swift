import Foundation

/// 这一帧没有新深度时，把上一帧（已经和上一帧画面对齐的）深度搬到这一帧的画面上。
///
/// 相机有时这一帧没有送来新的深度（晚到被丢、深度帧率比视频低），只能沿用旧的那张。
/// 画面里的东西在动时（比如手在镜头前上下挥），旧深度里的手还停在原来的位置：
///  - 手离开的地方，深度还说「这里是近处的手」→ 背景被当成前景，一块一块地虚化或清晰
///  - 手新移到的地方，深度还说「这里是背景」→ 手的边缘被当成背景虚化掉，看起来半透明
/// 合在一起就是「手有重影」。录下来的数据里（S05），同一帧的深度和画面是对齐的；
/// 错位只出现在沿用旧深度的帧上，而且时间平滑会把错的深度再拖几帧。
///
/// 做法（每次只差一帧，所以手挥得快也追得上；新深度一来就不用了）：
///  1. 哪里变了：这一帧和上一帧的颜色差（√线性光，三通道取最大），5×5 邻域取最大 → U（0 没变 … 1 变了）。
///     只看亮度不够：肤色和浅灰的柜子亮度差不多
///  2. 运动：1/4 分辨率上，每块（4×4 像素）在上一帧 ±12 块（±48 像素）里找 3×3 色块差最小的位置。
///     只算 U 附近的块
///  3. 每个变了的像素在相邻 3×3 块的运动里挑一个（全分辨率 3×3 色块差最小），
///     取上一帧那个位置的深度：手新移到的地方取到手的深度；手离开、露出来的背景找到相似的背景，取到背景的深度
///  4. 变了的区域附近再用这一帧的亮度做一次引导滤波，深度边缘贴到这一帧的轮廓上
/// 在 S05（拳头在镜头前挥动，深度每 3 帧才有一张新的）上，沿用帧里深度错了一大截的像素从 6.3% 降到 1.4%。
///
/// CPU 参考实现；GPU（BokehMetal）逐步一致。
public enum StaleDepth {
    /// 颜色（√线性光，每个通道）差在这个范围内从「没变」过渡到「变了」
    public static let changeLow: Float = 0.04
    public static let changeHigh: Float = 0.10
    /// U：颜色差取最大值的邻域半径；snap：引导滤波作用范围的半径（低分辨率像素）
    public static let maskRadius = 2
    public static let snapRadius = 5
    /// 运动搜索：块大小（像素）、搜索半径（块）
    public static let block = 4
    public static let searchRadius = 12
    /// 越界的色块差
    static let outsideCost: Float = 3

    public struct Result {
        public var depth: FloatMap
        /// 变了的程度 U
        public var changed: [Float]
    }

    /// - Parameters:
    ///   - depth: 上一帧的深度（和上一帧画面对齐），低分辨率
    ///   - now / previous: 这一帧、上一帧的低分辨率画面（线性光），和 depth 一样大
    ///   - guideLuma: 这一帧的 perceptualLuma
    ///   - gfRadius: 引导滤波半径（和深度对齐用的一样）
    public static func realign(depth: FloatMap, now: PlanarImage, previous: PlanarImage,
                               guideLuma: FloatMap, gfRadius: Int) -> Result {
        let w = depth.width, h = depth.height, n = w * h
        guard now.width == w, now.height == h, previous.width == w, previous.height == h,
              guideLuma.width == w, guideLuma.height == h else {
            return Result(depth: depth, changed: [Float](repeating: 0, count: n))
        }
        let cn = sqrtColors(now), cp = sqrtColors(previous)
        let diff = colorDiff(cn, cp)
        let u = maxSmoothstep(diff, width: w, height: h, radius: maskRadius)
        let us = maxSmoothstep(diff, width: w, height: h, radius: snapRadius)
        let qn = quarter(now), qp = quarter(previous)
        let flow = blockFlow(cur: qn, prev: qp, changed: u, width: w, height: h)
        var out = warp(depth: depth, cn: cn, cp: cp, changed: u, flow: flow, blocksX: qn.width, blocksY: qn.height)
        // 变了的区域附近：按这一帧的亮度贴边
        let g = DepthRefiner.guidedFilter(guide: guideLuma, input: out, radius: gfRadius, epsilon: 2e-4)
        for i in 0..<n where us[i] > 0 { out.values[i] += us[i] * (g.values[i] - out.values[i]) }
        return Result(depth: out, changed: u)
    }

    /// 两张同样大的画面之间哪里变了（U，0 没变 … 1 变了）
    public static func changed(_ now: PlanarImage, since old: PlanarImage) -> [Float] {
        guard now.width == old.width, now.height == old.height else {
            return [Float](repeating: 1, count: now.pixelCount)
        }
        return maxSmoothstep(colorDiff(sqrtColors(now), sqrtColors(old)), width: now.width, height: now.height,
                             radius: maskRadius)
    }

    /// 同上，但允许两张图之间有一点错位：先估计整体平移（±shiftRadius 像素），再允许每个像素 ±1 像素的出入。
    /// 用在几帧之前算的人像 / 物体遮罩上：长焦手持时整幅画面会抖几个像素，强边缘（盒子顶边和后面的暗背景）
    /// 一抖就会被当成「变了」，遮罩在那一圈被扔掉，盒子顶上就忽清忽糊、像一层波纹。手挥走这种大变化照样看得出来
    public static func changedAllowingShift(_ now: PlanarImage, since old: PlanarImage, shiftRadius R: Int = 3) -> [Float] {
        let w = now.width, h = now.height, n = w * h
        guard old.width == w, old.height == h, w > 2 * R + 2, h > 2 * R + 2 else {
            return [Float](repeating: 1, count: n)
        }
        // 先各自做 3×3 平均：纹理在亚像素错位下的差别抹掉，整块东西挪走的大变化留着
        func smoothed(_ img: PlanarImage) -> [Float] {
            let c = sqrtColors(img)
            var out = [Float](repeating: 0, count: n * 3)
            for ch in 0..<3 {
                let m = BoxFilter.mean((0..<n).map { c[3 * $0 + ch] }, width: w, height: h, radius: 1)
                for i in 0..<n { out[3 * i + ch] = m[i] }
            }
            return out
        }
        let a = smoothed(now), b = smoothed(old)
        @inline(__always) func d(_ i: Int, _ j: Int) -> Float {
            max(abs(a[3 * i] - b[3 * j]), max(abs(a[3 * i + 1] - b[3 * j + 1]), abs(a[3 * i + 2] - b[3 * j + 2])))
        }
        // 整体平移：中间区域的平均差最小的（先算不平移，平局时不动）
        func cost(_ sx: Int, _ sy: Int) -> Float {
            var s: Float = 0
            for y in R..<(h - R) { for x in R..<(w - R) { s += d(y * w + x, (y + sy) * w + x + sx) } }
            return s
        }
        var best = cost(0, 0), bx = 0, by = 0
        for sy in -R...R {
            for sx in -R...R where sx != 0 || sy != 0 {
                let c = cost(sx, sy)
                if c < best { best = c; bx = sx; by = sy }
            }
        }
        // 每个像素：平移后再在 3×3 里找最像的
        var diff = [Float](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for oy in -1...1 {
                    for ox in -1...1 {
                        let qx = min(max(x + bx + ox, 0), w - 1), qy = min(max(y + by + oy, 0), h - 1)
                        m = min(m, d(y * w + x, qy * w + qx))
                    }
                }
                diff[y * w + x] = m
            }
        }
        // 变了的地方往外扩 2 像素（长边 80 时约 1/40 画面）：手挥走后边上残留的一条旧遮罩也去掉
        return maxSmoothstep(diff, width: w, height: h, radius: 2)
    }

    /// √线性光（三个通道交错存放：r, g, b, r, g, b…）
    static func sqrtColors(_ img: PlanarImage) -> [Float] {
        let n = img.pixelCount
        var out = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            out[3 * i] = sqrtf(max(img.r[i], 0))
            out[3 * i + 1] = sqrtf(max(img.g[i], 0))
            out[3 * i + 2] = sqrtf(max(img.b[i], 0))
        }
        return out
    }

    /// 每个像素两帧颜色差（三个通道里最大的）
    static func colorDiff(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = a.count / 3
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = max(abs(a[3 * i] - b[3 * i]), max(abs(a[3 * i + 1] - b[3 * i + 1]), abs(a[3 * i + 2] - b[3 * i + 2])))
        }
        return out
    }

    /// smoothstep(changeLow, changeHigh, (2r+1)² 邻域里的最大值)
    static func maxSmoothstep(_ d: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        d.withUnsafeBufferPointer { dp in
        out.withUnsafeMutableBufferPointer { op in
            let D = dp.baseAddress!, O = op.baseAddress!
            parallelFor(h) { y in
                let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                for x in 0..<w {
                    let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                    var m: Float = 0
                    for yy in y0...y1 {
                        for xx in x0...x1 { m = max(m, D[yy * w + xx]) }
                    }
                    O[y * w + x] = BokehRenderer.smoothstep(changeLow, changeHigh, m)
                }
            }
        }}
        return out
    }

    /// 1/block 分辨率的 √颜色：每块（边上的块只算图内的像素）线性光取平均再开方
    static func quarter(_ img: PlanarImage) -> (width: Int, height: Int, c: [Float]) {
        let w = img.width, h = img.height, q = block
        let bw = (w + q - 1) / q, bh = (h + q - 1) / q
        var out = [Float](repeating: 0, count: bw * bh * 3)
        for by in 0..<bh {
            for bx in 0..<bw {
                var r: Float = 0, g: Float = 0, b: Float = 0
                let x0 = bx * q, x1 = min(w, x0 + q), y0 = by * q, y1 = min(h, y0 + q)
                for y in y0..<y1 {
                    for x in x0..<x1 { let i = y * w + x; r += img.r[i]; g += img.g[i]; b += img.b[i] }
                }
                let inv = 1 / Float((x1 - x0) * (y1 - y0))
                let j = 3 * (by * bw + bx)
                out[j] = sqrtf(max(r * inv, 0)); out[j + 1] = sqrtf(max(g * inv, 0)); out[j + 2] = sqrtf(max(b * inv, 0))
            }
        }
        return (bw, bh, out)
    }

    /// 每块的运动（块为单位）。周围 3×3 块里都没有变化的块不算（运动 = 0）
    static func blockFlow(cur: (width: Int, height: Int, c: [Float]), prev: (width: Int, height: Int, c: [Float]),
                          changed u: [Float], width w: Int, height h: Int) -> [Int32] {
        let bw = cur.width, bh = cur.height, q = block, R = searchRadius
        // 每块里最大的 U
        var blockU = [Float](repeating: 0, count: bw * bh)
        for y in 0..<h {
            for x in 0..<w { let j = (y / q) * bw + x / q; blockU[j] = max(blockU[j], u[y * w + x]) }
        }
        var flow = [Int32](repeating: 0, count: bw * bh * 2)
        let C = cur.c, P = prev.c
        flow.withUnsafeMutableBufferPointer { fp in
            let F = fp.baseAddress!
            parallelFor(bh) { by in
                for bx in 0..<bw {
                    var active = false
                    for oy in -1...1 {
                        for ox in -1...1 {
                            let nx = bx + ox, ny = by + oy
                            if nx >= 0 && ny >= 0 && nx < bw && ny < bh && blockU[ny * bw + nx] > 0.001 { active = true }
                        }
                    }
                    if !active { continue }
                    func cost(_ dx: Int, _ dy: Int) -> Float {
                        var s: Float = 0
                        for oy in -1...1 {
                            for ox in -1...1 {
                                let ax = min(max(bx + ox, 0), bw - 1), ay = min(max(by + oy, 0), bh - 1)
                                let sx = ax + dx, sy = ay + dy
                                if sx < 0 || sy < 0 || sx >= bw || sy >= bh { s += outsideCost; continue }
                                let a = 3 * (ay * bw + ax), b = 3 * (sy * bw + sx)
                                s += abs(C[a] - P[b]) + abs(C[a + 1] - P[b + 1]) + abs(C[a + 2] - P[b + 2])
                            }
                        }
                        return s
                    }
                    var best = cost(0, 0), bdx = 0, bdy = 0
                    for dy in -R...R {
                        for dx in -R...R where dx != 0 || dy != 0 {
                            let c = cost(dx, dy)
                            if c < best { best = c; bdx = dx; bdy = dy }
                        }
                    }
                    F[2 * (by * bw + bx)] = Int32(bdx)
                    F[2 * (by * bw + bx) + 1] = Int32(bdy)
                }
            }
        }
        return flow
    }

    /// 变了的像素：在相邻 3×3 块的运动里挑全分辨率 3×3 色块差最小的，取上一帧那里的深度
    static func warp(depth: FloatMap, cn: [Float], cp: [Float], changed u: [Float], flow: [Int32],
                     blocksX bw: Int, blocksY bh: Int) -> FloatMap {
        let w = depth.width, h = depth.height, q = block
        let src = depth.values
        var out = src
        out.withUnsafeMutableBufferPointer { op in
            let O = op.baseAddress!
            parallelFor(h) { y in
                for x in 0..<w {
                    let i = y * w + x
                    let ui = u[i]
                    if ui <= 0.001 { continue }
                    let bx = x / q, by = y / q
                    var best = Float.infinity, vx = 0, vy = 0
                    for oy in -1...1 {
                        for ox in -1...1 {
                            let nx = min(max(bx + ox, 0), bw - 1), ny = min(max(by + oy, 0), bh - 1)
                            let cx = Int(flow[2 * (ny * bw + nx)]) * q, cy = Int(flow[2 * (ny * bw + nx) + 1]) * q
                            var s: Float = 0
                            for py in -1...1 {
                                for px in -1...1 {
                                    let ax = min(max(x + px, 0), w - 1), ay = min(max(y + py, 0), h - 1)
                                    let sx = min(max(ax + cx, 0), w - 1), sy = min(max(ay + cy, 0), h - 1)
                                    let a = 3 * (ay * w + ax), b = 3 * (sy * w + sx)
                                    s += abs(cn[a] - cp[b]) + abs(cn[a + 1] - cp[b + 1]) + abs(cn[a + 2] - cp[b + 2])
                                }
                            }
                            if s < best { best = s; vx = cx; vy = cy }
                        }
                    }
                    let sx = min(max(x + vx, 0), w - 1), sy = min(max(y + vy, 0), h - 1)
                    O[i] = src[i] + ui * (src[sy * w + sx] - src[i])
                }
            }
        }
        return FloatMap(width: w, height: h, values: out)
    }
}
