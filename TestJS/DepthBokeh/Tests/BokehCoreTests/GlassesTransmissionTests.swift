import XCTest
@testable import BokehCore

/// 整片眼镜保清晰会让有纹理的远背景留在镜片里；整片按远深度又会吃掉镜框与反光。
final class GlassesTransmissionTests: XCTestCase {
    struct Fixture {
        var image: PlanarImage
        var depth: FloatMap
        var person: FloatMap
        var glasses: FloatMap
    }

    static func fixture() -> Fixture {
        let w = 240, h = 160
        var image = PlanarImage(width: w, height: h)
        var depth = FloatMap(width: w, height: h, repeating: 0.25)
        var person = FloatMap(width: w, height: h)
        var glasses = person
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let stripe: Float = (y / 4) % 2 == 0 ? 0.28 : 0.58
            image.r[i] = stripe; image.g[i] = stripe + 0.04; image.b[i] = stripe + 0.08
            if x >= 140 && x < 215 && y >= 15 && y < 145 {
                person.values[i] = 1; depth.values[i] = 1
                image.r[i] = 0.62; image.g[i] = 0.36; image.b[i] = 0.24
            }
            if x >= 90 && x < 150 && y >= 50 && y < 100 {
                glasses.values[i] = 0.7
                if x < 140 { person.values[i] = 0.6 }
                let rim = x < 93 || x >= 147 || y < 53 || y >= 97
                let reflection = x >= 117 && x < 123 && y >= 63 && y < 88
                if rim || reflection {
                    let v: Float = rim ? 0.025 : 0.95
                    image.r[i] = v; image.g[i] = v; image.b[i] = v
                }
            }
        } }
        return Fixture(image: image, depth: depth, person: person, glasses: glasses)
    }

    static func plan(_ f: Fixture, focus: (Float, Float) = (0.75, 0.5)) -> FramePlan {
        LiveFrameAnalyzer.stillPlan(disparity: f.depth, relativeDepth: false, colors: f.image,
            fNumber: 1.4, focusPoint: focus, personMask: f.person, outputLongSide: f.image.longSide,
            settings: .init(), focalLength35mm: 48, glassesMatte: f.glasses)
    }

    static func render(_ f: Fixture) -> (PlanarImage, FloatMap) {
        let plan = plan(f)
        let renderer = BokehRenderer()
        renderer.captureDebugMaps = true
        // 放大输出走双分辨率，验证最终景深/细节回填，不只检验分类函数。
        let full = f.image.resized(width: 720, height: 480)
        let output = renderer.renderDetailPreserving(full: full, disparity: plan.depth, lens: plan.lens,
            lowLongSide: plan.lowLongSide, quality: .photo, refinePasses: 2,
            subject: SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: plan.seeds),
            layerCenters: plan.layerCenters)
        return (output, renderer.debugLowDisparity!.resized(width: f.depth.width, height: f.depth.height))
    }

    func testTexturedBackgroundThroughLensBlursWhileRimReflectionAndFaceStaySharp() {
        let f = Self.fixture()
        let (output, depth) = Self.render(f)
        XCTAssertEqual(depth[105, 75], 0.25, accuracy: 0.01, "镜片内透出的远背景不能被填到人脸深度")
        XCTAssertGreaterThan(depth[91, 75], 0.9, "细镜框要保住")
        XCTAssertGreaterThan(depth[120, 75], 0.9, "与远背景不同的局部反光要保住")
        XCTAssertGreaterThan(depth[144, 75], 0.9, "镜片后面的脸要清晰")
        let darkIndex: Int = (73 * 3 + 1) * 720 + 105 * 3 + 1
        let lightIndex: Int = (77 * 3 + 1) * 720 + 105 * 3 + 1
        let contrast = abs(output.r[darkIndex] - output.r[lightIndex])
        let outsideDarkIndex: Int = (73 * 3 + 1) * 720 + 50 * 3 + 1
        let outsideLightIndex: Int = (77 * 3 + 1) * 720 + 50 * 3 + 1
        let outsideContrast = abs(output.r[outsideDarkIndex] - output.r[outsideLightIndex])
        XCTAssertEqual(contrast, outsideContrast, accuracy: 0.03, "镜片内外同深度的背景应具有接近的虚化程度")
        XCTAssertLessThan(contrast, 0.225, "透过镜片的背景条纹应降低至少四分之一对比度，不能仅改一张调试图")
        XCTAssertLessThan(output.r[75 * 3 * 720 + 91 * 3], 0.12, "镜框不能被亮背景冲淡")
        XCTAssertGreaterThan(output.r[75 * 3 * 720 + 120 * 3], 0.8, "镜片反光细节不能被抹掉")
    }

    func testInvalidOriginalDepthDoesNotBecomeTransmissionEvidenceAfterHoleFilling() {
        var f = Self.fixture()
        for y in 53..<97 { for x in 93..<140 { f.depth[x, y] = .nan } }
        XCTAssertNil(Self.plan(f).seeds?.transmission, "不能使用填洞生成的深度来证明镜片内是远背景")
    }

    func testReliableFaceAndMissingBackgroundEvidenceRemainProtected() {
        var f = Self.fixture()
        for y in 50..<100 { for x in 90..<150 { f.person[x, y] = 1 } }
        XCTAssertNil(Self.plan(f).seeds?.transmission, "人像可靠覆盖的眼睛/脸不因错误远深度被挖掉")
        f = Self.fixture()
        for i in f.depth.values.indices where f.person.values[i] == 0 && f.glasses.values[i] == 0 {
            f.depth.values[i] = .nan
        }
        XCTAssertNil(Self.plan(f).seeds?.transmission, "镜片外缺乏原始远背景证据时保守回退")
    }

    func testFocusAwayFromPersonAndMissingColorsKeepExistingBehavior() {
        let f = Self.fixture()
        XCTAssertNil(Self.plan(f, focus: (0.2, 0.5)).seeds?.transmission)
        let plan = LiveFrameAnalyzer.stillPlan(disparity: f.depth, relativeDepth: false, colors: nil,
            fNumber: 1.4, focusPoint: (0.75, 0.5), personMask: f.person, outputLongSide: 240,
            settings: .init(), glassesMatte: f.glasses)
        XCTAssertNil(plan.seeds?.transmission)
    }

    func testDownsamplingDoesNotSkipThinFramesAtAnyPixelPhase() {
        // 24 → 8 的像素中心仅命中第 1、4、7……列；其间的细框也必须阻止恢复远深度。
        for vertical in [true, false] {
            for position in 0..<24 {
                var mask = FloatMap(width: 24, height: 24, repeating: 1)
                for i in 0..<24 {
                    mask[vertical ? position : i, vertical ? i : position] = 0
                }
                let transmission = GlassesTransmission(mask: mask,
                    disparity: FloatMap(width: 24, height: 24, repeating: 0.25))
                let near = FloatMap(width: 8, height: 8, repeating: 1)
                let result = SubjectMatte.apply(disparity: near, image: PlanarImage(width: 8, height: 8),
                    focusDisparity: 1, parameters: .init(),
                    seeds: SubjectSeeds(person: near, transmission: transmission))
                for y in 0..<8 { for x in 0..<8 {
                    let isFrame = (vertical ? x : y) == position / 3
                    XCTAssertEqual(result.0[x, y], isFrame ? 1 : 0.25, accuracy: 1e-6)
                    XCTAssertEqual(result.1[x, y], isFrame ? 1 : 0, accuracy: 1e-6)
                } }
            }
        }
    }

    /// 按 photo-20261112-173241 的数值搭建：两个模型都漏反光，硬件却测到了近深度。
    func testNearReflectionSurvivesWhenAppleAndLocalDepthBothMissIt() {
        let w = 160, h = 120
        var depth = FloatMap(width: w, height: h, repeating: 0.22)
        var person = FloatMap(width: w, height: h), glasses = person, band = person
        var ai = FloatMap(width: w, height: h, repeating: 0.45)
        var image = PlanarImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            image.r[i] = 0.45; image.g[i] = 0.45; image.b[i] = 0.45
            if x >= 80 {
                person[x, y] = 1; depth[x, y] = 0.325; ai[x, y] = 0.86
                image.r[i] = 0.62; image.g[i] = 0.36; image.b[i] = 0.24
            }
            if y >= 40 && y < 70 {
                if x >= 65 && x < 90 { band[x, y] = 1 }
                if x >= 75 && x < 80 {
                    person[x, y] = 0.35; glasses[x, y] = 0.06; ai[x, y] = 0.58
                    if x >= 78 {
                        depth[x, y] = 0.316
                        image.r[i] = 0.95; image.g[i] = 0.95; image.b[i] = 0.95
                    }
                }
                if x >= 80 && x < 84 { glasses[x, y] = 0.8 }
            }
        } }
        let local = LocalDepth(map: ai, x0: 0, y0: 0, x1: 1, y1: 1)
        XCTAssertNil(SubjectMatte.glassesByLocalDepth(local, glasses: glasses, person: person,
            width: w, height: h, parameters: .init()), "必须复现 AI 也漏检的条件")
        // 同样贴着脸、位于软人像里的远背景，缩小光圈后也不能被兜底补成眼镜。
        for y in 60..<65 { depth[78, y] = 0.22; depth[79, y] = 0.22 }
        for fNumber: Float in [2.8, 8] {
            let plan = LiveFrameAnalyzer.stillPlan(disparity: depth, relativeDepth: true, colors: image,
                fNumber: fNumber, focusPoint: (0.65, 0.5), personMask: person, outputLongSide: 480,
                settings: .init(), focalLength35mm: 100, faceBand: band, glassesMatte: glasses,
                glassesFollowDepth: true, glassesDepth: local)
            XCTAssertGreaterThan(plan.depth[78, 55], 0.31, "不能把原始近反光从背景侧填成远深度")
            let renderer = BokehRenderer(); renderer.captureDebugMaps = true
            _ = renderer.renderDetailPreserving(full: image.resized(width: 480, height: 360),
                disparity: plan.depth, lens: plan.lens, lowLongSide: plan.lowLongSide, quality: .photo,
                refinePasses: 2, subject: .init(point: plan.focusPoint, parameters: plan.matte, seeds: plan.seeds),
                layerCenters: plan.layerCenters)
            let final = renderer.debugLowDisparity!.resized(width: w, height: h)
            let alpha = renderer.debugMatte!.resized(width: w, height: h)
            XCTAssertGreaterThan(final[78, 55], 0.31)
            XCTAssertGreaterThan(alpha[78, 55], 0.85, "近反光在最终合成前仍要保住")
            XCTAssertLessThan(plan.depth[75, 55], 0.25, "同在软人像/眼镜带内的远背景不能一起补清晰")
            XCTAssertLessThan(plan.depth[78, 62], 0.25, "小光圈也必须有独立的近深度证据")
        }
    }
}
