import XCTest
@testable import BokehCore

/// 「先深度、再分割」（ARCHITECTURE §1、§13）：分割只管边界在哪、点的是哪一个，点中的主体整体清晰是唯一的例外。
/// 下面这些地方以前分割 / 颜色说了算、没过深度（ARCHITECTURE §7 #8 #11 #6 #7），用合成场景钉住：
///  - 人像遮罩把空隙包进去了（胳膊和身体之间、下巴底下）：空隙里露出的是后面的背景，深度明明在后面，以前整块拉清晰
///  - 没有人像实例时，按深度留下的那部分再外扩 1/30：挨着的、站在后面的人被拉清晰一条
///  - 对焦物体时，颜色补边照样越过物体遮罩：和物体同色的东西（黑包旁边的黑条）被拉清晰
/// 同时守住例外：点中的人自己身上前后有深度差（伸向后面的胳膊、伸向镜头的手）照样整体清晰。
///
/// 场景按真实距离给深度（LiDAR，边缘被抹开 1 像素），分割照 Vision 常见的样子给（可能把空隙包进去），
/// 实时预览和拍照两条路径都跑，读出低分辨率上最终的视差，和镜头该给的虚化比。
final class DepthFirstRegressionTests: XCTestCase {

    struct Layer {
        var name: String
        var z: Float
        var color: (Int, Int) -> (Float, Float, Float)
        var inside: (Float, Float) -> Bool
        var person = false
        var object = false
    }

    static func flat(_ r: Float, _ g: Float, _ b: Float) -> (Int, Int) -> (Float, Float, Float) { { _, _ in (r, g, b) } }
    /// 黑白竖条（8 像素一条，960 宽的图上）。条纹要细：一格颜色统计里黑白都有，背景样本是灰的，
    /// 紧挨着主体的那条黑的才会被颜色补边认成主体（和录屏里的方格一样）
    static func stripes(_ ix: Int, _ iy: Int) -> (Float, Float, Float) {
        (ix / 8) % 2 == 0 ? (0.015, 0.015, 0.02) : (0.82, 0.82, 0.8)
    }
    static func checker(_ ix: Int, _ iy: Int) -> (Float, Float, Float) {
        (ix / 8 + iy / 8) % 2 == 0 ? (0.015, 0.015, 0.02) : (0.82, 0.82, 0.8)
    }
    static func rect(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float) -> (Float, Float) -> Bool {
        { x, y in x >= x0 && x < x1 && y >= y0 && y < y1 }
    }

    struct Scene {
        var layers: [Layer]
        var focus: (Float, Float)
        /// 额外算进人像遮罩 / 物体标签的地方（Vision 把空隙包进去了）
        var personMaskExtra: ((Float, Float) -> Bool)? = nil
        var objectMaskExtra: ((Float, Float) -> Bool)? = nil
        var instances = true
        /// 直接给人像遮罩（软边，480×360），不按层生成
        var personMaskOverride: FloatMap? = nil
        /// 眼镜带（FaceBand，0/1）
        var faceBand: FloatMap? = nil
        /// Apple 拍照时给的眼镜遮罩（只有拍照才有）
        var glassesMatte: FloatMap? = nil

        static let iw = 960, ih = 720, dw = 240, dh = 180

        /// 这一点最上面的是哪一层（后画的盖住先画的）
        func top(_ x: Float, _ y: Float) -> Int {
            var k = 0
            for (i, l) in layers.enumerated() where l.inside(x, y) { k = i }
            return k
        }
    }

    struct Result {
        var scene: Scene
        var lens: LensParameters
        var low: FloatMap
        var truth: [Float]

