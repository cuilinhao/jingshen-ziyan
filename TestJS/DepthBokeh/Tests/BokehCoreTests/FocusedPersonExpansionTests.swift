import XCTest
@testable import BokehCore

final class FocusedPersonExpansionTests: XCTestCase {
    /// A 的实例漏掉两列轮廓；B 的实例把右侧大量背景也包进去，被可信度检查丢弃。
    /// 两人的语义遮罩相连，B 左侧位于 A 实例的外扩范围内。
    private func scene(otherDepth: Float = 0.3) -> (FloatMap, FloatMap, FloatMap, PlanarImage) {
        let w = 160, h = 120
        var depth = FloatMap(width: w, height: h, repeating: 0.1)
        var people = FloatMap(width: w, height: h)
        var labels = FloatMap(width: w, height: h)
        var colors = PlanarImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            colors.r[i] = 0.8; colors.g[i] = 0.8; colors.b[i] = 0.8
            if x >= 80 { labels[x, y] = 2 }
            if (40..<82).contains(x), (25..<105).contains(y) {
                people[x, y] = 1; depth[x, y] = 1
                if x < 80 { labels[x, y] = 1 }
                colors.r[i] = 0.4; colors.g[i] = 0.2; colors.b[i] = 0.1
            }
            if (82..<113).contains(x), (25..<95).contains(y) {
                people[x, y] = 1; depth[x, y] = otherDepth
                colors.r[i] = 0.1; colors.g[i] = 0.2; colors.b[i] = 0.5
            }
        } }
        return (depth, people, labels, colors)
    }

    private func result(live: Bool, otherDepth: Float = 0.3,
                        fNumber: Float = 2.8) throws -> (FramePlan, FloatMap) {
        let (depth, people, labels, colors) = scene(otherDepth: otherDepth)
        let plan: FramePlan
        if live {
            plan = LiveFrameAnalyzer().analyze(.init(
                disparity: depth, relativeDepth: false, crop: 1, fNumber: fNumber,
                focusPoint: (0.375, 0.5), focusTapped: true, time: 0, colors: colors,
                personMask: people, outputLongSide: 1440, personInstances: labels,
                focalLength35mm: 24))
        } else {
            plan = LiveFrameAnalyzer.stillPlan(
                disparity: depth, relativeDepth: false, colors: colors, fNumber: fNumber,
                focusPoint: (0.375, 0.5), personMask: people, outputLongSide: 1440,
                settings: .init(), personInstances: labels, focalLength35mm: 24)
        }
        let seeds = try XCTUnwrap(plan.seeds)
        let rendered = SubjectMatte.apply(disparity: plan.depth, image: colors,
                                          focusDisparity: plan.focusDisparity,
                                          parameters: plan.matte, seeds: seeds).0
        return (plan, rendered)
    }

    private func checkFarPerson(live: Bool) throws {
        for f: Float in [2.8, 16] {
            let (plan, rendered) = try result(live: live, fNumber: f)
            XCTAssertEqual(plan.focusDisparity, 1, accuracy: 0.001)
            XCTAssertEqual(rendered[60, 60], 1, accuracy: 0.001, "A 本体继续清晰")
            XCTAssertEqual(rendered[80, 60], 1, accuracy: 0.001, "实例漏掉但深度一致的 A 轮廓继续清晰")
            XCTAssertLessThan(plan.seeds?.person?[84, 60] ?? 0, 0.05,
                              "B 实例无效不能让 A 外扩吞入明显在后面的 B；归属不随光圈改变")
            XCTAssertEqual(rendered[84, 60], 0.3, accuracy: 0.02,
                           "B 的远深度应保留到渲染，不能被人像或颜色补边拉回焦面")
        }
    }

    func testStillFarPersonInExpansionRemainsBlurredWhenItsInstanceIsRejected() throws {
        try checkFarPerson(live: false)
    }

    func testLiveFarPersonInExpansionRemainsBlurredWhenItsInstanceIsRejected() throws {
        try checkFarPerson(live: true)
    }

    func testPersonAtSameDepthRemainsSharp() throws {
        for live in [false, true] {
            let (_, rendered) = try result(live: live, otherDepth: 1)
            XCTAssertEqual(rendered[84, 60], 1, accuracy: 0.001)
        }
    }

    private func historyPlan(currentDepth: Float, offset: Float = 0,
                             relative: Bool = false) -> FramePlan {
        var (depth, people, labels, colors) = scene()
        // 先激活长焦线路的补洞历史，并让 B 的旧远深度积累足够样本。
        for y in 0..<15 { for x in 0..<depth.width { depth[x, y] = .nan } }
        let analyzer = LiveFrameAnalyzer()
        func analyze(_ d: FloatMap, time: Double) -> FramePlan {
            analyzer.analyze(.init(disparity: d, relativeDepth: relative, crop: 1, fNumber: 2.8,
                focusPoint: (0.375, 0.5), focusTapped: time == 0, time: time, colors: colors,
                personMask: people, outputLongSide: 1440, personInstances: labels, focalLength35mm: 24))
        }
        for frame in 0..<5 { _ = analyze(depth, time: Double(frame) / 30) }
        for y in 25..<95 { for x in 82..<113 { depth[x, y] = currentDepth } }
        if offset != 0 {
            for i in depth.values.indices where depth.values[i].isFinite { depth.values[i] += offset }
        }
        return analyze(depth, time: 5.0 / 30)
    }

    func testHistoryFilledHoleDoesNotCountAsCurrentFarEvidence() {
        let plan = historyPlan(currentDepth: .nan)
        XCTAssertLessThan(plan.depth[84, 60], 0.5, "历史仍可供正常渲染使用")
        XCTAssertGreaterThan(plan.seeds?.person?[84, 60] ?? 0, 0.95,
                             "当前没有测量，不能凭历史远值否定实例外的轮廓保护")
    }

    func testCurrentNearMeasurementOverridesOldFarRejectionEvidence() {
        let plan = historyPlan(currentDepth: 1)
        XCTAssertLessThan(plan.depth[84, 60], 0.5, "首帧深度中值仍是旧远值")
        XCTAssertGreaterThan(plan.seeds?.person?[84, 60] ?? 0, 0.95,
                             "本帧已测得近深度，不能用旧远值拒绝该外扩部分")
    }

    func testRelativeDepthOffsetDoesNotChangeExpansionDecision() {
        let plan = historyPlan(currentDepth: 0.3, offset: 0.8, relative: true)
        XCTAssertLessThan(plan.seeds?.person?[84, 60] ?? 0, 0.05,
                          "相对深度整幅平移不应让远处 B 重新进入保护；测量与焦面使用同一标尺")
    }
}
