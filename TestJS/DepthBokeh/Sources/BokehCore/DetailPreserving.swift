import Foundation

/// 对焦主体的提示：对焦点位置 + 主体遮罩参数（见 SubjectMatte）
public struct SubjectHint {
    public var point: (Float, Float)?
    public var parameters: SubjectMatteParameters
    /// 人像分割遮罩（和视差图同一画面，任意分辨率，0…1）。对焦点落在人身上时，整个人保持清晰 ——
    /// 包括伸出脸外、深度根本测不到的眼镜框
    public var personMask: FloatMap?
    public init(point: (Float, Float)?, parameters: SubjectMatteParameters = SubjectMatteParameters(),
                personMask: FloatMap? = nil) {
        self.point = point
        self.parameters = parameters
        self.personMask = personMask
    }
}

extension BokehRenderer {

    /// 双分辨率渲染：模糊在低分辨率上算，清晰部分用全分辨率原图。
    ///
    ///     输出 = 放大(低分辨率虚化结果) + (1 - w) × (全分辨率原图 - 放大(低分辨率原图))
    ///
    /// 第二项是原图的「高频细节」。w 是这个像素被虚化的程度：
    ///  - 在对焦面上（w = 0）：低分辨率虚化结果和低分辨率原图相同，输出就是全分辨率原图，完全清晰
    ///  - 被虚化的地方（w = 1）：只剩放大后的模糊结果（模糊本身没有细节，放大看不出来）
    /// w 同时考虑「自身的模糊半径」和「有没有被前景的虚化盖住」，前景虚化盖到主体上时细节也会被抹掉。
    ///
    /// - Parameters:
    ///   - full: 全分辨率图像（线性光）
    ///   - disparity: 任意分辨率的视差图（会被缩放、对齐到低分辨率图像）
    ///   - lowLongSide: 低分辨率的长边像素数（实时预览建议 360–480）
    ///   - temporal: 实时预览传同一个对象进来，跨帧稳定深度边缘和光斑；拍照编辑传 nil
    public func renderDetailPreserving(full: PlanarImage, disparity: FloatMap, lens: LensParameters,
                                       lowLongSide: Int, quality: RenderQuality = .preview,
                                       refinePasses: Int = 1, temporal: TemporalState? = nil,
                                       subject: SubjectHint? = nil) -> PlanarImage {
        let scale = Float(lowLongSide) / Float(full.longSide)
        if scale >= 0.95 {
            let luma = full.perceptualLuma()
            var d = DepthRefiner.refine(disparity: disparity, guide: full, passes: refinePasses, guideLuma: luma)
            if let t = temporal { d = t.prepare(luma: luma.values, disparity: d) }
            if let sh = subject {
                d = SubjectMatte.apply(disparity: d, image: full, focusDisparity: lens.focusDisparity,
                                       focusPoint: sh.point, parameters: sh.parameters,
                                         scale: lens.relativeScale, personMask: sh.personMask).0
            }
            return render(image: full, disparity: d, lens: lens, quality: quality, temporal: temporal)
        }
        stageTimings.removeAll(keepingCapacity: true)
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let t = DispatchTime.now().uptimeNanoseconds
            stageTimings.append((name, Double(t - mark) / 1e6))
            mark = t
        }
        let W = full.width, H = full.height
        let low = Self.downsample(full, longSide: lowLongSide)
        let lw = low.width, lh = low.height
        let lowLuma = low.perceptualLuma()
        lap("缩小")
        var dLow = DepthRefiner.refine(disparity: disparity, guide: low, passes: refinePasses, guideLuma: lowLuma)
        lap("深度对齐")
        if let t = temporal { dLow = t.prepare(luma: lowLuma.values, disparity: dLow) }
        lap("时间稳定")
        var matte: FloatMap?
        if let sh = subject {
            let res = SubjectMatte.apply(disparity: dLow, image: low, focusDisparity: lens.focusDisparity,
                                         focusPoint: sh.point, parameters: sh.parameters,
                                         scale: lens.relativeScale, personMask: sh.personMask)
            dLow = res.0; matte = res.1
        }
        lap("主体遮罩")
        var bokeh = render(image: low, disparity: dLow, lens: lens, quality: quality, temporal: temporal)
        lap("虚化")
        stageTimings += renderTimings.map { ("虚化." + $0.0, $0.1) }

        // 低分辨率上的虚化程度 w
        let Ll = low.longSide
        var w = [Float](repeating: 0, count: lw * lh)
        for i in 0..<(lw * lh) {
            let r = abs(lens.signedBlurRadius(disparity: dLow.values[i], imageLongSide: Ll))
            let own = Self.smoothstep(0.25, 0.9, r)
            let diff = max(abs(bokeh.r[i] - low.r[i]), max(abs(bokeh.g[i] - low.g[i]), abs(bokeh.b[i] - low.b[i])))
            let spill = Self.smoothstep(0.015, 0.06, diff)
            w[i] = max(own, spill)
        }
        // 焦外的时间平滑（实时预览）
        temporal?.stabilizeBokeh(&bokeh, defocus: w)
        lap("焦外稳定")
        if captureDebugMaps {
            debugWeights = FloatMap(width: lw, height: lh, values: w)
            debugLowDisparity = dLow
            debugMatte = matte
        }