        /// 区域里的像素：中位数虚化（实际 / 镜头该给的，按长边 %），以及「该明显糊（≥ 0.4%）却不到一半」的比例
        func stats(_ region: (Float, Float) -> Bool, dark: Bool = false) -> (actual: Float, ideal: Float, sharp: Float, n: Int) {
            let fl = scene.top(scene.focus.0, scene.focus.1)
            var a: [Float] = [], e: [Float] = []
            var bad = 0
            let k = Scene.iw / low.width
            for y in 0..<low.height {
                for x in 0..<low.width {
                    let nx = (Float(x) + 0.5) / Float(low.width), ny = (Float(y) + 0.5) / Float(low.height)
                    guard region(nx, ny) else { continue }
                    if dark {
                        var all = true
                        for yy in (y * k)..<(y * k + k) { for xx in (x * k)..<(x * k + k) {
                            let c = scene.layers[scene.top((Float(xx) + 0.5) / Float(Scene.iw), (Float(yy) + 0.5) / Float(Scene.ih))].color(xx, yy)
                            if c.0 > 0.5 { all = false }
                        } }
                        guard all else { continue }
                    }
                    let sx = min(Scene.dw - 1, Int(nx * Float(Scene.dw))), sy = min(Scene.dh - 1, Int(ny * Float(Scene.dh)))
                    let act = abs(lens.signedBlurRadius(disparity: low[x, y], imageLongSide: 1000)) / 10
                    // 理想：同一个镜头、真实视差；点中的那个人 / 物体（和对焦点同一层，或者同属一个人）整体清晰
                    let t = scene.top(nx, ny)
                    let subject = t == fl || (scene.layers[fl].person && scene.layers[t].person && scene.layers[t].name.hasPrefix(scene.layers[fl].name))
                    let ide = subject ? 0 : abs(lens.signedBlurRadius(disparity: truth[sy * Scene.dw + sx], imageLongSide: 1000)) / 10
                    a.append(act); e.append(ide)
                    if ide >= 0.4 && act < 0.5 * ide { bad += 1 }
                }
            }
            guard !a.isEmpty else { return (.nan, .nan, .nan, 0) }
            let n = a.count
            a.sort(); e.sort()
            return (a[n / 2], e[n / 2], Float(bad) / Float(n), n)
        }

        /// 这一层离别的层至少 margin 个深度像素的地方
        func interior(_ name: String, margin: Int = 2) -> (Float, Float) -> Bool {
            let k = scene.layers.firstIndex { $0.name == name }!
            let mx = Float(margin) / Float(Scene.dw), my = Float(margin) / Float(Scene.dh)
            return { x, y in
                for dy in [-my, 0, my] { for dx in [-mx, 0, mx] where scene.top(x + dx, y + dy) != k { return false } }
                return true
            }
        }
    }

