import Foundation

/// 深度图处理：补洞、上采样、用彩色图做边缘对齐（引导滤波）、取对焦点视差。
///
/// iPhone 给的视差图分辨率低（实时流通常是 320×240 或 640×480 一类）、边缘发糊，
/// 物体轮廓和彩色图对不齐。直接拿来算模糊，主体边缘会出现一圈「光晕」。
/// 引导滤波（He et al. 2010）让视差图在彩色图有边缘的地方也出现边缘，
/// 在彩色图平坦的地方保持平滑。
public enum DepthRefiner {

    /// 一站式处理：补洞 -> 上采样到图像尺寸 -> 引导滤波
    /// - Parameters:
    ///   - disparity: 原始视差图（单位 1/米），可以包含 NaN / 0 等无效值
    ///   - image: 要渲染的彩色图（线性光），决定输出尺寸，也作为引导图
    ///   - radiusScale: 引导滤波窗口半径 = radiusScale × 上采样倍数。
    ///     深度图越粗糙（放大倍数越大），边缘错位越多，需要的窗口越大
    ///   - epsilon: 正则项，越小越「贴边」，越大越平滑
    ///   - guideLuma: 已经算好的 image.perceptualLuma()（可选，省一次计算）
    public static func refine(disparity: FloatMap, guide image: PlanarImage,
                              radiusScale: Float = 2.5, epsilon: Float = 2e-4,
                              passes: Int = 2, guideLuma: FloatMap? = nil) -> FloatMap {
        let filled = fillInvalid(disparity)
        var up = filled.resized(width: image.width, height: image.height)
        let guide = guideLuma ?? image.perceptualLuma()
        let r = radius(disparity: disparity, image: image, radiusScale: radiusScale)
        for i in 0..<passes {
            // 第二遍用更小的半径收紧边缘
            let radius = i == 0 ? r : max(1, r / 2)
            up = guidedFilter(guide: guide, input: up, radius: radius, epsilon: epsilon)
        }
        return up
    }

    /// 引导滤波窗口半径：radiusScale × 上采样倍数，限制在 [2, 长边 / 40]
    public static func radius(disparity: FloatMap, image: PlanarImage, radiusScale: Float = 2.5) -> Int {
        let upscale = Float(image.longSide) / Float(max(disparity.width, disparity.height))
        return min(max(2, Int((radiusScale * upscale).rounded())), max(2, image.longSide / 40))
    }

    /// 用拉推法（pull-push）填补视差图里的无效像素
    public static func fillInvalid(_ map: FloatMap) -> FloatMap {
        var weight = [Float](repeating: 0, count: map.values.count)
        var premult = [Float](repeating: 0, count: map.values.count)
        var anyInvalid = false
        for i in 0..<map.values.count {
            let v = map.values[i]
            if v.isFinite && v > 0 {
                weight[i] = 1
                premult[i] = v
            } else {
                anyInvalid = true
            }
        }
        if !anyInvalid { return map }
        let filled = PullPush.fill(premultiplied: [premult], weight: weight,
                                   width: map.width, height: map.height)
        return FloatMap(width: map.width, height: map.height, values: filled[0])
    }

