import Foundation

/// 拍照眼镜内有独立背景证据的透射区域。mask 与 disparity 分开保存：
/// 眼镜归属不等于整个像素都在脸上；后续修边和引导滤波不能再把这里拉到焦面。
/// 这是一种保守近似，不分解同一像素里混合的反光与透射。
public struct GlassesTransmission {
    public var mask: FloatMap
    public var disparity: FloatMap

    public init(mask: FloatMap, disparity: FloatMap) {
        self.mask = mask
        self.disparity = disparity
    }

    /// 只从原始有效深度取证；填洞产生的值不参与。没有可靠背景支持时返回 nil。
    /// 调用者还需确认焦点落在原始人物遮罩上（不可用补入眼镜后的遮罩自证）。
    public static func estimate(accepted: FloatMap, glasses: FloatMap, person: FloatMap,
                                rawDepth: FloatMap, colors: PlanarImage, lens: LensParameters) -> Self? {
        let w = rawDepth.width, h = rawDepth.height, n = w * h
        guard n > 0, colors.width == w, colors.height == h, lens.focusDisparity > 0 else { return nil }
        let a = accepted.resized(width: w, height: h).values
        let g = glasses.resized(width: w, height: h).values
        let p = person.resized(width: w, height: h).values
        let d = rawDepth.values
        let farLimit = lens.sharpDisparityRange(limit: 0.003).low
        let depthTolerance = 0.06 * max(lens.relativeScale ?? lens.focusDisparity, 1e-3)
        let rim = max(1, max(w, h) / 400)
        let binary = a.map { $0 > 0.5 ? Float(1) : 0 }
        let edge = SubjectMatte.dilateBinary(binary.map { 1 - $0 }, width: w, height: h, radius: rim)
        // 与引导滤波相同的近似感知颜色空间；色差只是否决条件，不能独自证明是背景。
        let cr = colors.r.map { sqrt(max(0, $0)) }
        let cg = colors.g.map { sqrt(max(0, $0)) }
        let cb = colors.b.map { sqrt(max(0, $0)) }
        var seen = [Bool](repeating: false, count: n)
        var out = [Float](repeating: 0, count: n)
        var any = false
        for start in 0..<n where binary[start] > 0 && !seen[start] {
            var members = [start], next = 0
            seen[start] = true
            var x0 = w, x1 = 0, y0 = h, y1 = 0
            while next < members.count {
                let i = members[next]; next += 1
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (q, valid) in [(i - 1, x > 0), (i + 1, x < w - 1), (i - w, y > 0), (i + w, y < h - 1)]
                where valid && binary[q] > 0 && !seen[q] {
                    seen[q] = true; members.append(q)
                }
            }
            guard members.count >= 12 else { continue }
            let candidates = members.filter { edge[$0] == 0 && p[$0] < 0.9 &&
                d[$0].isFinite && d[$0] > 0 && d[$0] < farLimit }
            guard !candidates.isEmpty else { continue }
            let reach = max(4, min(max(w, h) / 10, max(x1 - x0 + 1, y1 - y0 + 1) / 2))
            // 分四个方向收集镜片外的真实远背景，不能以镜片内部的近深度框阻止取样。
            var sides = [[Int]](repeating: [], count: 4)
            for y in max(0, y0 - reach)...min(h - 1, y1 + reach) {
                for x in max(0, x0 - reach)...min(w - 1, x1 + reach) {
                    let i = y * w + x
                    guard p[i] < 0.05, g[i] < 0.05, binary[i] == 0,
                          d[i].isFinite, d[i] > 0, d[i] < farLimit else { continue }
                    if x < x0 { sides[0].append(i) }
                    else if x > x1 { sides[1].append(i) }
                    else if y < y0 { sides[2].append(i) }
                    else if y > y1 { sides[3].append(i) }
                }
            }
            guard sides.filter({ $0.count >= 4 }).count >= 2 else { continue }
            // 均匀取样控制每片眼镜的开销，保留不同纹理颜色；不靠单个恰巧同色像素。
            let samples = sides.map { side -> [Int] in
                guard side.count > 64 else { return side }
                return (0..<64).map { side[$0 * side.count / 64] }
            }
            for i in candidates {
                var directions = 0
                for side in samples {
                    var matches = 0
                    for q in side where abs(d[q] - d[i]) <= depthTolerance {
                        let difference = max(abs(cr[q] - cr[i]), max(abs(cg[q] - cg[i]), abs(cb[q] - cb[i])))
                        if difference <= 0.07 { matches += 1 }
                        if matches >= 3 { break }
                    }
                    if matches >= 3 { directions += 1 }
                }
                if directions >= 2 { out[i] = 1; any = true }
            }
        }
        guard any else { return nil }
        // 不把 NaN 上传到 GPU。mask=0 的值无效，渲染时采用预乘后的插值避免无效值污染边缘。
        let finite = d.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        return Self(mask: FloatMap(width: w, height: h, values: out),
                    disparity: FloatMap(width: w, height: h, values: finite))
    }

    /// mask 的插值只在几乎完全覆盖时生效，避免把背景深度带进细镜框。
    /// 深度使用预乘插值，镜片外的近深度/无效深度不会污染目标。
    public func sampled(width: Int, height: Int) -> (mask: [Float], disparity: [Float]) {
        let original = disparity.resized(width: mask.width, height: mask.height)
        let weighted = FloatMap(width: mask.width, height: mask.height,
                                values: zip(mask.values, original.values).map { $0 * $1 })
        let m = SubjectMatte.sampleAt(mask, width: width, height: height)
        let z = SubjectMatte.sampleAt(weighted, width: width, height: height)
        var coverage = m
        if width < mask.width || height < mask.height {
            // 缩小时必须检查整个目标像素覆盖的源区域：只采中心会跳过细框/孤立反光。
            // 与 Metal 使用同一整数边界，不把覆盖不完整的像素恢复成纯背景。
            for y in 0..<height { for x in 0..<width {
                let x0 = x * mask.width / width
                let x1 = ((x + 1) * mask.width + width - 1) / width - 1
                let y0 = y * mask.height / height
                let y1 = ((y + 1) * mask.height + height - 1) / height - 1
                let i = y * width + x
                for yy in y0...y1 { for xx in x0...x1 {
                    coverage[i] = min(coverage[i], mask[xx, yy])
                } }
            } }
        }
        return (coverage.map { value in
            let t = min(1, max(0, (value - 0.9) / 0.1))
            return t * t * (3 - 2 * t)
        }, zip(m, z).map { $0 > 1e-6 ? $1 / $0 : 0 })
    }
}
