import XCTest
@testable import BokehCore

/// 问题 2（录屏 yanjing-queshao、调试录制 rec-20261109-152800）：侧脸时远处那片镜片伸出脸的轮廓，
/// LiDAR 穿过透明镜片测到后面的墙，Vision 人像遮罩的 0.5 那条线也把它切在外面（只在 0.1～0.5 的软边里），
/// 镜片和镜框被当成背景虚化掉。眼镜带（FaceBand）里把软边算成人以后要保住；眼镜带以外的软边照旧不算（不多出光晕）。
///
/// 场景按调试录制搭：1.2 m 的人侧脸朝左，镜片伸出脸前沿约画面宽的 1.5%，镜片里的深度是 3 m 的墙；
/// 人像遮罩是软边（边上 0.5，往外约 8 个遮罩像素降到 0.1），镜片外半截在 0.5 外面。
final class GlassesBandTests: XCTestCase {
    typealias T = DepthFirstRegressionTests

    static let lens = T.rect(0.385, 0.40, 0.30, 0.335)

    /// 镜片：一圈 3 像素宽的深色镜框，中间是透明的（透出后面的墙）
    static func lensColor(_ ix: Int, _ iy: Int) -> (Float, Float, Float) {
        let x0 = Int(0.385 * 960), x1 = Int(0.40 * 960), y0 = Int(0.30 * 720), y1 = Int(0.335 * 720)
        let rim = ix - x0 < 3 || x1 - 1 - ix < 3 || iy - y0 < 3 || y1 - 1 - iy < 3
        return rim ? (0.05, 0.05, 0.06) : (0.74, 0.77, 0.79)
    }

    static func isBody(_ x: Float, _ y: Float) -> Bool {
        T.rect(0.40, 0.55, 0.15, 0.55)(x, y) || T.rect(0.35, 0.60, 0.55, 1)(x, y)
    }

    /// 相机肩带（调试录制 rec-20261109-160836）：人身后约 2 m（3.2 m）的一条深色带子，从镜片外侧往前伸出去，
    /// 在眼睛那一条里。颜色深，Vision 的软边把它也裹了进去
    /// 带子末端离镜片还有一点（中间是遮罩软边以外的墙），录屏里也是这样（镜框外侧和带子之间露着背景）
    static let strap = T.rect(0.30, 0.37, 0.285, 0.315)
    /// 直接挨着镜片：LiDAR 下镜片也测成后面的墙，分不开，按深度来（镜框可能软一点，带子一定要糊）
    static let strapTouching = T.rect(0.30, 0.385, 0.285, 0.315)
    static func strapColor(_ ix: Int, _ iy: Int) -> (Float, Float, Float) {
        (ix / 6 + iy / 6) % 3 == 0 ? (0.55, 0.25, 0.08) : (0.04, 0.04, 0.045)
    }

