import XCTest
@testable import BokehCore

final class PersonSegmentationRegressionTests: XCTestCase {
    private struct Scene {
        var depth: FloatMap
        var people: FloatMap
        var instances: FloatMap
        var objects: FloatMap?
        var colors: PlanarImage
        var focus: (Float, Float)
        var focalLength: Float = 24

        func plan(live: Bool, instancesEnabled: Bool = true, peopleEnabled: Bool = true) -> FramePlan {
            if live {
                return LiveFrameAnalyzer().analyze(.init(
                    disparity: depth, relativeDepth: false, crop: 1, fNumber: 1.4,
                    focusPoint: focus, focusTapped: true, time: 0, colors: colors,
                    personMask: peopleEnabled ? people : nil, outputLongSide: 1440, objectLabels: objects,
                    personInstances: instancesEnabled ? instances : nil, focalLength35mm: focalLength))
            }
            return LiveFrameAnalyzer.stillPlan(
                disparity: depth, relativeDepth: false, colors: colors, fNumber: 1.4,
                focusPoint: focus, personMask: peopleEnabled ? people : nil, outputLongSide: 1440,
                settings: .init(), objectLabels: objects,
                personInstances: instancesEnabled ? instances : nil, focalLength35mm: focalLength)
        }

        func renderedDepth(_ plan: FramePlan) throws -> FloatMap {
            let seeds = try XCTUnwrap(plan.seeds)
            return SubjectMatte.apply(disparity: plan.depth, image: colors,
                                      focusDisparity: plan.focusDisparity, parameters: plan.matte,
                                      scale: plan.lens.relativeScale, seeds: seeds).0
        }
    }

    // 同一实例的手被挡住连接处，手部深度又误测为背景；另一个人不能跟着变清晰。
    private func disconnectedPerson() -> Scene {
        let w = 100, h = 80
        var depth = FloatMap(width: w, height: h, repeating: 0.1)
        var people = FloatMap(width: w, height: h)
        var instances = people
        var colors = PlanarImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            colors.r[i] = 0.04; colors.g[i] = 0.05; colors.b[i] = 0.06
            let torso = (20..<45).contains(x) && (15..<70).contains(y)
            let hand = (62..<72).contains(x) && (35..<45).contains(y)
            let other = (82..<96).contains(x) && (15..<70).contains(y)
            if torso || hand || other {
                people[x, y] = 1
                instances[x, y] = other ? 2 : 1
                colors.r[i] = 0.55; colors.g[i] = 0.3; colors.b[i] = 0.22
                if torso { depth[x, y] = 0.5 }
            }
        } }
        return Scene(depth: depth, people: people, instances: instances, colors: colors, focus: (0.32, 0.4))
    }

    private func checkDisconnectedPerson(live: Bool) throws {
        let scene = disconnectedPerson()
        let plan = scene.plan(live: live)
        let output = try scene.renderedDepth(plan)
        XCTAssertGreaterThan(plan.seeds?.person?[66, 40] ?? 0, 0.9, "已选实例的独立手部仍需保留")
        XCTAssertEqual(output[66, 40], 0.5, accuracy: 0.001, "手部应和躯干一起保持清晰")
        XCTAssertLessThan(abs(plan.lens.signedBlurRadius(disparity: output[66, 40], imageLongSide: 1440)), 0.1)
        XCTAssertLessThan(plan.seeds?.person?[89, 40] ?? 0, 0.05, "另一个人不能进入主体遮罩")
        XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: output[89, 40], imageLongSide: 1440)), 5)
        XCTAssertEqual(output[5, 40], 0.1, accuracy: 0.001)
    }

    func testStillPreservesDisconnectedPartsOfFocusedPerson() throws {
        try checkDisconnectedPerson(live: false)
    }

    func testLivePreservesDisconnectedPartsOfFocusedPerson() throws {
        try checkDisconnectedPerson(live: true)
    }

    // 两个人相邻，人物实例能分开，但前景物体分割把两人归为同一组。
    private func mergedPeople() -> Scene {
        let w = 120, h = 90
        var depth = FloatMap(width: w, height: h, repeating: 0.25)
        var people = FloatMap(width: w, height: h)
        var instances = people
        for y in 15..<80 { for x in 20..<100 {
            depth[x, y] = x < 60 ? 1 : 0.8
            people[x, y] = 1
            instances[x, y] = x < 60 ? 1 : 2
        } }
        let colors = PlanarImage(width: w, height: h,
                                 r: people.values.map { $0 > 0 ? 0.3 : 0.8 },
                                 g: people.values.map { $0 > 0 ? 0.2 : 0.8 },
                                 b: people.values.map { $0 > 0 ? 0.15 : 0.8 })
        return Scene(depth: depth, people: people, instances: instances, objects: people,
                     colors: colors, focus: (0.33, 0.5), focalLength: 100)
    }

    private func checkMergedPeople(live: Bool) throws {
        let scene = mergedPeople()
        let plan = scene.plan(live: live)
        let output = try scene.renderedDepth(plan)
        XCTAssertGreaterThan(plan.seeds?.person?[40, 45] ?? 0, 0.9)
        XCTAssertLessThan(plan.seeds?.person?[80, 45] ?? 0, 0.05, "物体分组不能覆盖人物实例排除结果")
        XCTAssertEqual(output[80, 45], 0.8, accuracy: 0.001)
        XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: output[80, 45], imageLongSide: 1440)), 10)
    }

    func testStillObjectGroupCannotRestoreExcludedPerson() throws {
        try checkMergedPeople(live: false)
    }

    func testLiveObjectGroupCannotRestoreExcludedPerson() throws {
        try checkMergedPeople(live: true)
    }

    func testWithoutInstancesDoesNotTreatAllPeopleAsSelected() throws {
        let scene = disconnectedPerson()
        let plan = scene.plan(live: false, instancesEnabled: false)
        let output = try scene.renderedDepth(plan)
        XCTAssertGreaterThan(plan.seeds?.person?[32, 40] ?? 0, 0.9)
        XCTAssertLessThan(plan.seeds?.person?[89, 40] ?? 0, 0.05)
        XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: output[89, 40], imageLongSide: 1440)), 5)
    }

    private func objectBesidePerson() -> Scene {
        var scene = mergedPeople()
        // 左边改成物体，右边仍是另一个人。前景分割仍错误地把两者合成一组。
        for y in 15..<80 { for x in 20..<60 {
            scene.people[x, y] = 0
            scene.instances[x, y] = 0
        } }
        for y in 15..<21 { for x in 20..<60 { scene.depth[x, y] = 0.25 } }
        return scene
    }

    func testObjectFocusStillProtectsObjectWithoutProtectingNearbyPerson() throws {
        let scene = objectBesidePerson()
        for live in [false, true] {
            let plan = scene.plan(live: live)
            let output = try scene.renderedDepth(plan)
            XCTAssertEqual(output[40, 18], 1, accuracy: 0.001, "正常物体的顶面仍应保持清晰")
            XCTAssertEqual(output[80, 45], 0.8, accuracy: 0.001, "物体旁的已识别人物仍应虚化")
        }
    }

    func testInstanceExclusionsApplyEvenWithoutSemanticPersonMask() throws {
        let scene = objectBesidePerson()
        for live in [false, true] {
            let plan = scene.plan(live: live, peopleEnabled: false)
            let output = try scene.renderedDepth(plan)
            XCTAssertEqual(output[40, 18], 1, accuracy: 0.001)
            XCTAssertEqual(output[80, 45], 0.8, accuracy: 0.001,
                           "即使人像软遮罩缺失，也不能让物体分组恢复已识别的人物")
        }
    }
}
