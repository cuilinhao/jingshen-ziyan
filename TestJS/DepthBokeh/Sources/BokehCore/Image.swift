import Foundation

/// 平面存储的 RGB 浮点图像，数值是「线性光」（不是 sRGB 编码值）。
/// 景深模拟必须在线性光空间里做：真实镜头是把光能量摊开，
/// 在 sRGB 空间里平均会让高光变暗、焦外发灰。
public struct PlanarImage {
    public let width: Int
    public let height: Int
    public var r: [Float]
    public var g: [Float]
    public var b: [Float]

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        let n = width * height
        r = [Float](repeating: 0, count: n)
        g = [Float](repeating: 0, count: n)
        b = [Float](repeating: 0, count: n)
    }

    public init(width: Int, height: Int, r: [Float], g: [Float], b: [Float]) {
        precondition(r.count == width * height && g.count == r.count && b.count == r.count)
        self.width = width
        self.height = height
        self.r = r
        self.g = g
        self.b = b
    }

    public var pixelCount: Int { width * height }
    public var longSide: Int { max(width, height) }

    /// 每个像素的感知亮度（用作引导滤波的引导图），范围 0...1
    public func perceptualLuma() -> FloatMap {
        var out = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let y = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
            out[i] = SRGB.encodeFloat(y)
        }
        return FloatMap(width: width, height: height, values: out)
    }

    /// 双线性缩放（缩小时先做整数倍盒式降采样，避免锯齿）
    public func resized(width newW: Int, height newH: Int) -> PlanarImage {
        if newW == width && newH == height { return self }
        return PlanarImage(
            width: newW, height: newH,
            r: FloatMap(width: width, height: height, values: r).resized(width: newW, height: newH).values,
            g: FloatMap(width: width, height: height, values: g).resized(width: newW, height: newH).values,
            b: FloatMap(width: width, height: height, values: b).resized(width: newW, height: newH).values)
    }

    /// 中心裁切（同 FloatMap.centerCropped，三个通道分别做）
    public func centerCropped(by crop: Float, minSide: Int = 8) -> PlanarImage {
        let cr = FloatMap(width: width, height: height, values: r).centerCropped(by: crop, minSide: minSide)
        let cg = FloatMap(width: width, height: height, values: g).centerCropped(by: crop, minSide: minSide)
        let cb = FloatMap(width: width, height: height, values: b).centerCropped(by: crop, minSide: minSide)
        return PlanarImage(width: cr.width, height: cr.height, r: cr.values, g: cg.values, b: cb.values)
    }
}

