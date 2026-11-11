import XCTest
@testable import BokehCore

/// 4× 长焦、没经过系统滤波的深度：Vision 把点中的盒子和它后面的人（袖子、蓝衣服、放在鼠标上的手）编成了一个物体，
/// 人像实例又把大半个画面编成了「一个人」（调试录制 rec-20261111-095838，录屏 shuye / hezihou-ren）。
/// 深度本身是对的：盒子 0.345，手 0.26，袖子 0.23，衣服 0.20，旁边的椅子 0.20。
final class MergedObjectTests: XCTestCase {
    static let w = 80, h = 60
    static let focus: Float = 0.345

    /// 盒子（x 40..<60）+ 左边挨着的袖子和衣服（x 12..<40，深度和旁边的背景一样）+ 隔着袖子的手（深度在 ±25% 里）
    static func scene() -> (object: FloatMap, depth: FloatMap) {
        var d = [Float](repeating: 0.20, count: w * h)        // 背景（椅子）
        var obj = [Float](repeating: 0, count: w * h)
        for y in 15..<45 { for x in 40..<60 { obj[y * w + x] = 1; d[y * w + x] = focus } }
        for y in 25..<50 { for x in 12..<40 { obj[y * w + x] = 1; d[y * w + x] = x < 26 ? 0.20 : 0.23 } }
        for y in 50..<57 { for x in 14..<24 { obj[y * w + x] = 1; d[y * w + x] = 0.265 } }   // 手
        return (FloatMap(width: w, height: h, values: obj), FloatMap(width: w, height: h, values: d))
    }

    /// 自己测到的深度说它在后面：整块去掉，包括深度碰巧落在 ±25% 里、但和盒子不连着的手
    func testMeasuredNeighbourBehindIsDropped() {
        let s = Self.scene()
        let all = [Float](repeating: 1, count: Self.w * Self.h)
        let out = LiveFrameAnalyzer.refineObject(s.object, depth: s.depth, focusDisparity: Self.focus, norm: Self.focus,
                                                 band: 0.25, reach: 2, measured: all, focusPoint: (0.62, 0.5))
        XCTAssertEqual(out[50, 30], 1, "盒子")
        XCTAssertEqual(out[30, 35], 0, "袖子")
        XCTAssertEqual(out[18, 35], 0, "衣服（和旁边背景一样远）")
        XCTAssertEqual(out[18, 53], 0, "手（±25% 以内，但隔着袖子）")
        // 不知道深度是不是自己测到的（系统滤波过的深度）：和以前一样，和背景一样远的那块算渗进来的
        let old = LiveFrameAnalyzer.refineObject(s.object, depth: s.depth, focusDisparity: Self.focus, norm: Self.focus,
                                                 band: 0.25, reach: 2)
        XCTAssertEqual(old[18, 35], 1)
        XCTAssertEqual(old[18, 53], 1)
    }

    /// 那一块的深度是补洞补出来的（没测到）：照旧按「从背景渗进来」处理，盒子顶面这种还是补得回来
    func testFilledTopFaceIsStillKept() {
        let w = Self.w, h = Self.h
        var d = [Float](repeating: 0.05, count: w * h)
        var obj = [Float](repeating: 0, count: w * h)
        var measured = [Float](repeating: 1, count: w * h)
        for y in 20..<50 { for x in 30..<60 { obj[y * w + x] = 1; d[y * w + x] = Self.focus } }
        // 顶面 10 行：没测到，补洞补成了后面的墙
        for y in 10..<20 { for x in 30..<60 { obj[y * w + x] = 1; d[y * w + x] = 0.05; measured[y * w + x] = 0 } }
        let out = LiveFrameAnalyzer.refineObject(FloatMap(width: w, height: h, values: obj),
                                                 depth: FloatMap(width: w, height: h, values: d),
                                                 focusDisparity: Self.focus, norm: Self.focus, band: 0.25, reach: 2,
                                                 measured: measured, focusPoint: (0.55, 0.6))
        XCTAssertEqual(out[45, 14], 1, "顶面")
        XCTAssertEqual(out[45, 35], 1)
    }

    /// 盒子只占物体的一半多一点：以前整个物体的一致率不到 60%，物体不用；现在先去掉后面那块再算
    func testAgreementIgnoresTheOtherThing() {
        let s = Self.scene()
        var matte = SubjectMatteParameters()
        matte.objectDepthAgreement = 0.6
        let before = LiveFrameAnalyzer.acceptedObject(s.object, depth: s.depth, focusDisparity: Self.focus,
                                                      norm: Self.focus, matte: matte, reach: 2)
        XCTAssertNil(before)
        let all = [Float](repeating: 1, count: Self.w * Self.h)
        let after = LiveFrameAnalyzer.acceptedObject(s.object, depth: s.depth, focusDisparity: Self.focus,
                                                     norm: Self.focus, matte: matte, reach: 2, measured: all,
                                                     focusPoint: (0.62, 0.5))
        let m = try? XCTUnwrap(after)
        XCTAssertEqual(m?[50, 30], 1)
        XCTAssertEqual(m?[30, 35], 0)
    }

    /// 人像实例对不上人像遮罩的不用：盖住大半个画面的、大半落在人像遮罩外面的
    func testImplausibleInstancesAreDropped() {
        let w = Self.w, h = Self.h
        var people = FloatMap(width: w, height: h)
        for y in 40..<55 { for x in 5..<20 { people[x, y] = 0.8 } }                 // 人像遮罩：只有一只手
        var huge = FloatMap(width: w, height: h, repeating: 1)                       // 「1 号」：除了盒子以外的整个画面
        for y in 15..<45 { for x in 40..<60 { huge[x, y] = 0 } }
        var hand = FloatMap(width: w, height: h)
        for y in 41..<54 { for x in 6..<19 { hand[x, y] = 1 } }
        var elsewhere = FloatMap(width: w, height: h)                                // 不大，但不在人像遮罩里
        for y in 5..<15 { for x in 60..<75 { elsewhere[x, y] = 1 } }
        let kept = LiveFrameAnalyzer.plausibleInstances([(1, huge), (2, hand), (3, elsewhere)], people: people)
        XCTAssertEqual(kept.map { $0.label }, [2])
        // 没有人像遮罩：只查面积
        XCTAssertEqual(LiveFrameAnalyzer.plausibleInstances([(1, huge), (2, hand), (3, elsewhere)], people: nil)
            .map { $0.label }, [2, 3])
    }
}