    /// Vision 那样的软边遮罩（480×360）：人里面 1；外面按离人的距离 d（遮罩像素）是 0.5 − d / 20，镜片外半截在 0.5 外面。
    /// wrapStrap：肩带也在软边里（0.3），和 Vision 在录制里给的一样
    /// lensInMask：镜片在 0.5 那条线里面（0.6），离人近的软边从镜片边上量起（rec-20261109-182630 里 Vision 的样子）
    static func softMask(wrapStrap: ((Float, Float) -> Bool)? = nil, lensInMask: Bool = false) -> FloatMap {
        let w = 480, h = 360
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let nx = (Float(x) + 0.5) / Float(w), ny = (Float(y) + 0.5) / Float(h)
            if isBody(nx, ny) || (lensInMask && lens(nx, ny)) { inside[y * w + x] = true }
        } }
        var v = [Float](repeating: 0, count: w * h)
        let R = 10
        for y in 0..<h {
            for x in 0..<w {
                if inside[y * w + x] {
                    let nx = (Float(x) + 0.5) / Float(w), ny = (Float(y) + 0.5) / Float(h)
                    v[y * w + x] = isBody(nx, ny) ? 1 : 0.6
                    continue
                }
                var best = Float.infinity
                for yy in max(0, y - R)...min(h - 1, y + R) {
                    for xx in max(0, x - R)...min(w - 1, x + R) where inside[yy * w + xx] {
                        let dx = Float(xx - x), dy = Float(yy - y)
                        best = min(best, (dx * dx + dy * dy).squareRoot())
                    }
                }
                if best.isFinite { v[y * w + x] = max(0, 0.5 - best / 20) }
                if let wrapStrap, wrapStrap((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h)) {
                    v[y * w + x] = max(v[y * w + x], 0.3)
                }
            }
        }
        return FloatMap(width: w, height: h, values: v)
    }

    /// 人脸框（正立方向，左上角为原点）：脸前沿 0.40，眉毛到下巴
    static let face = FaceBand.Face(x: 0.40, y: 0.20, width: 0.15, height: 0.35)

    /// 整截都在离脸不远处、直接挨着镜片的肩带（调试录制 rec-20261109-182630，2× 双摄）：眼镜带分不开，
    /// 软边里离脸 cap 以内的都收，它就被拉清晰了。拍照时有 Apple 的眼镜遮罩就分得开
    static let strapShort = T.rect(0.372, 0.385, 0.285, 0.315)

    /// Apple 拍照时给的眼镜遮罩（AVSemanticSegmentationMatte .glasses，照片一半分辨率），照拍照调试包
    /// photo-20261110-095906 的样子：镜片上 0.45～0.6，周围一圈 0.1～0.2 的毛边，贴着镜片的背景里的东西 ≤ 0.2
    /// leak：眼镜遮罩漏到背景上的地方（拍照调试包 photo-20261110-103706：镜框铰链外面那块背景上有 0.25～0.9）
    static func glassesMatte(leak: ((Float, Float) -> Bool)? = nil) -> FloatMap {
        let w = 480, h = 360
        var v = [Float](repeating: 0, count: w * h)
        let x0 = Int(0.385 * Float(w)), x1 = Int(0.40 * Float(w)), y0 = Int(0.30 * Float(h)), y1 = Int(0.335 * Float(h))
        for y in 0..<h {
            for x in 0..<w {
                let dx = max(x0 - x, 0, x - (x1 - 1)), dy = max(y0 - y, 0, y - (y1 - 1))
                let d = max(dx, dy)
                v[y * w + x] = d == 0 ? 0.55 : (d <= 3 ? 0.18 : 0)
                if let leak, leak((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h)) {
                    v[y * w + x] = max(v[y * w + x], 0.7)
                }
            }
        }
        return FloatMap(width: w, height: h, values: v)
    }

    /// lensZ：镜片里测到的深度。3 = LiDAR 穿过镜片测到后面的墙；1.2 = 双摄在镜框上测得出镜片（rec-20261109-182630）
    static func scene(focusOnPerson: Bool, band: Bool, strap withStrap: ((Float, Float) -> Bool)? = nil,
                      glasses: Bool = false, lensZ: Float = 3, lensInMask: Bool = false,
                      glassesLeak: ((Float, Float) -> Bool)? = nil, glassesFollowDepth: Bool = false) -> T.Scene {
        T.Scene(layers: [
            T.Layer(name: "墙", z: 3, color: T.flat(0.82, 0.82, 0.80), inside: { _, _ in true }),
            T.Layer(name: "椅子", z: 1.2, color: T.flat(0.2, 0.2, 0.22), inside: T.rect(0.68, 0.85, 0.4, 0.95)),
            T.Layer(name: "肩带", z: 3.2, color: strapColor, inside: withStrap ?? { _, _ in false }),
            T.Layer(name: "镜片", z: lensZ, color: lensColor, inside: lens),
            T.Layer(name: "人", z: 1.2, color: { _, iy in Float(iy) / 720 < 0.22 ? (0.03, 0.03, 0.035) : (0.62, 0.45, 0.36) },
                    inside: { x, y in isBody(x, y) }, person: true),
        ], focus: focusOnPerson ? (0.47, 0.4) : (0.76, 0.6),
           personMaskOverride: softMask(wrapStrap: withStrap, lensInMask: lensInMask),
           faceBand: band ? FaceBand.map([face], width: 480, height: 360) : nil,
           glassesMatte: glasses ? glassesMatte(leak: glassesLeak) : nil, glassesFollowDepth: glassesFollowDepth)
    }

    /// 镜框（深色那一圈）的虚化中位数
    static func rimBlur(_ r: T.Result) -> Float {
        r.stats({ x, y in lens(x, y) }, dark: true).actual
    }

    func testGlassesOutsideMaskStaySharpWithFaceBand() {
        for live in [false, true] {
            for onPerson in [true, false] {
                let name = (live ? "预览" : "拍照") + (onPerson ? "，对焦在人身上" : "，对焦在旁边一样远的椅子上")
                let without = T.render(Self.scene(focusOnPerson: onPerson, band: false), live: live)
                let with = T.render(Self.scene(focusOnPerson: onPerson, band: true), live: live)
                let a = Self.rimBlur(without), b = Self.rimBlur(with)
                // 光晕：眼镜带以外、紧挨着头顶和额头前面的那圈墙（软边里），照旧要糊
                let halo = with.stats({ x, y in
                    (T.rect(0.38, 0.40, 0.15, 0.24)(x, y) || T.rect(0.40, 0.55, 0.13, 0.15)(x, y)) && !Self.isBody(x, y)
                })
                print(String(format: "眼镜 %@：镜框 没有眼镜带 %.2f%% → 有 %.2f%%；头顶额头外面的墙 %.2f%%（被拉清晰 %.0f%%）",
                             name, a, b, halo.actual, halo.sharp * 100))
                XCTAssertGreaterThan(a, 0.15, "\(name)：场景要能复现问题（没有眼镜带时镜框被当成背景虚化）")
                XCTAssertLessThan(b, 0.15, "\(name)：眼镜带里伸出脸外的镜框要清晰")
                XCTAssertLessThan(halo.sharp, 0.05, "\(name)：眼镜带以外，人像遮罩的软边不能算人（不多出光晕）")
            }
        }
    }

    /// 肩带在眼镜带里、也被 Vision 的软边裹着，但深度测得出它在人身后 2 m：照常虚化；镜框照样清晰
    func testBackgroundObjectInFaceBandFollowsDepth() {
        for live in [false, true] {
            for onPerson in [true, false] {
                let name = (live ? "预览" : "拍照") + (onPerson ? "，对焦在人身上" : "，对焦在旁边一样远的椅子上")
                for touching in [false, true] {
                    let region = touching ? Self.strapTouching : Self.strap
                    let r = T.render(Self.scene(focusOnPerson: onPerson, band: true, strap: region), live: live)
                    // 肩带：紧挨着镜片的一个深度像素不算（种子本身的软边）
                    let e: Float = 1.0 / 240
                    let strapStats = r.stats({ x, y in region(x, y) && x < 0.385 - e })
                    let rim = Self.rimBlur(r)
                    print(String(format: "肩带%@ %@：肩带 %.2f%%（应 %.2f%%，被拉清晰 %.0f%%），镜框 %.2f%%",
                                 touching ? "（挨着镜片）" : "", name, strapStats.actual, strapStats.ideal,
                                 strapStats.sharp * 100, rim))
                    XCTAssertGreaterThan(strapStats.n, 20)
                    XCTAssertLessThan(strapStats.sharp, 0.05, "\(name)：眼镜带里、深度在后面的东西（肩带）要按深度虚化")
                    if !touching { XCTAssertLessThan(rim, 0.15, "\(name)：镜框照样清晰") }
                }
            }
        }
    }

    /// 拍照有 Apple 的眼镜遮罩时用它代替眼镜带：镜片（在眼镜遮罩里）清晰，挨着镜片的肩带（不在里面，深度在后面）照常虚化。
    /// 只有眼镜带时两种测法各有一个分不开（场景要能复现问题）：
    ///  - 双摄测得出镜片（镜片 ≈ 脸的深度，Vision 也把镜片算进 0.5 里）：整截肩带都在离人 cap 以内，软边里的都收，
    ///    肩带被拉清晰（rec-20261109-182630）
    ///  - LiDAR 把镜片测成后面的墙：肩带顺着软边连到镜片上，镜片跟着不收，镜框被虚化（已知问题）
    func testPhotoGlassesMatteSeparatesLensFromStrap() {
        let e: Float = 1.0 / 240
        for lensZ: Float in [1.2, 3] {
            for onPerson in [true, false] {
                let name = (lensZ < 2 ? "双摄" : "LiDAR") + (onPerson ? "，对焦在人身上" : "，对焦在旁边一样远的椅子上")
                func measure(_ s: T.Scene) -> (strap: (actual: Float, ideal: Float, sharp: Float, n: Int), rim: Float) {
                    let r = T.render(s, live: false)
                    return (r.stats({ x, y in Self.strapShort(x, y) && x < 0.385 - e }), Self.rimBlur(r))
                }
                let inMask = lensZ < 2
                let band = measure(Self.scene(focusOnPerson: onPerson, band: true, strap: Self.strapShort,
                                              lensZ: lensZ, lensInMask: inMask))
                let glasses = measure(Self.scene(focusOnPerson: onPerson, band: true, strap: Self.strapShort,
                                                 glasses: true, lensZ: lensZ, lensInMask: inMask))
                print(String(format: "拍照 %@：只有眼镜带 肩带被拉清晰 %.0f%%、镜框 %.2f%%；有眼镜遮罩 肩带 %.2f%%（应 %.2f%%，被拉清晰 %.0f%%）、镜框 %.2f%%",
                             name, band.strap.sharp * 100, band.rim, glasses.strap.actual, glasses.strap.ideal,
                             glasses.strap.sharp * 100, glasses.rim))
                XCTAssertGreaterThan(band.strap.n, 10)
                XCTAssertTrue(band.strap.sharp > 0.3 || band.rim > 0.15,
                              "\(name)：场景要能复现问题（只有眼镜带时肩带被拉清晰，或者镜框被虚化）")
                XCTAssertLessThan(glasses.strap.sharp, 0.05, "\(name)：不在眼镜遮罩里、深度在后面的肩带要按深度虚化")
                XCTAssertLessThan(glasses.rim, 0.15, "\(name)：眼镜遮罩里的镜框要清晰")
            }
        }
        // 眼镜遮罩以外的软边不算人（眼镜遮罩的毛边也不算）：头顶、额头外面那圈墙照旧糊
        let r = T.render(Self.scene(focusOnPerson: true, band: true, glasses: true), live: false)
        let halo = r.stats({ x, y in
            (T.rect(0.38, 0.40, 0.15, 0.24)(x, y) || T.rect(0.40, 0.55, 0.13, 0.15)(x, y)) && !Self.isBody(x, y)
        })
        XCTAssertLessThan(halo.sharp, 0.05)
    }

    /// Apple 的眼镜遮罩自己也会漏到贴着镜框的背景上（拍照调试包 photo-20261110-103706，2× 双摄：镜框铰链外面
    /// 那块背景上遮罩值 0.25～0.9，深度明明测出它在后面）。双摄测得出镜框，眼镜遮罩也要先看深度：
    /// 遮罩里深度在后面、又顺着「深度在后面」连到遮罩外面背景的不算眼镜；镜框照样清晰。
    /// LiDAR 测不出镜片（glassesFollowDepth 关着）：照旧信眼镜遮罩，结果和以前一样
    func testPhotoGlassesMatteLeakFollowsDepth() {
        let e: Float = 1.0 / 240
        for onPerson in [true, false] {
            let name = "双摄" + (onPerson ? "，对焦在人身上" : "，对焦在旁边一样远的椅子上")
            func measure(follow: Bool) -> (strap: (actual: Float, ideal: Float, sharp: Float, n: Int), rim: Float) {
                let r = T.render(Self.scene(focusOnPerson: onPerson, band: true, strap: Self.strapShort, glasses: true,
                                            lensZ: 1.2, lensInMask: true, glassesLeak: Self.strapShort,
                                            glassesFollowDepth: follow), live: false)
                return (r.stats({ x, y in Self.strapShort(x, y) && x < 0.385 - e }), Self.rimBlur(r))
            }
            let trusted = measure(follow: false), gated = measure(follow: true)
            print(String(format: "眼镜遮罩漏到肩带上 %@：只信遮罩 肩带被拉清晰 %.0f%%、镜框 %.2f%%；先看深度 肩带 %.2f%%（应 %.2f%%，被拉清晰 %.0f%%）、镜框 %.2f%%",
                         name, trusted.strap.sharp * 100, trusted.rim, gated.strap.actual, gated.strap.ideal,
                         gated.strap.sharp * 100, gated.rim))
            XCTAssertGreaterThan(trusted.strap.n, 10)
            XCTAssertGreaterThan(trusted.strap.sharp, 0.3, "\(name)：场景要能复现问题（只信眼镜遮罩时漏出去的那块被拉清晰）")
            XCTAssertLessThan(gated.strap.sharp, 0.05, "\(name)：眼镜遮罩漏到的背景深度在后面，要按深度虚化")
            XCTAssertLessThan(gated.rim, 0.15, "\(name)：镜框照样清晰")
            // 双摄也测不出镜片的时候（侧得厉害，镜片测成后面的墙，成片 IMG_2354）：镜片是从脸边上伸出去的，
            // 先看深度也不能把它去掉。这时候分不出漏出去的那块，照旧信眼镜遮罩（和不看深度一样）
            let blind = T.render(Self.scene(focusOnPerson: onPerson, band: true, strap: Self.strapShort, glasses: true,
                                            lensZ: 3, lensInMask: false, glassesLeak: Self.strapShort,
                                            glassesFollowDepth: true), live: false)
            let blindRim = Self.rimBlur(blind)
            print(String(format: "  双摄测不出镜片：镜框 %.2f%%", blindRim))
            XCTAssertLessThan(blindRim, 0.15, "\(name)：深度测不出镜片时，先看深度也不能把镜片虚化")
        }
    }

    /// 眼镜遮罩先看深度的规则本身（SubjectMatte.glassesAccessories）：
    ///  - 漏到背景上的那块（深度在后面，连着遮罩外面的背景）不收；
    ///  - 镜片中间测远了的洞（四周是近处的镜框，连不到外面）照收；
    ///  - 不给深度（LiDAR）：和以前一样全收
    func testGlassesMatteDepthGateKeepsEnclosedLensHole() throws {
        let w = 60, h = 40
        var g = [Float](repeating: 0, count: w * h), m = g
        var d = [Float](repeating: 1.0 / 3, count: w * h)
        func fill(_ a: inout [Float], _ xs: Range<Int>, _ ys: Range<Int>, _ v: Float) {
            for y in ys { for x in xs { a[y * w + x] = v } }
        }
        fill(&m, 30..<60, 0..<40, 1); fill(&d, 30..<60, 0..<40, 1 / 1.2)      // 人
        fill(&g, 20..<32, 10..<26, 0.6); fill(&d, 20..<30, 10..<26, 1 / 1.2)   // 伸出脸外的镜片（双摄测得出）
        fill(&d, 23..<27, 14..<21, 1.0 / 3)                                    // 镜片中间测远了的洞
        fill(&g, 12..<20, 10..<17, 0.8)                                        // 遮罩漏到背景上的一块
        let glasses = FloatMap(width: w, height: h, values: g), person = FloatMap(width: w, height: h, values: m)
        let depth = FloatMap(width: w, height: h, values: d)
        let lens = LensParameters(fNumber: 1.4, focusDisparity: 1 / 1.2)
        let p = SubjectMatteParameters()
        let trusted = try XCTUnwrap(SubjectMatte.glassesAccessories(glasses, person: person, width: w, height: h,
                                                                    parameters: p, band: 2))
        let gated = try XCTUnwrap(SubjectMatte.glassesAccessories(glasses, person: person, width: w, height: h,
                                                                  parameters: p, band: 2, depth: depth, lens: lens))
        XCTAssertEqual(trusted[15, 13], 1, "不给深度：照旧信眼镜遮罩")
        XCTAssertEqual(gated[15, 13], 0, "漏到背景上的那块：深度在后面、连着外面的背景，不算眼镜")
        XCTAssertEqual(gated[18, 11], 0)
        XCTAssertEqual(gated[25, 17], 1, "镜片中间测远了的洞：被镜框围住，照样算眼镜")
        XCTAssertEqual(gated[21, 12], 1, "镜框")
        XCTAssertEqual(gated[21, 24], 1)
        // 深度测不出镜片（整片镜片都测成后面的墙）：镜片挨着脸，不能去掉；连着它的那块也分不出来，照旧信遮罩
        fill(&d, 20..<30, 10..<26, 1.0 / 3)
        let blind = try XCTUnwrap(SubjectMatte.glassesAccessories(
            glasses, person: person, width: w, height: h, parameters: p, band: 2,
            depth: FloatMap(width: w, height: h, values: d), lens: lens))
        XCTAssertEqual(blind[21, 12], 1, "镜片测成了背景，但它是从脸边上伸出去的：照样算眼镜")
        XCTAssertEqual(blind[25, 17], 1)
        XCTAssertEqual(zip(blind.values, trusted.values).filter { $0 != $1 }.count, 0, "深度测不出镜片时和不看深度一样")
    }

    func testFaceBandGeometry() throws {
        // 正脸、不歪头：眉毛到颧骨那一条，左右各伸出脸宽的 30%
        let m = try XCTUnwrap(FaceBand.map([Self.face], width: 480, height: 360))
        func at(_ x: Float, _ y: Float) -> Float { m[min(479, Int(x * 480)), min(359, Int(y * 360))] }
        XCTAssertEqual(at(0.39, 0.32), 1, "脸前沿外面、眼睛高度：在带里")
        XCTAssertEqual(at(0.47, 0.25), 1)
        XCTAssertEqual(at(0.47, 0.21), 0, "额头：不在带里")
        XCTAssertEqual(at(0.47, 0.50), 0, "下巴：不在带里")
        XCTAssertEqual(at(0.30, 0.32), 0, "离脸太远：不在带里")
        // 歪头：两个方向都转一遍取并集，带子变宽但还包住原来的
        var tilted = Self.face
        tilted.roll = 0.3
        let t = try XCTUnwrap(FaceBand.map([tilted], width: 480, height: 360))
        XCTAssertEqual(t[Int(0.39 * 480), Int(0.32 * 360)], 1)
        XCTAssertGreaterThan(t.values.reduce(0, +), m.values.reduce(0, +))
        XCTAssertNil(FaceBand.map([], width: 480, height: 360))
    }
}
