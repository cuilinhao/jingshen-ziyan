import Foundation

/// 一支「虚拟镜头」：把 ƒ 值和对焦距离换算成每个像素的模糊半径。
///
/// 两种模型：
///
/// 1. `.system`（默认）—— 按系统相机实测标定的「相对离焦」模型（和 DepthBokehCamera 工程一致）：
///
///        rel = d / d_f − 1            （d 是视差 1/z；背景在无穷远时 rel = −1，前景 rel > 0）
///        r   = max(|rel| − 死区, 0) × (前景 ? 0.8 : 1) × blurK / ƒ × 长边
///
///    blurK = 0.015：DepthBokehCamera 2 按系统相机标定的是 0.012（ƒ1.4、主体 1.5 m、背景 6 m 时背景模糊半径
///    约为长边的 0.55%）；对比你录的系统相机预览（拳头 0.46 m、ƒ1.4，远处灯的光斑半径约为长边的 1%）和
///    S02–S07 的系统人像照片，0.012 偏弱，取 0.015（那个工程 README 里「更奶油」的推荐值）。
///    模糊量只和「相对距离」有关，不随对焦距离变化，所以拳头拿近时背景不会糊得比系统多几倍。
///
/// 2. `.thinLens` —— 薄透镜物理公式：c ≈ (f² / N) · |1/z − 1/z_f|。
///    对焦越近、模糊越大，同样的 ƒ 值下比系统强得多（实测拳头 0.46 m 时是系统的 4 倍左右）。
public struct LensParameters: Equatable {
    public enum Model: Equatable { case system, thinLens }

    /// 模拟的光圈值（ƒ1.4 ... ƒ16）
    public var fNumber: Float
    /// 对焦平面的视差（1/米）。通常由点击位置的视差决定
    public var focusDisparity: Float
    /// 模糊模型
    public var model: Model
    /// `.thinLens`：模拟镜头的 35mm 等效焦距（毫米）
    public var focalLength35mm: Float
    /// 最大模糊半径（占图像长边的比例）。系统模型默认 1.4%（和系统相机一致）
    public var maxBlurFraction: Float
    /// 对焦面前后的「全清晰区」（相对距离），0.06 = 对焦距离的 ±6% 内完全清晰
    public var focusTolerance: Float
    /// `.system`：ƒ1 时背景在无穷远的模糊半径（占长边的比例）。默认 0.015
    public var blurK: Float
    /// `.system`：前景模糊相对背景的比例（系统相机前景更柔和）
    public var foregroundScale: Float
    /// `.system`：|rel| 超过这个值后不再增大（极近的前景）
    public var maxRelative: Float
    /// `.thinLens`：软上限（ƒ4.5 时占长边的比例，随 ƒ 反比变化），0 = 关闭
    public var softLimitFraction: Float
    /// `.system`：相对距离的分母。nil = 对焦视差本身（LiDAR / 双摄的绝对视差：rel = d/d_f − 1）。
    /// AI 单目深度只有相对值（未知的比例和偏移），对焦在远处时 d_f 接近 0，rel 会被放得很大，
    /// 所以用 max(d_f, 0.25 × (近端 − 远端)) 当分母（和 DepthBokehCamera 2 一样）
    public var relativeScale: Float?

    public init(fNumber: Float = 2.8, focusDisparity: Float = 1, model: Model = .system,
                focalLength35mm: Float = 52, maxBlurFraction: Float? = nil, focusTolerance: Float = 0.06,
                blurK: Float = 0.015, foregroundScale: Float = 0.8, maxRelative: Float = 1.6,
                softLimitFraction: Float = 0.012, relativeScale: Float? = nil) {
        self.fNumber = fNumber
        self.focusDisparity = focusDisparity
        self.model = model
        self.focalLength35mm = focalLength35mm
        self.maxBlurFraction = maxBlurFraction ?? (model == .system ? 0.014 : 0.04)
        self.focusTolerance = focusTolerance
        self.blurK = blurK
        self.foregroundScale = foregroundScale
        self.maxRelative = maxRelative
        self.softLimitFraction = softLimitFraction
        self.relativeScale = relativeScale
    }

    /// 相对对焦面的距离：(d − d_f) / 分母。正数 = 前景，−1 = 无穷远（绝对视差时）
    @inline(__always)
    public func relativeDistance(_ d: Float) -> Float {
        (d - focusDisparity) / max(relativeScale ?? focusDisparity, 1e-3)
    }

    /// 带符号的模糊半径（像素）。正数 = 在对焦面前方（前景），负数 = 后方（背景）
    @inline(__always)
    public func signedBlurRadius(disparity d: Float, imageLongSide L: Int) -> Float {
        let maxR = maxBlurFraction * Float(L)
        switch model {
        case .system:
            let rel = relativeDistance(d)
            var mag = min(max(abs(rel) - focusTolerance, 0), maxRelative)
            if rel > 0 { mag *= foregroundScale }
            let r = mag * blurK / max(fNumber, 1) * Float(L)
            return rel > 0 ? min(r, maxR) : -min(r, maxR)
        case .thinLens:
            // 等效全画幅 36mm 宽的底片上的弥散圆直径（毫米）；视差单位 1/m -> 1/mm 要除以 1000
            let f = focalLength35mm
            var delta = d - focusDisparity
            let tol = focusTolerance * focusDisparity
            delta = delta > 0 ? max(0, delta - tol) : min(0, delta + tol)
            let diameterMM = f * f / fNumber * delta / 1000
            var radiusPx = 0.5 * diameterMM / 36 * Float(L)
            if softLimitFraction > 0 {
                let rSat = softLimitFraction * Float(L) * 4.5 / max(fNumber, 0.5)
                let x = radiusPx / rSat
                radiusPx /= cbrtf(1 + abs(x * x * x))
            }
            return min(max(radiusPx, -maxR), maxR)
        }
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
    /// 平滑的高光提亮（预览不闪）。false = 旧算法（硬门限）
    public var smoothHighlights: Bool

    public init(layersPerSide: Int = 8, highlightThreshold: Float = 0.6, highlightGain: Float = 2.5,
                smoothHighlights: Bool = true) {
        self.layersPerSide = layersPerSide
        self.highlightThreshold = highlightThreshold
        self.highlightGain = highlightGain
        self.smoothHighlights = smoothHighlights
    }

    /// 旧的高光参数（硬门限 0.9、4 倍），只用于对比测试
    public mutating func useLegacyHighlights() {
        highlightThreshold = 0.9; highlightGain = 4; smoothHighlights = false
    }

    /// 实时预览：层数少一些换速度；高光提亮更克制（预览里灯管、筒灯的亮度会随卷帘条纹和曝光起伏，
    /// 提亮越狠，闪得越明显）
    public static let preview = RenderQuality(layersPerSide: 5, highlightThreshold: 0.75, highlightGain: 1.5)
    /// 拍照成片
    public static let photo = RenderQuality(layersPerSide: 9, highlightThreshold: 0.6, highlightGain: 2.5)
}