    /// 灰度引导的引导滤波：q = a·I + b，a、b 在每个窗口里做线性回归
    public static func guidedFilter(guide I: FloatMap, input p: FloatMap, radius r: Int, epsilon eps: Float) -> FloatMap {
        precondition(I.width == p.width && I.height == p.height)
        let w = I.width, h = I.height, n = w * h
        var Ip = [Float](repeating: 0, count: n)
        var II = [Float](repeating: 0, count: n)
        for i in 0..<n {
            Ip[i] = I.values[i] * p.values[i]
            II[i] = I.values[i] * I.values[i]
        }
        let meanI = BoxFilter.mean(I.values, width: w, height: h, radius: r)
        let meanP = BoxFilter.mean(p.values, width: w, height: h, radius: r)
        let meanIp = BoxFilter.mean(Ip, width: w, height: h, radius: r)
        let meanII = BoxFilter.mean(II, width: w, height: h, radius: r)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let cov = meanIp[i] - meanI[i] * meanP[i]
            let varI = meanII[i] - meanI[i] * meanI[i]
            a[i] = cov / (varI + eps)
            b[i] = meanP[i] - a[i] * meanI[i]
        }
        let meanA = BoxFilter.mean(a, width: w, height: h, radius: r)
        let meanB = BoxFilter.mean(b, width: w, height: h, radius: r)
        var q = [Float](repeating: 0, count: n)
        for i in 0..<n { q[i] = meanA[i] * I.values[i] + meanB[i] }
        return FloatMap(width: w, height: h, values: q)
    }

    /// 取对焦点的视差：在点击位置附近取一个小窗口的中位数，
    /// 比单点取值稳定（单点可能刚好落在边缘或噪点上）
    /// - Parameters:
    ///   - nx, ny: 归一化坐标 0...1
    public static func focusDisparity(in map: FloatMap, nx: Float, ny: Float, windowFraction: Float = 0.03) -> Float {
        let cx = Int(nx * Float(map.width)), cy = Int(ny * Float(map.height))
        let r = max(1, Int(Float(max(map.width, map.height)) * windowFraction))
        var samples: [Float] = []
        samples.reserveCapacity((2 * r + 1) * (2 * r + 1))
        for y in max(0, cy - r)...min(map.height - 1, cy + r) {
            for x in max(0, cx - r)...min(map.width - 1, cx + r) {
                let v = map[x, y]
                if v.isFinite && v > 0 { samples.append(v) }
            }
        }
        guard !samples.isEmpty else { return 1 }
        samples.sort()
        return samples[samples.count / 2]
    }
}

/// O(1) 每像素的盒式均值滤波（可分离，行列各一次滑动求和）
enum BoxFilter {
    static func mean(_ src: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        let n = w * h
        guard n > 0 else { return [] }
        var tmp = [Float](repeating: 0, count: n)
        var out = [Float](repeating: 0, count: n)
        src.withUnsafeBufferPointer { sp in
        tmp.withUnsafeMutableBufferPointer { tp in
            let S = sp.baseAddress!, T = tp.baseAddress!
            // 水平方向：每行一个滑动窗口
            parallelFor(h) { y in
                let row = S + y * w, dst = T + y * w
                var acc: Float = 0
                for x in 0...min(r, w - 1) { acc += row[x] }
                for x in 0..<w {
                    let lo = max(0, x - r), hi = min(w - 1, x + r)
                    dst[x] = acc / Float(hi - lo + 1)
                    let add = x + r + 1, sub = x - r
                    if add < w { acc += row[add] }
                    if sub >= 0 { acc -= row[sub] }
                }
            }
        }}
        tmp.withUnsafeBufferPointer { tp in
        out.withUnsafeMutableBufferPointer { op in
            let T = tp.baseAddress!, O = op.baseAddress!
            // 垂直方向：按列分块，每块维护一行「列和」，逐行向下滑动（按行连续访问内存，比逐列快）
            let bands = max(1, min(8, w / 32))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let x0 = band * w / bands, x1 = (band + 1) * w / bands
                let bw = x1 - x0
                guard bw > 0 else { return }
                var col = [Float](repeating: 0, count: bw)
                col.withUnsafeMutableBufferPointer { cp in
                    let C = cp.baseAddress!
                    for y in 0...min(r, h - 1) {
                        let row = T + y * w + x0
                        for x in 0..<bw { C[x] += row[x] }
                    }
                    for y in 0..<h {
                        let lo = max(0, y - r), hi = min(h - 1, y + r)
                        let inv = 1 / Float(hi - lo + 1)
                        let dst = O + y * w + x0
                        for x in 0..<bw { dst[x] = C[x] * inv }
                        let add = y + r + 1, sub = y - r
                        if add < h { let row = T + add * w + x0; for x in 0..<bw { C[x] += row[x] } }
                        if sub >= 0 { let row = T + sub * w + x0; for x in 0..<bw { C[x] -= row[x] } }
                    }
                }
            }
        }}
        return out
    }
}
