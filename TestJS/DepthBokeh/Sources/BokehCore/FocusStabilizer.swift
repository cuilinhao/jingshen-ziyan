import Foundation

/// 实时预览的对焦稳定器。
///
/// 对焦点固定在屏幕上的一个位置，每帧重新测那里的视差。主体稍微一动、手一抖，
/// 那个点就可能落到主体旁边的背景上，对焦面瞬间跳到几米外，主体整个糊掉，
/// 过一会儿又跳回来（实测人像片段里一次闪 1 秒多）。
///
/// 处理方式：
///  1. 点按位置的视差和当前锁定的深度差不多（±15%）：正常更新
///  2. 突然变远了（主体滑出这个点、露出后面的背景）：先在周围更大的窗口里找原来那个深度。
///     只要还占窗口的 10% 以上，就认为主体还在旁边，继续对焦在它上面（最多坚持 `maxHold` 秒）
///  3. 突然变近了（有东西挡到前面、新主体移进来）：只坚持 `nearHold` 秒就换焦。
///     实测楼梯扶手移回对焦点时，如果也坚持 1.5 秒，扶手会糊 1.5 秒
///  4. 找不到，或者新深度已经持续超过上面的时间：认为确实换了对象，接受新深度
/// 输出之后再做时间平滑（`smoothingTime`），换焦时是一个平滑的拉焦过程，而不是跳变。
public struct FocusStabilizer {
    public var smallWindow: Float = 0.03
    public var searchWindow: Float = 0.10
    public var relativeTolerance: Float = 0.15
    public var minShare: Float = 0.10
    /// 找不到原深度时，原地保持多久（秒）
    public var briefHold: Double = 0.3
    /// 点按位置变远时（主体滑出去），最多继续跟原来的主体多久（秒）
    public var maxHold: Double = 1.5
    /// 点按位置变近时（前面有新东西），最多坚持多久（秒）
    public var nearHold: Double = 0.3
    /// 换焦动画的时间常数（秒）
    public var smoothingTime: Double = 0.12
    /// 手机正在移动（上下左右扫）：这时对焦点下面换了东西是因为镜头在动，而不是主体滑出去，
    /// 变远时也只坚持 `nearHold`，否则扫过去时虚化要过 1.5 秒才跟上，看起来像延迟
    public var cameraMoving = false

    private var anchor: Float?
    private var diverged: Double = 0
    private var smoothed: Float?

    public init() {}

    /// 点按了新位置：忘掉之前锁定的深度（但保留平滑值，换焦依然是平滑过渡）
    public mutating func reset() {
        anchor = nil
        diverged = 0
    }

    /// - Parameters:
    ///   - map: 视差图（可以含 NaN / 0）
    ///   - nx, ny: 对焦点归一化坐标
    ///   - dt: 距上一帧的秒数
    /// - Returns: 平滑后的对焦视差
    public mutating func update(map: FloatMap, nx: Float, ny: Float, dt: Double) -> Float {
        let target = stabilizedTarget(map: map, nx: nx, ny: ny, dt: dt)
        guard let s = smoothed else { smoothed = target; return target }
        let a = Float(1 - exp(-max(0, dt) / max(1e-3, smoothingTime)))
        let v = s + (target - s) * a
        smoothed = v
        return v
    }

    /// 不带时间平滑的目标视差
    public mutating func stabilizedTarget(map: FloatMap, nx: Float, ny: Float, dt: Double) -> Float {
        var center = Self.samples(map, nx, ny, smallWindow)
        let c: Float
        if center.isEmpty {
            c = anchor ?? 1
        } else {
            center.sort()
            c = center[center.count / 2]
        }
        guard let a = anchor, abs(c - a) > relativeTolerance * a else {
            anchor = c
            diverged = 0
            return c
        }
        diverged += dt
        let hold = c > a || cameraMoving ? nearHold : maxHold
        if diverged < hold {
            let around = Self.samples(map, nx, ny, searchWindow)
            var near = around.filter { abs($0 - a) <= relativeTolerance * a }
            if !around.isEmpty && Float(near.count) >= minShare * Float(around.count) {
                near.sort()
                let m = near[near.count / 2]
                anchor = m
                return m
            }
            if diverged < briefHold { return a }
        }
        anchor = c
        diverged = 0
        return c
    }

    static func samples(_ map: FloatMap, _ nx: Float, _ ny: Float, _ fraction: Float) -> [Float] {
        let cx = min(map.width - 1, max(0, Int(nx * Float(map.width))))
        let cy = min(map.height - 1, max(0, Int(ny * Float(map.height))))
        let r = max(1, Int(Float(max(map.width, map.height)) * fraction))
        var out: [Float] = []
        out.reserveCapacity((2 * r + 1) * (2 * r + 1))
        for y in max(0, cy - r)...min(map.height - 1, cy + r) {
            for x in max(0, cx - r)...min(map.width - 1, cx + r) {
                let v = map[x, y]
                if v.isFinite && v > 0 { out.append(v) }
            }
        }
        return out
    }
}
