import Foundation

/// 没经过系统滤波的深度流（长焦双摄，CameraController.usesSystemDepthFilter）在补洞之前的跨帧稳定。
///
/// 这条线路每一帧的视差是各自独立测出来的（调试录制 rec-20261110-181727，4.2×，ƒ1.4，对焦 1 m 左右的纸盒）：
///  - 40% 的像素没有数据，而且「有没有数据」每帧有 14% 的像素在翻转；洞是按这一帧四周有数据的像素补的
///    （DepthRefiner.fillInvalid(_:guide:)），支撑点一变，补出来的一大片（墙、显示器）跟着整片变；
///  - 有数据的像素自己相邻两帧也差 0.01～0.06；
///  - ImageBridge.disparityMap 给相对视差加的整体平移每帧按这一帧的 2% 分位现算：值正好是 0 的像素占 0.5%～4.5%，
///    在 2% 上下跳，平移量就在 0 和 0.02 之间跳（89 帧里 27 帧不是 0.02）。
/// 100mm、ƒ1.4 时镜头曲线很陡（视差差 0.01 ≈ 长边的 0.13%），这些全部变成虚化半径的逐帧变化：
/// 和对焦面差不多远的东西（隔板、显示器边）一会儿清楚一会儿糊，看上去像一层波纹在画面上跳。
/// 渲染里已有的跨帧稳定（TemporalState，沿用上一帧 60%）只有两三帧的记忆，压不住。
///
/// 做法（深度图分辨率，补洞之前）：
///  1. 这一帧和上一帧的小图比：整体平移多少（手抖）、哪里变了（东西在动）。历史跟着平移挪；变了的地方清掉历史；
///  2. 相对视差：这一帧和历史在都有数据的像素上差的中位数，就是这一帧多出来的整体平移，减掉（留 5%，真的整体变化会慢慢跟上）；
///  3. 每个像素记最近 `samples` 次测到的值，输出它们的中位数：一两帧的飞点直接被挡掉；
///     连着两次测到差不多的新值（`changeThreshold`）就算真的变了，马上跟上；
///  4. 这一帧没测到的像素沿用历史（最多 `maxHold` 张深度）：洞的形状不再每帧变，补洞的支撑点也就稳了。
/// 只在这一帧的洞不少（≥ `activateHoles`）时启用：系统滤波过的深度（LiDAR、主摄段双摄）没有洞，原样通过。
public final class DepthHistory {
    /// 每个像素记最近几次测到的值
    public var samples = 5
    /// 没测到时最多沿用多少张深度（30 张 ≈ 1 秒）
    public var maxHold = 30
    /// 洞占多少以上才启用 / 少于多少就停用（系统滤波过的深度没有洞）
    public var activateHoles: Float = 0.05
    public var deactivateHoles: Float = 0.005
    /// 整体平移的修正留多少不修（每帧）：真的整体变化按这个速度被历史吸收
    public var offsetLeak: Float = 0.05
    /// 连着两次测到的值都和历史差这么多（视差）、彼此又差不到一半：算深度真的变了，不等中位数慢慢跟上
    public var changeThreshold: Float = 0.04
    /// false = 关掉（测试对比用），深度原样通过
    public var enabled = true

    private var width = 0, height = 0
    /// width × height × samples；每个像素最近测到的值，新的在前，没有的是 NaN
    private var ring: [Float] = []
    /// 每个像素已经连续多少张深度没测到
    private var missing: [UInt8] = []
    private var previousColors: PlanarImage?
    /// 平移取整以后剩下的小数部分（累计，下一帧一起算）
    private var carry: (x: Float, y: Float) = (0, 0)
    private var lastOutput: FloatMap?
    public private(set) var active = false
    /// 最近一帧减掉的整体平移（测试用）
    public private(set) var lastOffset: Float = 0

    public init() {}