    static func render(_ s: Scene, live: Bool) -> Result {
        let iw = Scene.iw, ih = Scene.ih, dw = Scene.dw, dh = Scene.dh
        var r = [Float](repeating: 0, count: iw * ih), g = r, b = r
        for y in 0..<ih { for x in 0..<iw {
            let c = s.layers[s.top((Float(x) + 0.5) / Float(iw), (Float(y) + 0.5) / Float(ih))].color(x, y)
            r[y * iw + x] = c.0; g[y * iw + x] = c.1; b[y * iw + x] = c.2
        } }
        var truth = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh { for x in 0..<dw {
            truth[y * dw + x] = 1 / s.layers[s.top((Float(x) + 0.5) / Float(dw), (Float(y) + 0.5) / Float(dh))].z
        } }
        let d = ScenarioMatrixTests.boxBlur(truth, w: dw, h: dh, r: 1)
        // 分割（Vision balanced 约 480 宽）
        let mw = 480, mh = 360
        var pm = [Float](repeating: 0, count: mw * mh), om = pm
        var anyP = false, anyO = false
        for y in 0..<mh { for x in 0..<mw {
            let nx = (Float(x) + 0.5) / Float(mw), ny = (Float(y) + 0.5) / Float(mh)
            let l = s.layers[s.top(nx, ny)]
            if l.person || s.personMaskExtra?(nx, ny) == true { pm[y * mw + x] = 1; anyP = true }
            if l.object || s.objectMaskExtra?(nx, ny) == true { om[y * mw + x] = 1; anyO = true }
        } }
        let image = PlanarImage(width: iw, height: ih, r: r, g: g, b: b)
        let disparity = FloatMap(width: dw, height: dh, values: d)
        let person = s.personMaskOverride ?? (anyP ? FloatMap(width: mw, height: mh, values: pm) : nil)
        let instances = anyP && s.instances ? FloatMap(width: mw, height: mh, values: pm) : nil
        let objects = anyO ? FloatMap(width: mw, height: mh, values: om) : nil
        if live {
            let pipeline = LivePreviewPipeline()
            pipeline.renderer.captureDebugMaps = true
            for t in 0..<8 {
                _ = pipeline.process(LivePreviewPipeline.Frame(
                    image: image, disparity: disparity, relativeDepth: false, crop: 1, fNumber: 1.4,
                    focusPoint: s.focus, focusTapped: t == 0, time: Double(t) / 30, personMask: person,
                    objectLabels: objects, personInstances: instances, focalLength35mm: 24, faceBand: s.faceBand))
            }
            return Result(scene: s, lens: pipeline.lastPlan!.lens, low: pipeline.renderer.debugLowDisparity!, truth: truth)
        }
        var settings = LiveFrameAnalyzer.Settings()
        settings.layersPerSide = RenderQuality.photo.layersPerSide
        let plan = LiveFrameAnalyzer.stillPlan(
            disparity: disparity, relativeDepth: false, colors: image.resized(width: dw, height: dh), fNumber: 1.4,
            focusPoint: s.focus, personMask: person, outputLongSide: iw, settings: settings, objectLabels: objects,
            personInstances: instances, focalLength35mm: 24, faceBand: s.faceBand, glassesMatte: s.glassesMatte)
        let renderer = BokehRenderer()
        renderer.captureDebugMaps = true
        let hint = plan.seeds.map { SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: $0) }
        _ = renderer.renderDetailPreserving(full: image, disparity: plan.depth, lens: plan.lens, lowLongSide: plan.lowLongSide,
                                            quality: .photo, subject: hint, layerCenters: plan.layerCenters)
        return Result(scene: s, lens: plan.lens, low: renderer.debugLowDisparity!, truth: truth)
    }

    static func name(_ live: Bool, _ s: Scene) -> String { (live ? "预览" : "拍照") + (s.instances ? "" : "（无实例）") }

    // MARK: - #8 人像遮罩包住了空隙

    static let wall = flat(0.55, 0.6, 0.7)

    /// 1.2 m 的人叉着腰：躯干、上臂、前臂围出一块空隙，露出后面 3 m 的墙；Vision 把空隙也算进了人像遮罩
    static func armGap(instances: Bool) -> Scene {
        let gap = rect(0.52, 0.58, 0.55, 0.75)
        return Scene(layers: [
            Layer(name: "墙", z: 3, color: wall, inside: { _, _ in true }),
            Layer(name: "人", z: 1.2, color: flat(0.7, 0.5, 0.4), inside: { x, y in
                (rect(0.4, 0.52, 0.2, 1)(x, y) || rect(0.52, 0.64, 0.45, 0.55)(x, y) || rect(0.58, 0.64, 0.45, 0.8)(x, y)) && !gap(x, y)
            }, person: true),
        ], focus: (0.46, 0.4), personMaskExtra: gap, instances: instances)
    }

    func testPersonMaskGapFollowsDepth() {
        for live in [false, true] {
            for instances in [true, false] {
                let s = Self.armGap(instances: instances)
                let r = Self.render(s, live: live)
                let gap = r.stats({ x, y in Self.rect(0.52, 0.58, 0.55, 0.75)(x, y) && r.interior("墙", margin: 1)(x, y) })
                let person = r.stats(r.interior("人"))
                let n = Self.name(live, s)
                print(String(format: "空隙 %@：墙 %.2f%%（应 %.2f%%，被拉清晰 %.0f%%），人 %.2f%%", n, gap.actual, gap.ideal, gap.sharp * 100, person.actual))
                XCTAssertGreaterThan(gap.n, 20)
                XCTAssertLessThan(gap.sharp, 0.05, "\(n)：遮罩包进来的空隙里是后面的墙，要按深度虚化")
                XCTAssertLessThan(person.actual, 0.15, "\(n)：人要清晰")
            }
        }
    }

    /// 问题 1 的另一种来路：Vision 自己把下巴、脖子和领口围出的空隙包进了人像遮罩，空隙里是 1.6 m 柜子上的黑白方格
    static func chinPocketInMask() -> Scene {
        let pocket = rect(0.50, 0.57, 0.50, 0.62)
        return Scene(layers: [
            Layer(name: "墙", z: 3, color: flat(0.8, 0.8, 0.78), inside: { _, _ in true }),
            Layer(name: "方格", z: 1.6, color: checker, inside: rect(0.36, 0.57, 0.46, 0.78)),
            Layer(name: "人", z: 0.87, color: { x, y in Float(y) / 720 >= 0.62 ? (0.02, 0.02, 0.025) : (0.55, 0.36, 0.27) },
                  inside: { x, y in rect(0.50, 0.66, 0.12, 0.50)(x, y) || rect(0.57, 0.66, 0.50, 0.62)(x, y)
                      || (x >= 0.40 && x < 0.95 && y >= 0.62) }, person: true),
        ], focus: (0.6, 0.35), personMaskExtra: pocket)
    }

    func testChinPocketInsideMaskFollowsDepth() {
        for live in [false, true] {
            let s = Self.chinPocketInMask()
            let r = Self.render(s, live: live)
            let pocket = r.stats({ x, y in Self.rect(0.50, 0.57, 0.50, 0.62)(x, y) && r.interior("方格", margin: 1)(x, y) })
            let far = r.stats(Self.rect(0.37, 0.45, 0.47, 0.55))
            let n = Self.name(live, s)
            print(String(format: "下巴空隙在遮罩里 %@：方格 %.2f%%（远处 %.2f%%，被拉清晰 %.0f%%）", n, pocket.actual, far.actual, pocket.sharp * 100))
            XCTAssertGreaterThan(pocket.n, 20)
            XCTAssertLessThan(pocket.sharp, 0.05, "\(n)：遮罩包进来的下巴空隙要按深度虚化")
        }
    }

    // MARK: - 例外照旧：点中的人自己身上的前后差

    /// 对焦 1.2 m 的脸；同一个人的胳膊伸向后面（1.6 m）、手伸向镜头（0.8 m），后面 3 m 的墙
    static func bodyDepthSpread(instances: Bool) -> Scene {
        Scene(layers: [
            Layer(name: "墙", z: 3, color: wall, inside: { _, _ in true }),
            Layer(name: "人胳膊", z: 1.6, color: flat(0.65, 0.45, 0.35), inside: rect(0.52, 0.75, 0.40, 0.48), person: true),
            Layer(name: "人", z: 1.2, color: flat(0.7, 0.5, 0.4), inside: rect(0.35, 0.52, 0.2, 1), person: true),
            Layer(name: "人手", z: 0.8, color: flat(0.72, 0.52, 0.42), inside: rect(0.25, 0.35, 0.6, 0.72), person: true),
        ], focus: (0.43, 0.35), instances: instances)
    }

    func testFocusedPersonOwnDepthSpreadStaysSharp() {
        for live in [false, true] {
            let s = Self.bodyDepthSpread(instances: true)
            let r = Self.render(s, live: live)
            let arm = r.stats(r.interior("人胳膊", margin: 1)), hand = r.stats(r.interior("人手", margin: 1))
            print(String(format: "人自己的前后差 %@：伸向后面的胳膊 %.2f%%，伸向镜头的手 %.2f%%", Self.name(live, s), arm.actual, hand.actual))
            XCTAssertLessThan(arm.actual, 0.15, "点中的人整体清晰：伸向后面的胳膊也清晰")
            XCTAssertLessThan(hand.actual, 0.15, "点中的人整体清晰：伸向镜头的手也清晰")
        }
    }

    /// 伸出去的手（接在胳膊末端、伸进背景里），深度被测成了后面 3 m 的墙：它是人自己（外面一圈大半是背景，不是被身体围着的空隙），
    /// 和 PersonSegmentationRegressionTests 里被挡断的手一样，照旧整体清晰
    func testMismeasuredHandAtArmEndStaysSharp() {
        for live in [false, true] {
            for instances in [true, false] {
                let s = Scene(layers: [
                    Layer(name: "墙", z: 3, color: Self.wall, inside: { _, _ in true }),
                    Layer(name: "人", z: 1.2, color: Self.flat(0.7, 0.5, 0.4), inside: { x, y in
                        Self.rect(0.35, 0.5, 0.2, 1)(x, y) || Self.rect(0.5, 0.66, 0.42, 0.48)(x, y) }, person: true),
                    Layer(name: "人手（深度测成了墙）", z: 3, color: Self.flat(0.72, 0.52, 0.42), inside: Self.rect(0.66, 0.74, 0.38, 0.52), person: true),
                ], focus: (0.42, 0.35), instances: instances)
                let r = Self.render(s, live: live)
                let hand = r.stats(r.interior("人手（深度测成了墙）", margin: 1))
                print(String(format: "深度测错的手 %@：%.2f%%", Self.name(live, s), hand.actual))
                if instances {
                    XCTAssertLessThan(hand.actual, 0.15, "\(Self.name(live, s))：点中的人伸出去的手，深度测错了也整体清晰")
                }
            }
        }
    }

    // MARK: - #11 没有人像实例时外扩的那一圈

    /// 没有人像实例：对焦 1.2 m 的人，2.5 m 的人站在他身后、画面上挨着（人像遮罩连成一片），后面 5 m 的墙
    static func personBehind() -> Scene {
        Scene(layers: [
            Layer(name: "墙", z: 5, color: flat(0.8, 0.8, 0.78), inside: { _, _ in true }),
            Layer(name: "后人", z: 2.5, color: flat(0.3, 0.35, 0.6), inside: rect(0.5, 0.75, 0.15, 1), person: true),
            Layer(name: "前人", z: 1.2, color: flat(0.7, 0.5, 0.4), inside: rect(0.25, 0.5, 0.3, 1), person: true),
        ], focus: (0.37, 0.6), instances: false)
    }

    func testWithoutInstancesPersonBehindIsNotPulledSharp() {
        for live in [false, true] {
            let s = Self.personBehind()
            let r = Self.render(s, live: live)
            // 挨着前人的那一条：修边那条不可信的带子（长边 1/80，这里 3 个深度像素）以外、画面宽 4% 以内
            let strip = r.stats({ x, y in x >= 0.5 + 4.0 / 240 && x < 0.54 && y >= 0.35 && y < 0.95 })
            let farther = r.stats(Self.rect(0.62, 0.72, 0.35, 0.95))
            let front = r.stats(r.interior("前人"))
            print(String(format: "身后的人（无实例）%@：贴着前人的一条 %.2f%%（被拉清晰 %.0f%%），远一点 %.2f%%，前人 %.2f%%",
                         Self.name(live, s), strip.actual, strip.sharp * 100, farther.actual, front.actual))
            XCTAssertLessThan(strip.sharp, 0.05, "没有实例时，挨着的、站在后面的人不能被拉清晰一条")
            XCTAssertLessThan(front.actual, 0.15)
        }
    }

    // MARK: - #6 #7 对焦物体时的颜色补边

    /// 对焦 0.7 m 的黑包（物体分割分得出来），后面 1.6 m 有黑白竖条（包两边紧挨着的都是黑条），3 m 的墙
    static func blackBag() -> Scene {
        Scene(layers: [
            Layer(name: "墙", z: 3, color: flat(0.8, 0.8, 0.78), inside: { _, _ in true }),
            Layer(name: "竖条", z: 1.6, color: stripes, inside: rect(0.25, 0.75, 0.3, 0.95)),
            Layer(name: "包", z: 0.7, color: flat(0.02, 0.02, 0.025), inside: rect(0.4, 0.6, 0.45, 0.95), object: true),
        ], focus: (0.5, 0.7))
    }

    func testObjectFocusColorDoesNotCrossObjectMask() {
        for live in [false, true] {
            let s = Self.blackBag()
            let r = Self.render(s, live: live)
            // 包两边 4% 以内的黑条（紧贴包的一个深度像素不算：种子本身的软边，同 ChinPocketColorLeakTests）
            let e: Float = 1.0 / 240
            let near = r.stats({ x, y in (x >= 0.36 && x < 0.4 - e || x >= 0.6 + e && x < 0.64) && y >= 0.5 && y < 0.9 }, dark: true)
            let bag = r.stats(r.interior("包"))
            print(String(format: "黑包 %@：旁边黑条被拉清晰 %.0f%%（共 %d），包 %.2f%%", Self.name(live, s), near.sharp * 100, near.n, bag.actual))
            XCTAssertGreaterThan(near.n, 20)
            XCTAssertLessThan(near.sharp, 0.01, "对焦物体时，物体遮罩外面和它同色的东西不能被拉清晰")
            XCTAssertLessThan(bag.actual, 0.15)
        }
    }
}