/// 单通道浮点图（视差图、亮度图、遮罩等）
public struct FloatMap {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, repeating v: Float = 0) {
        self.init(width: width, height: height, values: [Float](repeating: v, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    /// 双线性采样，坐标是像素坐标（像素中心在 x + 0.5）
    @inline(__always) public func sampleBilinear(x: Float, y: Float) -> Float {
        let fx = min(max(x - 0.5, 0), Float(width - 1))
        let fy = min(max(y - 0.5, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let a = values[y0 * width + x0], b = values[y0 * width + x1]
        let c = values[y1 * width + x0], d = values[y1 * width + x1]
        return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
    }

    public func resized(width newW: Int, height newH: Int) -> FloatMap {
        if newW == width && newH == height { return self }
        // 缩小超过 2 倍时先盒式降采样
        let src = halvedToFit(width: newW, height: newH)
        var out = [Float](repeating: 0, count: newW * newH)
        let sx = Float(src.width) / Float(newW)
        let sy = Float(src.height) / Float(newH)
        out.withUnsafeMutableBufferPointer { op in
            let p = op.baseAddress!
            parallelFor(newH) { y in
                let fy = (Float(y) + 0.5) * sy
                for x in 0..<newW {
                    p[y * newW + x] = src.sampleBilinear(x: (Float(x) + 0.5) * sx, y: fy)
                }
            }
        }
        return FloatMap(width: newW, height: newH, values: out)
    }

    /// 中心裁切：取中间 1/crop 的区域，双线性重采样到约 原尺寸/crop（至少 minSide）。crop ≤ 1 原样返回。
    /// 变焦在两个能出深度的倍率之间时，相机停在较低的那个倍率，画面和深度图都按同样的比例从中间裁
    public func centerCropped(by crop: Float, minSide: Int = 8) -> FloatMap {
        guard crop.isFinite, crop > 1.0005, width > 1, height > 1 else { return self }
        let cw = Float(width) / crop, ch = Float(height) / crop
        let x0 = (Float(width) - cw) / 2, y0 = (Float(height) - ch) / 2
        let ow = max(minSide, Int(cw.rounded())), oh = max(minSide, Int(ch.rounded()))
        let sx = cw / Float(ow), sy = ch / Float(oh)
        var out = [Float](repeating: 0, count: ow * oh)
        for y in 0..<oh {
            let fy = y0 + (Float(y) + 0.5) * sy
            for x in 0..<ow {
                let fx = x0 + (Float(x) + 0.5) * sx
                var v = sampleBilinear(x: fx, y: fy)
                if !v.isFinite {
                    // 旁边有空洞（NaN）时退回最近邻，不让空洞变大
                    let xi = min(width - 1, max(0, Int(fx))), yi = min(height - 1, max(0, Int(fy)))
                    v = values[yi * width + xi]
                }
                out[y * ow + x] = v
            }
        }
        return FloatMap(width: ow, height: oh, values: out)
    }

    /// 第 lower / upper 百分位（跳过 NaN），在最多约 4096 个均匀采样点上统计
    public func percentiles(_ lower: Float, _ upper: Float) -> (low: Float, high: Float)? {
        let step = max(1, values.count / 4096)
        var sample: [Float] = []
        sample.reserveCapacity(values.count / step + 1)
        var i = 0
        while i < values.count {
            if values[i].isFinite { sample.append(values[i]) }
            i += step
        }
        guard sample.count >= 16 else { return nil }
        sample.sort()
        let lo = sample[min(sample.count - 1, Int(Float(sample.count) * lower))]
        let hi = sample[min(sample.count - 1, Int(Float(sample.count) * upper))]
        return (lo, hi)
    }

    /// `resized` 的第一步：目标尺寸不到一半时先反复 2×2 盒式缩小（GPU 版在 CPU 上先做这一步，再在 GPU 上双线性缩放）
    public func halvedToFit(width newW: Int, height newH: Int) -> FloatMap {
        var src = self
        while src.width >= newW * 2 && src.height >= newH * 2 {
            src = src.halved()
        }
        return src
    }

    func halved() -> FloatMap {
        let w2 = width / 2, h2 = height / 2
        var out = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h2 {
            for x in 0..<w2 {
                let i = (2 * y) * width + 2 * x
                out[y * w2 + x] = 0.25 * (values[i] + values[i + 1] + values[i + width] + values[i + width + 1])
            }
        }
        return FloatMap(width: w2, height: h2, values: out)
    }
}

/// sRGB <-> 线性光转换（查表实现）
public enum SRGB {
    /// 8 位 sRGB 值 -> 线性光
    public static let decodeLUT: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static let encodeLUTSize = 4096
    private static let encodeLUT: [UInt8] = (0..<4096).map { i in
        let l = Float(i) / Float(4095)
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (c * 255).rounded())))
    }

    /// 线性光 -> 8 位 sRGB
    @inline(__always) public static func encode(_ linear: Float) -> UInt8 {
        let v = min(max(linear, 0), 1)
        return encodeLUT[Int(v * Float(encodeLUTSize - 1) + 0.5)]
    }

    @inline(__always) public static func encodeFloat(_ linear: Float) -> Float {
        let l = min(max(linear, 0), 1)
        return l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
    }
}

/// 交错存储的 8 位像素的通道顺序
public enum InterleavedLayout {
    case rgba, bgra, rgb

    var bytesPerPixel: Int { self == .rgb ? 3 : 4 }
    var offsets: (r: Int, g: Int, b: Int) {
        switch self {
        case .rgba, .rgb: return (0, 1, 2)
        case .bgra: return (2, 1, 0)
        }
    }
}

extension PlanarImage {
    /// 从 8 位交错像素（例如相机的 BGRA CVPixelBuffer）构建线性光图像。
    /// `downsample` 为整数倍降采样（实时预览时用来把 1920/4032 宽的帧缩到 480 宽）。
    /// 每个输出像素在对应的 s×s 块里最多取 `maxSamplesPerAxis`² 个样本平均，
    /// 对大图降采样时不必读完所有源像素。
    public init(interleaved8 base: UnsafeRawPointer, width srcW: Int, height srcH: Int,
                bytesPerRow: Int, layout: InterleavedLayout, downsample: Int = 1,
                maxSamplesPerAxis: Int = 4) {
        let s = max(1, downsample)
        let w = srcW / s, h = srcH / s
        self.init(width: w, height: h)
        let lut = SRGB.decodeLUT
        let bpp = layout.bytesPerPixel
        let (or, og, ob) = layout.offsets
        let k = max(1, min(s, maxSamplesPerAxis))
        // 块内均匀分布的采样偏移
        let offsets = (0..<k).map { (2 * $0 + 1) * s / (2 * k) }
        let inv = 1 / Float(k * k)
        let src = base.assumingMemoryBound(to: UInt8.self)
        r.withUnsafeMutableBufferPointer { rp in
        g.withUnsafeMutableBufferPointer { gp in
        b.withUnsafeMutableBufferPointer { bp in
        lut.withUnsafeBufferPointer { lp in
            let R = rp.baseAddress!, G = gp.baseAddress!, B = bp.baseAddress!, L = lp.baseAddress!
            parallelFor(h) { y in
                for x in 0..<w {
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0
                    for yy in offsets {
                        let row = src + (y * s + yy) * bytesPerRow
                        for xx in offsets {
                            let p = row + (x * s + xx) * bpp
                            sr += L[Int(p[or])]
                            sg += L[Int(p[og])]
                            sb += L[Int(p[ob])]
                        }
                    }
                    let i = y * w + x
                    R[i] = sr * inv; G[i] = sg * inv; B[i] = sb * inv
                }
            }
        }}}}
    }