    public func reset() {
        width = 0; height = 0
        ring = []; missing = []
        previousColors = nil
        carry = (0, 0)
        lastOutput = nil
        active = false
        lastOffset = 0
    }

    /// - Parameters:
    ///   - map: 这一帧裁切好的视差图（无效值 NaN / ≤ 0）
    ///   - colors: 这一帧裁切后的小图；nil = 没法知道画面动没动，不做
    ///   - fresh: 深度是这一帧新来的（false = 沿用的旧深度：不再记一遍，返回上次的结果）
    ///   - relative: 相对视差（整体平移没有意义，可以修）
    /// - Returns: 稳定后的视差图，没有数据的地方还是 NaN（接着照常补洞）
    public func update(_ map: FloatMap, colors: PlanarImage?, fresh: Bool, relative: Bool) -> FloatMap {
        guard enabled, let colors else { reset(); return map }
        let w = map.width, h = map.height, n = w * h, K = max(1, samples)
        if !fresh, let last = lastOutput, last.width == w, last.height == h { return last }
        var holes = 0
        for v in map.values where !(v.isFinite && v > 0) { holes += 1 }
        let holeFraction = Float(holes) / Float(max(1, n))
        if !active {
            guard holeFraction >= activateHoles else { return map }
            reset()
            active = true
        } else if holeFraction < deactivateHoles {
            reset()
            return map
        }
        // 小图（长边约 80）：估计整体平移、哪里变了
        let s = min(1, 80 / Float(max(colors.width, colors.height, 1)))
        let cw = max(8, Int((Float(colors.width) * s).rounded())), ch = max(8, Int((Float(colors.height) * s).rounded()))
        let small = colors.resized(width: cw, height: ch)
        defer { previousColors = small }

        guard width == w, height == h, ring.count == n * K, let previous = previousColors,
              previous.width == cw, previous.height == ch else {
            width = w; height = h
            ring = [Float](repeating: .nan, count: n * K)
            missing = [UInt8](repeating: 0, count: n)
            carry = (0, 0)
            for i in 0..<n where map.values[i].isFinite && map.values[i] > 0 { ring[i * K] = map.values[i] }
            lastOutput = map
            lastOffset = 0
            return map
        }

        // 1. 整体平移和变了的地方
        let R = 3
        let motion = StaleDepth.changeAndShift(small, since: previous, shiftRadius: R)
        // 平移顶到了搜索范围：在扫镜头，历史对不上了，重新开始
        if abs(motion.shift.x) >= Float(R) - 0.01 || abs(motion.shift.y) >= Float(R) - 0.01 {
            ring = [Float](repeating: .nan, count: n * K)
            missing = [UInt8](repeating: 0, count: n)
            carry = (0, 0)
        } else {
            // now(x, y) ≈ old(x + shift)：历史里 (x + shift) 的东西挪到 (x)
            let fx = motion.shift.x * Float(w) / Float(cw) + carry.x
            let fy = motion.shift.y * Float(h) / Float(ch) + carry.y
            let ix = Int(fx.rounded()), iy = Int(fy.rounded())
            carry = (fx - Float(ix), fy - Float(iy))
            if ix != 0 || iy != 0 { translate(dx: ix, dy: iy, samples: K) }
        }
        let changed: [Float]? = motion.changed.contains(where: { $0 > 0 })
            ? FloatMap(width: cw, height: ch, values: motion.changed).resized(width: w, height: h).values : nil

        // 2. 相对视差：这一帧相对历史的整体平移（都有数据、画面没变的像素上，差的中位数）
        // 3、4. 记下这一帧，输出最近几次的中位数；没测到的沿用历史
        var out = [Float](repeating: .nan, count: n)
        let hold = UInt8(min(255, max(0, maxHold)))
        let jump = changeThreshold, leak = offsetLeak
        var offset: Float = 0
        var scratch = [Float](repeating: 0, count: K)
        map.values.withUnsafeBufferPointer { mp in
        ring.withUnsafeMutableBufferPointer { rp in
        missing.withUnsafeMutableBufferPointer { sp in
        out.withUnsafeMutableBufferPointer { op in
        scratch.withUnsafeMutableBufferPointer { bp in
            let M = mp.baseAddress!, Rg = rp.baseAddress!, Ms = sp.baseAddress!, O = op.baseAddress!, B = bp.baseAddress!
            if relative {
                var diffs: [Float] = []
                diffs.reserveCapacity(8192 + 1)
                let step = max(1, n / 8192)
                var i = 0
                while i < n {
                    let v = M[i]
                    if v.isFinite && v > 0 && Rg[i * K].isFinite && (changed.map { $0[i] < 0.5 } ?? true) {
                        diffs.append(v - Self.median(Rg + i * K, count: K, scratch: B))
                    }
                    i += step
                }
                if diffs.count >= 64 {
                    diffs.sort()
                    offset = diffs[diffs.count / 2] * (1 - leak)
                }
            }
            for i in 0..<n {
                let slot = Rg + i * K
                var v = M[i]
                let valid = v.isFinite && v > 0
                if valid { v = max(v - offset, 1e-4) }
                if let changed, changed[i] >= 0.5 {
                    // 这里的东西换了：历史不算数
                    for k in 0..<K { slot[k] = .nan }
                    Ms[i] = 0
                }
                if valid {
                    // 连着两次测到的值差不多、又都和历史差得远：是真的变了（飞点不会连着两次落在一起），旧的不要了
                    let last = slot[0]
                    if K > 1 && last.isFinite && abs(v - last) < 0.5 * jump {
                        let m = Self.median(slot, count: K, scratch: B)
                        if abs(v - m) > jump && abs(last - m) > jump {
                            for k in 1..<K { slot[k] = .nan }
                        }
                    }
                    var k = K - 1
                    while k > 0 { slot[k] = slot[k - 1]; k -= 1 }
                    slot[0] = v
                    Ms[i] = 0
                } else if slot[0].isFinite {
                    if Ms[i] >= hold {
                        for k in 0..<K { slot[k] = .nan }
                        Ms[i] = 0
                    } else {
                        Ms[i] += 1
                    }
                }
                if slot[0].isFinite { O[i] = Self.median(slot, count: K, scratch: B) }
            }
        }}}}}
        lastOffset = offset
        let result = FloatMap(width: w, height: h, values: out)
        lastOutput = result
        return result
    }