        // 双线性插值表（像素中心对齐）
        func table(_ n: Int, _ ln: Int) -> (i0: [Int32], i1: [Int32], t: [Float]) {
            var i0 = [Int32](repeating: 0, count: n), i1 = [Int32](repeating: 0, count: n), t = [Float](repeating: 0, count: n)
            let s = Float(ln) / Float(n)
            for k in 0..<n {
                let f = min(max((Float(k) + 0.5) * s - 0.5, 0), Float(ln - 1))
                let a = Int(f)
                i0[k] = Int32(a); i1[k] = Int32(min(a + 1, ln - 1)); t[k] = f - Float(a)
            }
            return (i0, i1, t)
        }
        let tx = table(W, lw), ty = table(H, lh)

        var out = PlanarImage(width: W, height: H)
        // 一次遍历：插值 7 张低分辨率图并合成
        let srcs = [w, low.r, low.g, low.b, bokeh.r, bokeh.g, bokeh.b]
        srcs[0].withUnsafeBufferPointer { wP in
        srcs[1].withUnsafeBufferPointer { lrP in
        srcs[2].withUnsafeBufferPointer { lgP in
        srcs[3].withUnsafeBufferPointer { lbP in
        srcs[4].withUnsafeBufferPointer { brP in
        srcs[5].withUnsafeBufferPointer { bgP in
        srcs[6].withUnsafeBufferPointer { bbP in
        full.r.withUnsafeBufferPointer { frP in
        full.g.withUnsafeBufferPointer { fgP in
        full.b.withUnsafeBufferPointer { fbP in
        out.r.withUnsafeMutableBufferPointer { orP in
        out.g.withUnsafeMutableBufferPointer { ogP in
        out.b.withUnsafeMutableBufferPointer { obP in
        tx.i0.withUnsafeBufferPointer { x0P in
        tx.i1.withUnsafeBufferPointer { x1P in
        tx.t.withUnsafeBufferPointer { txP in
            let Wt = wP.baseAddress!, LR = lrP.baseAddress!, LG = lgP.baseAddress!, LB = lbP.baseAddress!
            let BR = brP.baseAddress!, BG = bgP.baseAddress!, BB = bbP.baseAddress!
            let FR = frP.baseAddress!, FG = fgP.baseAddress!, FB = fbP.baseAddress!
            let OR = orP.baseAddress!, OG = ogP.baseAddress!, OB = obP.baseAddress!
            let X0 = x0P.baseAddress!, X1 = x1P.baseAddress!, TX = txP.baseAddress!
            parallelFor(H) { y in
                let r0 = Int(ty.i0[y]) * lw, r1 = Int(ty.i1[y]) * lw, fy = ty.t[y]
                @inline(__always) func bil(_ P: UnsafePointer<Float>, _ a: Int, _ b: Int, _ fx: Float) -> Float {
                    let top = P[r0 + a] + (P[r0 + b] - P[r0 + a]) * fx
                    let bot = P[r1 + a] + (P[r1 + b] - P[r1 + a]) * fx
                    return top + (bot - top) * fy
                }
                for x in 0..<W {
                    let a = Int(X0[x]), b = Int(X1[x]), fx = TX[x]
                    let keep = 1 - bil(Wt, a, b, fx)
                    let i = y * W + x
                    OR[i] = bil(BR, a, b, fx) + keep * (FR[i] - bil(LR, a, b, fx))
                    OG[i] = bil(BG, a, b, fx) + keep * (FG[i] - bil(LG, a, b, fx))
                    OB[i] = bil(BB, a, b, fx) + keep * (FB[i] - bil(LB, a, b, fx))
                }
            }
        }}}}}}}}}}}}}}}}
        lap("合成")
        return out
    }

    /// 缩小到指定长边：整数倍时用盒式平均（快），否则用通用缩放
    static func downsample(_ img: PlanarImage, longSide: Int) -> PlanarImage {
        let k = img.longSide / max(1, longSide)
        if k >= 2 && img.longSide % longSide == 0 && img.width % k == 0 && img.height % k == 0 {
            let lw = img.width / k, lh = img.height / k
            var out = PlanarImage(width: lw, height: lh)
            let inv = 1 / Float(k * k)
            let W = img.width
            func box(_ src: [Float]) -> [Float] {
                var dst = [Float](repeating: 0, count: lw * lh)
                src.withUnsafeBufferPointer { sp in
                dst.withUnsafeMutableBufferPointer { dp in
                    let S = sp.baseAddress!, D = dp.baseAddress!
                    parallelFor(lh) { y in
                        for x in 0..<lw {
                            var s: Float = 0
                            for yy in 0..<k {
                                let row = (y * k + yy) * W + x * k
                                for xx in 0..<k { s += S[row + xx] }
                            }
                            D[y * lw + x] = s * inv
                        }
                    }
                }}
                return dst
            }
            out.r = box(img.r); out.g = box(img.g); out.b = box(img.b)
            return out
        }
        let s = Float(longSide) / Float(img.longSide)
        return img.resized(width: max(1, Int((Float(img.width) * s).rounded())),
                           height: max(1, Int((Float(img.height) * s).rounded())))
    }
}
