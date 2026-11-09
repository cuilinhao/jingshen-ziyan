import XCTest
@testable import BokehCore

/// 录屏 xiba-wenti / 24-xiaba（1106）：穿黑衣服的人对焦在脸上，下巴、脖子和领口围出的那一小块空隙里露出后面柜子上的黑白方格。
/// 方格在 1.6 m，按镜头应该和柜子其他地方一样糊；demo 里贴着领口的那几排黑格却完全清晰，越往外越糊。
///
/// 原因：颜色补边（growByColor）和彩色引导滤波 α 只看颜色，黑格和黑衣服、头发一个颜色，就被当成人拉回对焦面。
/// 人像遮罩明明说那里不是人，深度也明明在后面。
///
/// 这里按录屏搭一个合成场景（分辨率比例和实时预览、拍照一致），实时预览和拍照两条路径、LiDAR 和双摄都跑，
/// 读出低分辨率上最终的视差（和 GPU 版逐像素一致），比较空隙里的方格和远离人的方格虚化了多少。
final class ChinPocketColorLeakTests: XCTestCase {

    // 场景里的距离（米）
    static let personZ: Float = 0.87, cardZ: Float = 1.6, wallZ: Float = 3.0

    enum Part { case wall, card, skin, hair, sweater }

    /// 归一化坐标 → 这一点是什么
    static func part(_ x: Float, _ y: Float) -> Part {
        let head = x >= 0.50 && x < 0.66 && y >= 0.12 && y < 0.50
        let neck = x >= 0.57 && x < 0.66 && y >= 0.50 && y < 0.62
        let sweater = x >= 0.40 && x < 0.95 && y >= 0.62
        if sweater { return .sweater }
        if head { return y < 0.22 ? .hair : .skin }
        if neck { return .skin }
        if x >= 0.36 && x < 0.57 && y >= 0.46 && y < 0.78 { return .card }
        return .wall
    }

    static func isPerson(_ p: Part) -> Bool { p == .skin || p == .hair || p == .sweater }

    /// 柜子上贴的东西：黑白方格（8 像素一格，960 宽的图上；预览里一格约 9～10 个输出像素），
    /// 或者竖条（黑条和领口连着，颜色补边能顺着它一路往上补，模拟后面黑色的椅背、线）
    enum Pattern { case checker, stripes }

    static func cardColor(ix: Int, iy: Int, _ pattern: Pattern) -> (Float, Float, Float) {
        let dark = pattern == .checker ? (ix / 8 + iy / 8) % 2 == 0 : (ix / 8) % 2 == 0
        return dark ? (0.015, 0.015, 0.02) : (0.82, 0.82, 0.8)
    }

    static func color(_ p: Part, ix: Int, iy: Int, _ pattern: Pattern) -> (Float, Float, Float) {
        switch p {
        case .wall: return (0.8, 0.8, 0.78)
        case .card: return cardColor(ix: ix, iy: iy, pattern)
        case .skin: return (0.55, 0.36, 0.27)
        case .hair: return (0.03, 0.03, 0.035)
        case .sweater: return (0.02, 0.02, 0.025)
        }
    }

    struct Scene {
        var image: PlanarImage
        var disparity: FloatMap
        var person: FloatMap
        var instances: FloatMap
        var relative: Bool
        var focal: Float
        var pattern: Pattern
    }

    enum Source { case lidar, dual }

    static func makeScene(_ source: Source, _ pattern: Pattern = .checker) -> Scene {
        let iw = 960, ih = 720
        var r = [Float](repeating: 0, count: iw * ih), g = r, b = r
        for y in 0..<ih {
            for x in 0..<iw {
                let p = part((Float(x) + 0.5) / Float(iw), (Float(y) + 0.5) / Float(ih))
                let c = color(p, ix: x, iy: y, pattern)
                r[y * iw + x] = c.0; g[y * iw + x] = c.1; b[y * iw + x] = c.2
            }
        }
        // 深度图：LiDAR 240×180，双摄 320×240；边缘被滤波抹开（双摄更宽）
        let (dw, dh, smear): (Int, Int, Int) = source == .lidar ? (240, 180, 1) : (320, 240, 2)
        var d = [Float](repeating: 0, count: dw * dh)
        for y in 0..<dh {
            for x in 0..<dw {
                let p = part((Float(x) + 0.5) / Float(dw), (Float(y) + 0.5) / Float(dh))
                let z = isPerson(p) ? personZ : (p == .card ? cardZ : wallZ)
                d[y * dw + x] = 1 / z + (source == .dual ? 0.3 : 0)
            }
        }
        d = ScenarioMatrixTests.boxBlur(d, w: dw, h: dh, r: smear)
        // 人像遮罩（Vision balanced 约 480 宽）：只有人，空隙不在里面
        let mw = 480, mh = 360
        var m = [Float](repeating: 0, count: mw * mh)
        for y in 0..<mh {
            for x in 0..<mw where isPerson(part((Float(x) + 0.5) / Float(mw), (Float(y) + 0.5) / Float(mh))) {
                m[y * mw + x] = 1
            }
        }
        return Scene(image: PlanarImage(width: iw, height: ih, r: r, g: g, b: b),
                     disparity: FloatMap(width: dw, height: dh, values: d),
                     person: FloatMap(width: mw, height: mh, values: m),
                     instances: FloatMap(width: mw, height: mh, values: m),
                     relative: source == .dual, focal: source == .lidar ? 24 : 48, pattern: pattern)
    }

