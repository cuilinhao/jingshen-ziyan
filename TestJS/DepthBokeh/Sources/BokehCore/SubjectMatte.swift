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
    /// - Returns: (修正后的视差, 遮罩 α)
    public static func apply(disparity: FloatMap, image: PlanarImage, focusDisparity df: Float,
                             focusPoint: (Float, Float)?, parameters p: SubjectMatteParameters,
                             scale: Float? = nil) -> (FloatMap, FloatMap) {
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

        // 2. 彩色引导滤波（三个通道分别做引导，取平均，比只用亮度更能区分肤色和粉色屏幕这类亮度接近的颜色）
        let r = max(2, Int(Float(max(w, h)) * p.radiusFraction))
        let coreMap = FloatMap(width: w, height: h, values: core)
        var alpha = [Float](repeating: 0, count: n)
        for ch in 0..<3 {
            let src = ch == 0 ? image.r : (ch == 1 ? image.g : image.b)
            var g = [Float](repeating: 0, count: n)
            for i in 0..<n { g[i] = sqrtf(max(0, src[i])) }   // 近似感知亮度，比 sRGB 编码便宜
            let q = DepthRefiner.guidedFilter(guide: FloatMap(width: w, height: h, values: g), input: coreMap,
                                              radius: r, epsilon: p.epsilon)
            for i in 0..<n { alpha[i] += q.values[i] / 3 }
        }
        // 收紧过渡带，边缘更利落
        for i in 0..<n { alpha[i] = smoothstep(0.25, 0.75, alpha[i]) }

        // 3. 修正视差
        //    α 高：拉到对焦面（主体整体清晰，包括深度缺掉的边）
        //    核心内但 α 低（颜色说不是主体，是深度渗出来的）：换成附近较远的视差，按背景虚化
        let farNearby = minFilter(d, width: w, height: h, radius: r)
        var out = d
        for i in 0..<n {
            let a = alpha[i]
            var v = d[i] + a * (df - d[i])
            let leak = max(0, core[i] - a)
            if leak > 0 && farNearby[i] < df - p.band * norm {
                v += leak * (farNearby[i] - v)
            }
            out[i] = v
        }
        return (FloatMap(width: w, height: h, values: out), FloatMap(width: w, height: h, values: alpha))
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
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var m = Float.infinity
                for xx in max(0, x - r)...min(w - 1, x + r) { m = min(m, src[row + xx]) }
                tmp[row + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m = Float.infinity
                for yy in max(0, y - r)...min(h - 1, y + r) { m = min(m, tmp[yy * w + x]) }
                out[y * w + x] = m
            }
        }
        return out
    }

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
