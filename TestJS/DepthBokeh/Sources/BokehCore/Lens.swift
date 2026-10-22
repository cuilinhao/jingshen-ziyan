import Foundation

/// 一支「虚拟镜头」：把 ƒ 值和对焦距离换算成每个像素的模糊半径。
///
/// 两种模型：
///
/// 1. `.system`（默认）—— 按系统相机标定的「视差差」模型：
///
///        Δd = d − d_f                 （d 是视差 1/z，单位 1/米；前景 Δd > 0，背景 Δd < 0）
///        背景：g = 0.95 · tanh(1.6 · max(|Δd| − 0.04, 0) / 0.95)
///        前景：g = 1.2  · tanh(1.6 · max(Δd − 0.25, 0) / 1.2)
///        r = g × blurK / ƒ × 长边
///
///    和真实镜头一样，模糊只和视差差有关，不除以对焦视差：以前的「相对距离」(d − d_f) / d_f 在对焦远处时分母很小，
///    对焦后面的柜子时，前面一两米的人被虚化得很厉害；系统相机这时人几乎是清晰的，前面的杯子只是轻微虚化。
///    前面有一段 0.25（1/米）的全清晰区：系统人像照片里，对焦面前面视差差 0.3 以内的东西都是清晰的
///    （S02：对焦 2 m 的人，前面 1.6 m 以外的东西都清晰），后面没有这么宽。
///    视差差还不受双摄 / AI 相对视差里那个未知偏移的影响（实测双摄视差 ≈ 激光雷达视差 + 0.2…0.4）。
///    原始 blurK = 0.015 时，ƒ1.4、拳头 0.46 m、背景 3 m 的半径约为长边的 1%；
///    主体 1.5 m、背景 6 m 时约为 0.66%。当前默认强度统一由 defaultBlurK 配置，半径仍受 maxBlurFraction 限制。
///
/// 2. `.thinLens` —— 薄透镜物理公式：c ≈ (f² / N) · |1/z − 1/z_f|。
///    对焦越近、模糊越大；与原始 blurK = 0.015 的系统模型相比，实测拳头 0.46 m 时约为其 4 倍。
public struct LensParameters: Equatable {
    /// 默认景深虚化强度：调整预览和照片的虚化时，只需修改这里。
    //public static let defaultBlurK: Float = 0.015
    public static let defaultBlurK: Float = 0.015 + 0.003

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
    /// `.thinLens`：对焦面前后的「全清晰区」（相对距离），0.06 = 对焦距离的 ±6% 内完全清晰
    public var focusTolerance: Float
    /// `.system`：模糊强度（g = 1 时、ƒ1 的模糊半径占长边的比例）。默认使用 defaultBlurK
    public var blurK: Float
    /// `.system`：对焦面前面的全清晰区、斜率、上限（视差差，1/米）
    public var frontTolerance: Float
    public var frontSlope: Float
    public var frontMax: Float
    /// `.system`：对焦面后面的全清晰区、斜率、上限
    public var backTolerance: Float
    public var backSlope: Float
    public var backMax: Float
    /// `.thinLens`：软上限（ƒ4.5 时占长边的比例，随 ƒ 反比变化），0 = 关闭
    public var softLimitFraction: Float
    /// 「相对距离」(d − d_f) / 分母 的分母，主体遮罩用它判断「和对焦面差不多远」（SubjectMatte 的 band）。
    /// nil = 对焦视差本身（LiDAR）。双摄 / AI 深度只有相对值，用 max(d_f, 0.25 × (近端 − 远端))
    public var relativeScale: Float?

    
    /*
     这个问题先不改了，看下我现在测试出的一个问题
     在 4x 的情况下，
     第一个问题，当我拍摄距离镜头近的盒子的时候，发现盒子顶部有蒙层，不清楚，你可以对比下同一个手机，系统的景深效果（视频demo-1021.MP4，系统视频是xitong.MP4）

     第二个问题， 当我拍摄距离镜头远的人脸的时候，发现这个人佩戴的眼镜是有蒙层的，看下可以修复吗？（视频demo-1021.MP4）


     第三个问题，当我上下移动镜头的时候，怎么感觉拍摄画面有延迟？（第一次打开没问题，选择 4x 焦距，然后拍几张后，再上下移动就有延迟了）视频demo-kadun.MP4

     ---
     另外，你这次改动加了焦段调节，要自己使用2 核云主机上测试，发现问题，解决问题

     */
    public init(fNumber: Float = 2.8, focusDisparity: Float = 1, model: Model = .system,
                focalLength35mm: Float = 52, maxBlurFraction: Float? = nil, focusTolerance: Float = 0.06,
                blurK: Float = LensParameters.defaultBlurK, frontTolerance: Float = 0.25, frontSlope: Float = 1.6, frontMax: Float = 1.2,
                backTolerance: Float = 0.04, backSlope: Float = 1.6, backMax: Float = 0.95,
                softLimitFraction: Float = 0.012, relativeScale: Float? = nil) {
        self.fNumber = fNumber
        self.focusDisparity = focusDisparity
        self.model = model
        self.focalLength35mm = focalLength35mm
        self.maxBlurFraction = maxBlurFraction ?? (model == .system ? 0.014 : 0.04)
        self.focusTolerance = focusTolerance
        self.blurK = blurK
        self.frontTolerance = frontTolerance
        self.frontSlope = frontSlope
        self.frontMax = frontMax
        self.backTolerance = backTolerance
        self.backSlope = backSlope
        self.backMax = backMax
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
            let dd = d - focusDisparity
            let g: Float
            if dd > 0 {
                g = frontMax * tanhf(frontSlope * max(dd - frontTolerance, 0) / frontMax)
            } else {
                g = backMax * tanhf(backSlope * max(-dd - backTolerance, 0) / backMax)
            }
            let r = g * blurK / max(fNumber, 1) * Float(L)
            return dd > 0 ? min(r, maxR) : -min(r, maxR)
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