    /// 从 8 位交错像素缩放到任意尺寸（不要求整数倍）。
    /// 每个输出像素在它覆盖的源区域里取 2×2 个样本平均，缩小 1–3 倍时不会有明显锯齿。
    /// `sourceRect`（源像素坐标 x, y, 宽, 高）只取其中一块，用于数码变焦的中心裁切；nil = 整张
    public init(interleaved8 base: UnsafeRawPointer, width srcW: Int, height srcH: Int,
                bytesPerRow: Int, layout: InterleavedLayout, outputWidth w: Int, outputHeight h: Int,
                sourceRect: (x: Float, y: Float, width: Float, height: Float)? = nil) {
        self.init(width: w, height: h)
        let lut = SRGB.decodeLUT
        let bpp = layout.bytesPerPixel
        let (or, og, ob) = layout.offsets
        let rect = sourceRect ?? (0, 0, Float(srcW), Float(srcH))
        let sx = rect.width / Float(w), sy = rect.height / Float(h)
        let ox = rect.x, oy = rect.y
        // 每个输出像素的 2 个采样列 / 行（位于覆盖区域的 1/4 和 3/4 处）
        let xs: [Int] = (0..<(2 * w)).map { k in
            let x = k / 2, q: Float = k % 2 == 0 ? 0.25 : 0.75
            return min(srcW - 1, max(0, Int(ox + (Float(x) + q) * sx)))
        }
        let src = base.assumingMemoryBound(to: UInt8.self)
        r.withUnsafeMutableBufferPointer { rp in
        g.withUnsafeMutableBufferPointer { gp in
        b.withUnsafeMutableBufferPointer { bp in
        lut.withUnsafeBufferPointer { lp in
        xs.withUnsafeBufferPointer { xp in
            let R = rp.baseAddress!, G = gp.baseAddress!, B = bp.baseAddress!, L = lp.baseAddress!, XS = xp.baseAddress!
            parallelFor(h) { y in
                let y0 = min(srcH - 1, max(0, Int(oy + (Float(y) + 0.25) * sy)))
                let y1 = min(srcH - 1, max(0, Int(oy + (Float(y) + 0.75) * sy)))
                let row0 = src + y0 * bytesPerRow, row1 = src + y1 * bytesPerRow
                for x in 0..<w {
                    let a = XS[2 * x] * bpp, c = XS[2 * x + 1] * bpp
                    let i = y * w + x
                    R[i] = 0.25 * (L[Int(row0[a + or])] + L[Int(row0[c + or])] + L[Int(row1[a + or])] + L[Int(row1[c + or])])
                    G[i] = 0.25 * (L[Int(row0[a + og])] + L[Int(row0[c + og])] + L[Int(row1[a + og])] + L[Int(row1[c + og])])
                    B[i] = 0.25 * (L[Int(row0[a + ob])] + L[Int(row0[c + ob])] + L[Int(row1[a + ob])] + L[Int(row1[c + ob])])
                }
            }
        }}}}}
    }

    /// 相机帧（8 位交错）→ 线性光图像：从中间裁出 1/crop（数码变焦），缩放到长边不超过 longSide。
    /// 裁出来的那块本身比 longSide 小时不放大（界面再放大显示）。iOS 和电脑上的模拟测试共用这一份计算
    public static func cameraFrame(interleaved8 base: UnsafeRawPointer, width w: Int, height h: Int, bytesPerRow: Int,
                                   layout: InterleavedLayout, longSide: Int, crop: Float) -> PlanarImage {
        let c = crop.isFinite ? Double(max(1, crop)) : 1
        let cw = Double(w) / c, ch = Double(h) / c
        let s = min(1, Double(longSide) / max(cw, ch))
        let ow = max(1, Int((cw * s).rounded()))
        let oh = max(1, Int((ch * s).rounded()))
        let rect: (x: Float, y: Float, width: Float, height: Float)? = c > 1.0005
            ? (Float((Double(w) - cw) / 2), Float((Double(h) - ch) / 2), Float(cw), Float(ch)) : nil
        return PlanarImage(interleaved8: base, width: w, height: h, bytesPerRow: bytesPerRow,
                           layout: layout, outputWidth: ow, outputHeight: oh, sourceRect: rect)
    }

    /// 输出 8 位 RGBA（sRGB 编码，alpha = 255），可直接用来创建 CGImage
    public func interleavedRGBA8() -> [UInt8] {
        var out = [UInt8](repeating: 255, count: pixelCount * 4)
        let w = width
        out.withUnsafeMutableBufferPointer { op in
        r.withUnsafeBufferPointer { rp in
        g.withUnsafeBufferPointer { gp in
        b.withUnsafeBufferPointer { bp in
            let O = op.baseAddress!, R = rp.baseAddress!, G = gp.baseAddress!, B = bp.baseAddress!
            parallelFor(height) { y in
                for x in 0..<w {
                    let i = y * w + x
                    O[i * 4] = SRGB.encode(R[i])
                    O[i * 4 + 1] = SRGB.encode(G[i])
                    O[i * 4 + 2] = SRGB.encode(B[i])
                }
            }
        }}}}
        return out
    }
}