    static let focus: (x: Float, y: Float) = (0.6, 0.35)   // 脸颊

    /// 实时预览：和 App 一样走 LivePreviewPipeline，返回 (镜头, 低分辨率上最终的视差)
    static func live(_ s: Scene) -> (LensParameters, FloatMap)? {
        let pipeline = LivePreviewPipeline()
        pipeline.renderer.captureDebugMaps = true
        for t in 0..<8 {
            _ = pipeline.process(LivePreviewPipeline.Frame(
                image: s.image, disparity: s.disparity, relativeDepth: s.relative, crop: 1, fNumber: 1.4,
                focusPoint: focus, focusTapped: t == 0, time: Double(t) / 30, personMask: s.person,
                personInstances: s.instances, focalLength35mm: s.focal))
        }
        guard let plan = pipeline.lastPlan, let d = pipeline.renderer.debugLowDisparity else { return nil }
        return (plan.lens, d)
    }

    /// 拍照：stillPlan + 编辑器的 CPU 渲染（GPU 版和它逐像素一致）
    static func still(_ s: Scene) -> (LensParameters, FloatMap)? {
        var settings = LiveFrameAnalyzer.Settings()
        settings.layersPerSide = RenderQuality.photo.layersPerSide
        let plan = LiveFrameAnalyzer.stillPlan(
            disparity: s.disparity, relativeDepth: s.relative, colors: s.image.resized(width: s.disparity.width,
                                                                                         height: s.disparity.height),
            fNumber: 1.4, focusPoint: focus, personMask: s.person, outputLongSide: s.image.longSide,
            settings: settings, personInstances: s.instances, focalLength35mm: s.focal)
        let renderer = BokehRenderer()
        renderer.captureDebugMaps = true
        let hint = plan.seeds.map { SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: $0) }
        _ = renderer.renderDetailPreserving(full: s.image, disparity: plan.depth, lens: plan.lens,
                                            lowLongSide: plan.lowLongSide, quality: .photo, subject: hint,
                                            layerCenters: plan.layerCenters)
        guard let d = renderer.debugLowDisparity else { return nil }
        return (plan.lens, d)
    }

    /// 区域里（低分辨率像素）虚化半径的中位数（按长边 %）；dark = true 只看黑格
    static func medianBlur(_ lens: LensParameters, _ d: FloatMap, _ s: Scene, x0: Float, x1: Float, y0: Float, y1: Float,
                           dark: Bool? = nil, want: (Part) -> Bool) -> Float {
        var v: [Float] = []
        let L = 1000
        for y in 0..<d.height {
            for x in 0..<d.width {
                let nx = (Float(x) + 0.5) / Float(d.width), ny = (Float(y) + 0.5) / Float(d.height)
                guard nx >= x0, nx < x1, ny >= y0, ny < y1, want(part(nx, ny)) else { continue }
                if let dark {
                    // 低分辨率一个像素盖住的整张图像素都是黑格（白格）才算
                    let ix0 = Int(Float(x) / Float(d.width) * Float(s.image.width))
                    let iy0 = Int(Float(y) / Float(d.height) * Float(s.image.height))
                    let k = s.image.width / d.width
                    var all = true
                    for yy in iy0..<(iy0 + k) { for xx in ix0..<(ix0 + k) where (cardColor(ix: xx, iy: yy, s.pattern).0 < 0.5) != dark { all = false } }
                    guard all else { continue }
                }
                v.append(abs(lens.signedBlurRadius(disparity: d[x, y], imageLongSide: L)) / Float(L) * 100)
            }
        }
        guard !v.isEmpty else { return .nan }
        v.sort()
        return v[v.count / 2]
    }

    /// 低分辨率像素盖住的图像像素全是黑格
    static func coversOnlyDark(_ s: Scene, _ d: FloatMap, x: Int, y: Int) -> Bool {
        let k = s.image.width / d.width
        for yy in (y * k)..<(y * k + k) { for xx in (x * k)..<(x * k + k) where cardColor(ix: xx, iy: yy, s.pattern).0 > 0.5 { return false } }
        return true
    }

    /// 离人 reach 以内（低分辨率像素）的黑格里，虚化不到 limit（按长边 %）的占多少。
    /// 录屏里的毛病就是这一圈：贴着领口、下巴的黑格被拉清晰，再往外才糊。
    /// 紧贴人的 edge 个像素（一个深度像素宽）不算：人像种子在深度图分辨率上，边上本来就有这么宽的软边，
    /// 对着白墙也一样，不是颜色带出去的
    static func sharpDarkFraction(_ lens: LensParameters, _ d: FloatMap, _ s: Scene, reach: Int, edge: Int,
                                  limit: Float) -> (Float, Int) {
        let w = d.width, h = d.height
        var person = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where isPerson(part((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))) {
            person[y * w + x] = 1
        } }
        let near = SubjectMatte.dilateBinary(person, width: w, height: h, radius: reach)
        let touching = SubjectMatte.dilateBinary(person, width: w, height: h, radius: edge)
        var n = 0, sharp = 0
        for y in 0..<h {
            for x in 0..<w where near[y * w + x] > 0 && touching[y * w + x] == 0 {
                guard part((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h)) == .card,
                      coversOnlyDark(s, d, x: x, y: y) else { continue }
                n += 1
                if abs(lens.signedBlurRadius(disparity: d[x, y], imageLongSide: 1000)) / 10 < limit { sharp += 1 }
            }
        }
        return (n > 0 ? Float(sharp) / Float(n) : 0, n)
    }

    func check(_ source: Source, still: Bool, _ pattern: Pattern = .checker) throws {
        let s = Self.makeScene(source, pattern)
        let (lens, d) = try XCTUnwrap(still ? Self.still(s) : Self.live(s))
        let name = "\(source == .lidar ? "LiDAR" : "双摄") \(still ? "拍照" : "预览") \(pattern == .checker ? "方格" : "竖条")"
        // 远离人的方格（离头、衣服都在 0.05 以上）：按镜头该糊多少
        let far = Self.medianBlur(lens, d, s, x0: 0.37, x1: 0.45, y0: 0.47, y1: 0.55) { $0 == .card }
        // 下巴、脖子、领口围出的空隙里的方格
        let pocket = Self.medianBlur(lens, d, s, x0: 0.50, x1: 0.57, y0: 0.50, y1: 0.62) { $0 == .card }
        // 离人 4% 长边以内的黑格：有多少被拉清晰（虚化不到远处的一半）
        let reach = max(2, Int(0.04 * Float(max(d.width, d.height))))
        let edge = Int((Float(d.width) / Float(s.disparity.width)).rounded(.up))
        let (sharpDark, nDark) = Self.sharpDarkFraction(lens, d, s, reach: reach, edge: edge, limit: 0.5 * far)
        // 人：脸、衣服
        let face = Self.medianBlur(lens, d, s, x0: 0.52, x1: 0.64, y0: 0.25, y1: 0.48) { $0 == .skin }
        let sweater = Self.medianBlur(lens, d, s, x0: 0.42, x1: 0.9, y0: 0.64, y1: 0.95) { $0 == .sweater }
        print(String(format: "%@：远处方格 %.2f%%，空隙方格 %.2f%%，贴着人的黑格被拉清晰 %.1f%%（共 %d 个像素），脸 %.2f%%，衣服 %.2f%%",
                     name, far, pocket, sharpDark * 100, nDark, face, sweater))
        XCTAssertGreaterThan(far, 0.4, "\(name)：远处方格本来就该明显虚化")
        XCTAssertGreaterThan(nDark, 50)
        XCTAssertGreaterThan(pocket, 0.7 * far, "\(name)：空隙里的方格要和柜子其他地方一样糊")
        XCTAssertLessThan(sharpDark, 0.01, "\(name)：贴着领口、下巴的黑格不能因为和黑衣服同色被拉清晰")
        XCTAssertLessThan(face, 0.15, "\(name)：脸要清晰")
        XCTAssertLessThan(sweater, 0.15, "\(name)：衣服要清晰")
    }

    func testLidarLiveDarkCheckerInChinPocketStaysBlurred() throws { try check(.lidar, still: false) }
    func testLidarStillDarkCheckerInChinPocketStaysBlurred() throws { try check(.lidar, still: true) }
    func testDualLiveDarkCheckerInChinPocketStaysBlurred() throws { try check(.dual, still: false) }
    func testDualStillDarkCheckerInChinPocketStaysBlurred() throws { try check(.dual, still: true) }
    func testLidarLiveDarkStripesNextToCollarStayBlurred() throws { try check(.lidar, still: false, .stripes) }
    func testLidarStillDarkStripesNextToCollarStayBlurred() throws { try check(.lidar, still: true, .stripes) }
    func testDualLiveDarkStripesNextToCollarStayBlurred() throws { try check(.dual, still: false, .stripes) }
    func testDualStillDarkStripesNextToCollarStayBlurred() throws { try check(.dual, still: true, .stripes) }
}
