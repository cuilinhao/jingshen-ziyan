import Foundation

/// 用照片的 HDR 增益图分辨「过曝的灯」和「过曝的白色表面」，后者不做焦外高光提亮（录屏 0.5x-baoguang）。
///
/// 焦外高光提亮只看照片（SDR）里的亮度：最亮通道到了门限、又比周围亮很多，就当成灯提亮成光斑。可照片一旦把白色表面
/// 压到 255，它在 SDR 里就和一盏灯一模一样。iPhone 16 Pro 超广角的照片把被顶灯照亮的白色收纳盒顶边、盒子边、
/// 白盒子、桌面反光都压到了 255（同一个场景 17 Pro Max 基本只有灯管到 255），提亮以后成片里就是一条条过曝的亮边，
/// 门限调多高都没用。
///
/// 照片文件里带的 HDR 增益图（每个像素在 HDR 里比 SDR 再亮多少）还记着真实亮度。实测（photo-20261103-160822 /
/// photo-20261103-161021，两台手机同一个场景）：灯管过曝像素的增益图 p10 ≥ 245/255；过曝的收纳盒、盒子边、白盒子、
/// 桌面反光 p90 ≤ 198/255。所以照片里过曝、增益图又不高的地方不是光源，和人身上一样不提亮（SubjectSeeds.people）
public enum HDRHighlights {
    /// 增益图（0…1）在这个区间里从「不是光源」过渡到「是光源」（217 → 240 / 255，两边离实测值都有 20 左右的余量）
    public static let lightGainLow: Float = 0.85
    public static let lightGainHigh: Float = 0.94

