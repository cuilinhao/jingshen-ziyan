import Foundation

/// 一支「虚拟镜头」：把 ƒ 值和对焦距离换算成每个像素的模糊半径。
///
/// 薄透镜模型：镜头焦距 f、光圈直径 A = f/N、对焦在距离 z_f，
/// 距离为 z 的点在底片上形成的弥散圆直径
///
///     c = A · f · |z - z_f| / (z · (z_f - f))  ≈  (f² / N) · |1/z - 1/z_f|
///
/// 1/z 就是视差（iPhone 的 disparity 单位正好是 1/米），
/// 所以模糊直径和「视差差值」成正比、和 ƒ 值成反比 —— 这就是 iPhone
/// 景深滑块背后的那条公式。
public struct LensParameters: Equatable {
    /// 模拟的光圈值（ƒ1.4 ... ƒ16）
    public var fNumber: Float
    /// 对焦平面的视差（1/米）。通常由点击位置的视差决定
    public var focusDisparity: Float
    /// 模拟镜头的「35mm 等效焦距」（毫米）。iPhone 人像 2× 约等于 48–52mm
    public var focalLength35mm: Float
    /// 最大模糊半径（占图像长边的比例），防止极端值把计算量拉爆
    public var maxBlurFraction: Float
    /// 对焦面前后的「全清晰区」，按对焦视差的比例算（0.08 ≈ 对焦距离的 ±8%）。
    /// 真实镜头在 ƒ2.8、1 米时景深只有 ±3 cm，人的身体会有一部分被虚化；
    /// 手机人像模式会让整个主体保持清晰，所以这里留出一段不虚化的深度范围
    public var focusTolerance: Float
    /// 模糊半径的「软上限」：ƒ4.5 时占图像长边的比例，随 ƒ 值反比变化（ƒ1.4 时约 3.9%）。
    /// 和系统人像照片逐块对比得到：深度差小的时候系统的模糊和薄透镜公式一致，
    /// 但对焦很近、背景很远时系统不会继续线性变大，而是在这个值附近饱和
    ///（ƒ4.5、长边 2016 时约 20–25 像素）。0 = 关闭，回到纯物理模型
    public var softLimitFraction: Float

    public init(fNumber: Float = 2.8, focusDisparity: Float = 1,
                focalLength35mm: Float = 52, maxBlurFraction: Float = 0.04, focusTolerance: Float = 0.08,
                softLimitFraction: Float = 0.012) {
        self.fNumber = fNumber
        self.focusDisparity = focusDisparity
        self.focalLength35mm = focalLength35mm
        self.maxBlurFraction = maxBlurFraction
        self.focusTolerance = focusTolerance
        self.softLimitFraction = softLimitFraction
    }

    /// 带符号的模糊半径（像素）。正数 = 在对焦面前方（前景），负数 = 后方（背景）
    @inline(__always)
    public func signedBlurRadius(disparity d: Float, imageLongSide L: Int) -> Float {
        // 等效全画幅 36mm 宽的底片上的弥散圆直径（毫米）；视差单位 1/m -> 1/mm 要除以 1000
        let f = focalLength35mm
        var delta = d - focusDisparity
        let tol = focusTolerance * focusDisparity
        delta = delta > 0 ? max(0, delta - tol) : min(0, delta + tol)
        let diameterMM = f * f / fNumber * delta / 1000
        // 映射到像素：图像长边对应 36mm
        var radiusPx = 0.5 * diameterMM / 36 * Float(L)
        if softLimitFraction > 0 {
            // 软饱和：r / ∛(1 + (r/r_sat)³)。小半径基本不变，大半径平滑地趋近 r_sat
            let rSat = softLimitFraction * Float(L) * 4.5 / max(fNumber, 0.5)
            let x = radiusPx / rSat
            radiusPx /= cbrtf(1 + abs(x * x * x))
        }
        let maxR = maxBlurFraction * Float(L)
        return min(max(radiusPx, -maxR), maxR)
    }
}

/// 渲染质量参数
public struct RenderQuality: Equatable {
    /// 对焦面每一侧切多少层（总层数 = 2 × layersPerSide + 1）
    public var layersPerSide: Int
    /// 高光阈值（线性光）。超过它的像素在焦外会被提亮，形成光斑
    public var highlightThreshold: Float
    /// 高光提亮倍数
    public var highlightGain: Float

    public init(layersPerSide: Int = 8, highlightThreshold: Float = 0.9, highlightGain: Float = 4) {
        self.layersPerSide = layersPerSide
        self.highlightThreshold = highlightThreshold
        self.highlightGain = highlightGain
    }

    /// 实时预览：层数少一些换速度
    public static let preview = RenderQuality(layersPerSide: 5)
    /// 拍照成片
    public static let photo = RenderQuality(layersPerSide: 9)
}
