import Foundation

/// 实时预览的跨帧状态：让静止的画面在相邻帧之间保持稳定。
///
/// 实测（手机不动的 3 秒里）闪烁集中在两类地方：
///  - 深度边缘：深度流每帧的噪声让边缘处的模糊半径来回变，轮廓「呼吸」
///  - 焦外光斑：亮点在高光阈值附近的噪声被提亮倍数放大，光斑一闪一闪
/// 处理：在低分辨率上，把这一帧细化后的视差和高光提亮系数，向上一帧的值靠一部分。
/// 靠多少由这个像素的亮度变化决定 —— 画面没变（静止）就多沿用上一帧，
/// 画面变了（物体移动、手机移动）就完全用新值，所以运动时不会拖影。
public final class TemporalState {
    /// 画面完全静止的像素沿用上一帧的比例（0 = 关闭）
    public var strength: Float = 0.6
    /// 亮度（sRGB 0...1）变化的尺度：变化达到它时沿用比例降到 e⁻¹ 倍左右
    public var sigma: Float = 0.025

    var width = 0, height = 0
    var luma: [Float] = []
    var disparity: [Float] = []
    var boost: [Float] = []
    /// 当前帧每个像素沿用上一帧的比例（由 prepare 算出，render 里给高光用）
    var blend: [Float] = []

    public init() {}

    public func reset() {
        width = 0; height = 0
        luma = []; disparity = []; boost = []; blend = []
    }

    /// 根据这一帧的亮度算出 blend，并把视差向上一帧靠拢。返回稳定后的视差
    func prepare(luma now: [Float], disparity d: FloatMap) -> FloatMap {
        let n = d.width * d.height
        guard strength > 0, width == d.width, height == d.height, luma.count == n, disparity.count == n else {
            width = d.width; height = d.height
            blend = [Float](repeating: 0, count: n)
            luma = now; disparity = d.values; boost = []
            return d
        }
        // 3×3 平均后的亮度差，避免单像素噪声
        let w = d.width, h = d.height
        var diff = [Float](repeating: 0, count: n)
        for i in 0..<n { diff[i] = abs(now[i] - luma[i]) }
        let dm = BoxFilter.mean(diff, width: w, height: h, radius: 1)
        var out = d.values
        let s = strength, inv = 1 / sigma
        for i in 0..<n {
            let x = dm[i] * inv
            let b = s * expf(-x * x)
            blend[i] = b
            out[i] += b * (disparity[i] - out[i])
        }
        luma = now
        disparity = out
        return FloatMap(width: w, height: h, values: out)
    }

    /// 高光提亮系数的时间稳定（在 render 里调用）
    func stabilizeBoost(_ b: inout [Float]) {
        if boost.count == b.count && blend.count == b.count {
            for i in 0..<b.count { b[i] += blend[i] * (boost[i] - b[i]) }
        }
        boost = b
    }
}