    /// 不做焦外高光提亮的亮区（0…1，width × height，一般是深度图的分辨率）：落在每一格里、最亮通道 ≥ threshold
    /// （高光提亮的门限）的照片像素里，增益图说「不是光源」的比例；没有这么亮的像素的格子是 0。
    /// 再往外扩 1 格：提亮在更高的分辨率上算，格子边上的亮像素也要盖住。
    /// gainMap 要和 image 同一个画面、同一个方向（分辨率可以不同；方向不确定时先用 align 对齐）。
    ///
    /// 增益图先往外扩约 0.1% 长边（取最大）：它只有照片一半的分辨率，灯管边上照片还是 255、增益图已经掉到 200 左右
    /// （16 Pro 那张：灯管上 23751 个过曝像素里有约 1000 个在边上），不扩的话灯管的光斑边缘会被啃出锯齿
    public static func nonLightMask(image: PlanarImage, gainMap rawGain: FloatMap, threshold: Float,
                                    width: Int, height: Int) -> FloatMap {
        let gainMap = maxFiltered(rawGain, radius: max(2, max(rawGain.width, rawGain.height) / 1000))
        let W = image.width, H = image.height, gw = gainMap.width, gh = gainMap.height
        let n = width * height
        guard W > 0, H > 0, gw > 0, gh > 0, n > 0 else { return FloatMap(width: max(1, width), height: max(1, height)) }
        var acc = [Float](repeating: 0, count: n)
        var cnt = [Float](repeating: 0, count: n)
        image.r.withUnsafeBufferPointer { R in image.g.withUnsafeBufferPointer { G in image.b.withUnsafeBufferPointer { B in
        gainMap.values.withUnsafeBufferPointer { GM in
            for y in 0..<H {
                let oy = min(height - 1, y * height / H) * width
                let gy = min(gh - 1, y * gh / H) * gw
                let row = y * W
                for x in 0..<W {
                    let i = row + x
                    let m = max(R[i], max(G[i], B[i]))
                    if m < threshold { continue }
                    let g = GM[gy + min(gw - 1, x * gw / W)]
                    let o = oy + min(width - 1, x * width / W)
                    acc[o] += 1 - BokehRenderer.smoothstep(lightGainLow, lightGainHigh, g)
                    cnt[o] += 1
                }
            }
        }}}}
        var mask = [Float](repeating: 0, count: n)
        for i in 0..<n where cnt[i] > 0 { mask[i] = acc[i] / cnt[i] }
        var out = mask
        for y in 0..<height {
            for x in 0..<width {
                var v: Float = 0
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) { v = max(v, mask[yy * width + xx]) }
                }
                out[y * width + x] = v
            }
        }
        return FloatMap(width: width, height: height, values: out)
    }

    /// 增益图转到和 image 一样的方向。照片文件里的辅助图不一定和 AVCapturePhoto.cgImageRepresentation 是同一个像素方向
    /// （HEIF 的旋转属性可能只挂在主图上）。增益图和画面亮度高度相关（亮的地方增益也高），
    /// 在 48 像素宽的小图上把宽高比对得上的方向都试一遍，取相关系数最高的那个
    public static func align(_ gain: FloatMap, to image: PlanarImage) -> FloatMap {
        let sw = 48, sh = max(2, Int((Float(48 * image.height) / Float(max(1, image.width))).rounded()))
        let small = image.resized(width: sw, height: sh)
        var luma = [Float](repeating: 0, count: sw * sh)
        for i in 0..<luma.count { luma[i] = max(small.r[i], max(small.g[i], small.b[i])) }
        let landscape = image.width >= image.height
        var best = gain
        var bestScore = -Float.infinity
        for candidate in [gain, rotated180(gain), rotated90(gain, clockwise: true), rotated90(gain, clockwise: false)]
            where (candidate.width >= candidate.height) == landscape {
            let score = correlation(luma, candidate.resized(width: sw, height: sh).values)
            if score > bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    /// 方形窗口取最大（先横后竖，各 2·radius + 1）
    static func maxFiltered(_ m: FloatMap, radius r: Int) -> FloatMap {
        let w = m.width, h = m.height
        guard r > 0, w > 0, h > 0 else { return m }
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v = -Float.infinity
                for xx in max(0, x - r)...min(w - 1, x + r) { v = max(v, m.values[y * w + xx]) }
                tmp[y * w + x] = v
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v = -Float.infinity
                for yy in max(0, y - r)...min(h - 1, y + r) { v = max(v, tmp[yy * w + x]) }
                out[y * w + x] = v
            }
        }
        return FloatMap(width: w, height: h, values: out)
    }

    static func rotated180(_ m: FloatMap) -> FloatMap {
        FloatMap(width: m.width, height: m.height, values: m.values.reversed())
    }

    /// 顺时针（clockwise）或逆时针转 90°
    static func rotated90(_ m: FloatMap, clockwise: Bool) -> FloatMap {
        let w = m.width, h = m.height
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                // 新图宽 h、高 w。顺时针：(x, y) → (h − 1 − y, x)；逆时针：(x, y) → (y, w − 1 − x)
                let (nx, ny) = clockwise ? (h - 1 - y, x) : (y, w - 1 - x)
                out[ny * h + nx] = m.values[y * w + x]
            }
        }
        return FloatMap(width: h, height: w, values: out)
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(min(a.count, b.count))
        guard n > 1 else { return 0 }
        var ma: Float = 0, mb: Float = 0
        for i in 0..<Int(n) { ma += a[i]; mb += b[i] }
        ma /= n; mb /= n
        var sab: Float = 0, saa: Float = 0, sbb: Float = 0
        for i in 0..<Int(n) {
            let da = a[i] - ma, db = b[i] - mb
            sab += da * db; saa += da * da; sbb += db * db
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }

    /// 两张遮罩逐像素取最大（尺寸不同时 b 先缩放到 a 的尺寸）
    public static func maxMerge(_ a: FloatMap?, _ b: FloatMap) -> FloatMap {
        guard let a else { return b }
        let bb = b.width == a.width && b.height == a.height ? b : b.resized(width: a.width, height: a.height)
        return FloatMap(width: a.width, height: a.height, values: zip(a.values, bb.values).map { max($0, $1) })
    }
}
