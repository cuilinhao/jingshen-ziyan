import XCTest
@testable import BokehCore

/// 没经过系统滤波的深度（长焦双摄）在补洞之前的跨帧稳定（DepthHistory）。
/// 场景照着调试录制 rec-20261110-181727 造：4.2×、ƒ1.4，对焦近处的纸盒；每帧 40% 的洞、洞的位置每帧变，
/// 有数据的像素带噪声和飞点，整幅视差的平移在 0 和 0.02 之间跳。画面完全静止
final class DepthHistoryTests: XCTestCase {
    struct RNG {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float((s >> 40) & 0xFFFFFF) / Float(0x1000000)
        }
        mutating func gauss() -> Float {
            let u = max(next(), 1e-6), v = next()
            return sqrtf(-2 * logf(u)) * cosf(2 * .pi * v)
        }
    }

    static let w = 160, h = 120

    /// 左边是远处的墙（视差 0.05，颜色浅），右边是和对焦面差不多远的隔板（0.30，颜色深一点），中间一个盒子（0.335）
    static func scene(boxAt bx: Int = 60, boxDisparity: Float = 0.335,
                      boxColor: Float = 0.55) -> (truth: FloatMap, colors: PlanarImage) {
        var d = FloatMap(width: w, height: h, repeating: 0.05)
        var c = PlanarImage(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var v: Float = 0.35 + 0.05 * Float((x / 8 + y / 8) % 2)
                if x >= 100 { d.values[i] = 0.30; v = 0.15 + 0.05 * Float((x / 6 + y / 6) % 2) }
                if x >= bx && x < bx + 30 && y >= 40 && y < 90 { d.values[i] = boxDisparity; v = boxColor }
                c.r[i] = v; c.g[i] = v * 0.9; c.b[i] = v * 0.7
            }
        }
        return (d, c)
    }

    /// 一帧「测出来」的视差：洞、噪声、飞点、整体平移
    static func measured(_ truth: FloatMap, rng: inout RNG, offset: Float) -> FloatMap {
        var m = truth
        // 洞成块出现（8×8 的块，每块 40% 的概率整块没数据）
        var blockHole = [Bool](repeating: false, count: (w / 8 + 1) * (h / 8 + 1))
        for i in 0..<blockHole.count { blockHole[i] = rng.next() < 0.4 }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if blockHole[(y / 8) * (w / 8 + 1) + x / 8] { m.values[i] = .nan; continue }
                var v = truth.values[i] + 0.01 * rng.gauss()
                if rng.next() < 0.05 { v = 0.02 + 0.35 * rng.next() }   // 飞点
                m.values[i] = max(v, 0.001) + offset
            }
        }
        return m
    }

    /// 相邻两帧补好洞的视差平均差多少（减掉各自的对焦视差：虚化只看和对焦面的差）
    func run(history: DepthHistory?, frames: Int = 40) -> (jitter: Float, error: Float) {
        let (truth, colors) = Self.scene()
        var rng = RNG(s: 42)
        var previous: [Float]?
        var jitter: Float = 0, error: Float = 0, count: Float = 0
        let focusIndex = 65 * Self.w + 75
        for f in 0..<frames {
            let offset: Float = rng.next() < 0.3 ? 0 : 0.02
            let m = Self.measured(truth, rng: &rng, offset: offset)
            let stable = history?.update(m, colors: colors, fresh: true, relative: true) ?? m
            let filled = DepthRefiner.fillInvalid(stable, guide: colors)
            let focus = DepthRefiner.focusDisparity(in: filled, nx: 75.0 / Float(Self.w), ny: 65.0 / Float(Self.h))
            let rel = filled.values.map { $0 - focus }
            if f >= 10, let p = previous {
                var s: Float = 0, e: Float = 0
                for i in 0..<rel.count {
                    s += abs(rel[i] - p[i])
                    e += abs(rel[i] - (truth.values[i] - truth.values[focusIndex]))
                }
                jitter += s / Float(rel.count)
                error += e / Float(rel.count)
                count += 1
            }
            previous = rel
        }
        return (jitter / count, error / count)
    }

    /// 静止的画面：逐帧变化至少降到原来的 1/4，而且离真值不会更远
    func testStaticSceneStopsFlickering() {
        let before = run(history: nil)
        let after = run(history: DepthHistory())
        print("逐帧变化 \(before.jitter) → \(after.jitter)，离真值 \(before.error) → \(after.error)")
        XCTAssertLessThan(after.jitter, before.jitter * 0.25)
        XCTAssertLessThan(after.error, before.error)
        // 镜头曲线 100mm ƒ1.4：视差差 0.01 ≈ 长边的 0.13%。稳定后逐帧平均变化不到 0.007（≈ 0.09%，1440 上 1 个多像素）
        XCTAssertLessThan(after.jitter, 0.007)
    }

    /// 系统滤波过的深度（没有洞）：原样通过，一个数都不改
    func testFilteredDepthPassesThrough() {
        let (truth, colors) = Self.scene()
        let history = DepthHistory()
        var rng = RNG(s: 7)
        for _ in 0..<5 {
            var m = truth
            for i in 0..<m.values.count { m.values[i] += 0.01 * rng.gauss() }
            let out = history.update(m, colors: colors, fresh: true, relative: true)
            XCTAssertEqual(out.values, m.values)
            XCTAssertFalse(history.active)
        }
    }

    /// 东西挪走了（那一块画面变了）：当帧就用新测到的，不拖着旧深度
    func testMovedObjectIsNotHeld() {
        let history = DepthHistory()
        var rng = RNG(s: 3)
        let a = Self.scene(boxAt: 30)
        for _ in 0..<12 {
            _ = history.update(Self.measured(a.truth, rng: &rng, offset: 0.02), colors: a.colors, fresh: true, relative: true)
        }
        // 盒子从 x = 30 挪到 x = 64（不重叠）：原来的位置露出后面的墙
        let b = Self.scene(boxAt: 64)
        let out = history.update(Self.measured(b.truth, rng: &rng, offset: 0.02), colors: b.colors, fresh: true, relative: true)
        var stale = 0, seen = 0
        for y in 44..<86 {
            for x in 34..<56 {
                let v = out.values[y * Self.w + x]
                guard v.isFinite else { continue }
                seen += 1
                // 减掉整体平移以后墙是 0.05 + 0.02 左右；还留着盒子深度（> 0.25）的就是拖影
                if v > 0.25 { stale += 1 }
            }
        }
        XCTAssertGreaterThan(seen, 200)
        // 这一帧自己的飞点约 5%，其中落在 0.25 以上的不到一半
        XCTAssertLessThan(Float(stale) / Float(seen), 0.05)
    }

    /// 画面没变、深度真的变了（颜色一样的东西前后挪）：四张深度以内跟上（每个像素要连着测到两次）
    func testDepthChangeWithoutColorChangeFollows() {
        let history = DepthHistory()
        var rng = RNG(s: 11)
        let a = Self.scene(boxDisparity: 0.335)
        for _ in 0..<12 {
            _ = history.update(Self.measured(a.truth, rng: &rng, offset: 0.02), colors: a.colors, fresh: true, relative: true)
        }
        let b = Self.scene(boxDisparity: 0.20)
        var out = FloatMap(width: Self.w, height: Self.h)
        for _ in 0..<4 {
            out = history.update(Self.measured(b.truth, rng: &rng, offset: 0.02), colors: a.colors, fresh: true, relative: true)
        }
        var values: [Float] = []
        for y in 45..<85 { for x in 65..<85 where out.values[y * Self.w + x].isFinite { values.append(out.values[y * Self.w + x]) } }
        values.sort()
        let wall = out.values[10 * Self.w + 10]
        // 盒子相对墙的视差差应该从 0.285 变到 0.15 左右
        XCTAssertEqual(values[values.count / 2] - wall, 0.15, accuracy: 0.03)
    }

    /// 整体平移每帧跳（ImageBridge 的 2% 分位在 0 上下翻）：输出里不该再有这个跳变
    func testGlobalOffsetJumpIsRemoved() {
        let (truth, colors) = Self.scene()
        let history = DepthHistory()
        var rng = RNG(s: 5)
        var walls: [Float] = []
        for f in 0..<30 {
            let m = Self.measured(truth, rng: &rng, offset: f % 3 == 0 ? 0 : 0.02)
            let out = history.update(m, colors: colors, fresh: true, relative: true)
            if f >= 8 {
                var v: [Float] = []
                for y in 20..<100 { for x in 5..<50 where out.values[y * Self.w + x].isFinite { v.append(out.values[y * Self.w + x]) } }
                v.sort()
                walls.append(v[v.count / 2])
            }
        }
        let spread = walls.max()! - walls.min()!
        XCTAssertLessThan(spread, 0.004, "墙的视差还在跟着整体平移跳：\(walls)")
    }
}
