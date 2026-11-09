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

    /// Vision 那样的软边遮罩（480×360）：人里面 1；外面按离人的距离 d（遮罩像素）是 0.5 − d / 20，镜片外半截在 0.5 外面
    static func softMask() -> FloatMap {
        let w = 480, h = 360
        var inside = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where isBody((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h)) { inside[y * w + x] = true } }
        var v = [Float](repeating: 0, count: w * h)
        let R = 10
        for y in 0..<h {
            for x in 0..<w {
                if inside[y * w + x] { v[y * w + x] = 1; continue }
                var best = Float.infinity
                for yy in max(0, y - R)...min(h - 1, y + R) {
                    for xx in max(0, x - R)...min(w - 1, x + R) where inside[yy * w + xx] {
                        let dx = Float(xx - x), dy = Float(yy - y)
                        best = min(best, (dx * dx + dy * dy).squareRoot())
                    }
                }
                if best.isFinite { v[y * w + x] = max(0, 0.5 - best / 20) }
            }
        }
        return FloatMap(width: w, height: h, values: v)
    }

    /// 人脸框（正立方向，左上角为原点）：脸前沿 0.40，眉毛到下巴
    static let face = FaceBand.Face(x: 0.40, y: 0.20, width: 0.15, height: 0.35)

    static func scene(focusOnPerson: Bool, band: Bool) -> T.Scene {
        T.Scene(layers: [
            T.Layer(name: "墙", z: 3, color: T.flat(0.82, 0.82, 0.80), inside: { _, _ in true }),
            T.Layer(name: "椅子", z: 1.2, color: T.flat(0.2, 0.2, 0.22), inside: T.rect(0.68, 0.85, 0.4, 0.95)),
            T.Layer(name: "镜片", z: 3, color: lensColor, inside: lens),
            T.Layer(name: "人", z: 1.2, color: { _, iy in Float(iy) / 720 < 0.22 ? (0.03, 0.03, 0.035) : (0.62, 0.45, 0.36) },
                    inside: { x, y in isBody(x, y) }, person: true),
        ], focus: focusOnPerson ? (0.47, 0.4) : (0.76, 0.6),
           personMaskOverride: softMask(), faceBand: band ? FaceBand.map([face], width: 480, height: 360) : nil)
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