    /// 一个像素最近几次测到的值的中位数（NaN 是空位；偶数个取中间两个的平均）。scratch 至少 K 个
    @inline(__always)
    private static func median(_ slot: UnsafePointer<Float>, count K: Int, scratch b: UnsafeMutablePointer<Float>) -> Float {
        var c = 0
        for k in 0..<K {
            let v = slot[k]
            if !v.isFinite { continue }
            // 插入排序
            var j = c
            while j > 0 && b[j - 1] > v { b[j] = b[j - 1]; j -= 1 }
            b[j] = v
            c += 1
        }
        if c == 0 { return .nan }
        return c % 2 == 1 ? b[c / 2] : 0.5 * (b[c / 2 - 1] + b[c / 2])
    }

    /// 历史整体挪 (dx, dy) 个像素：新的 (x, y) 取原来的 (x + dx, y + dy)，挪进来的边上没有历史
    private func translate(dx: Int, dy: Int, samples K: Int) {
        let w = width, h = height
        var nr = [Float](repeating: .nan, count: w * h * K)
        var nm = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let sy = y + dy
            if sy < 0 || sy >= h { continue }
            for x in 0..<w {
                let sx = x + dx
                if sx < 0 || sx >= w { continue }
                let o = (y * w + x) * K, q = (sy * w + sx) * K
                for k in 0..<K { nr[o + k] = ring[q + k] }
                nm[y * w + x] = missing[sy * w + sx]
            }
        }
        ring = nr
        missing = nm
    }
}
