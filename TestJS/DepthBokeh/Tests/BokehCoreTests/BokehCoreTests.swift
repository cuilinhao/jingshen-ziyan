import XCTest
@testable import BokehCore

final class BokehCoreTests: XCTestCase {

    /// 对焦面上的像素不能被改动
    func testInFocusPixelsUnchanged() {
        let w = 64, h = 48
        var img = PlanarImage(width: w, height: h)
        for i in 0..<(w * h) {
            img.r[i] = Float(i % 7) / 7; img.g[i] = Float(i % 5) / 5; img.b[i] = Float(i % 3) / 3
        }
        let disp = FloatMap(width: w, height: h, repeating: 1)
        let out = BokehRenderer().render(image: img, disparity: disp, lens: LensParameters(fNumber: 1.4, focusDisparity: 1))
        for i in 0..<(w * h) {
            XCTAssertEqual(out.r[i], img.r[i], accuracy: 1e-4)
            XCTAssertEqual(out.g[i], img.g[i], accuracy: 1e-4)
        }
    }

    /// 均匀颜色的平面不管怎么虚化，颜色和亮度都不变（能量守恒、边界归一化正确）
    func testFlatFieldPreserved() {
        let w = 80, h = 60
        var img = PlanarImage(width: w, height: h)
        for i in 0..<(w * h) { img.r[i] = 0.3; img.g[i] = 0.2; img.b[i] = 0.1 }
        let disp = FloatMap(width: w, height: h, repeating: 0.2)
        let out = BokehRenderer().render(image: img, disparity: disp, lens: LensParameters(fNumber: 1.4, focusDisparity: 2))
        for i in 0..<(w * h) {
            XCTAssertEqual(out.r[i], 0.3, accuracy: 1e-3)
            XCTAssertEqual(out.b[i], 0.1, accuracy: 1e-3)
        }
    }

    /// 背景里的一个亮点应该被摊成一个圆盘，半径符合镜头公式
    func testPointBecomesDisk() {
        let w = 201, h = 201
        var img = PlanarImage(width: w, height: h)
        let c = 100 * w + 100
        img.r[c] = 1; img.g[c] = 1; img.b[c] = 1
        let disp = FloatMap(width: w, height: h, repeating: 0.1)
        let lens = LensParameters(fNumber: 2, focusDisparity: 1, model: .thinLens, focalLength35mm: 100, maxBlurFraction: 0.2, softLimitFraction: 0)
        let expected = abs(lens.signedBlurRadius(disparity: 0.1, imageLongSide: w))
        XCTAssertGreaterThan(expected, 10)
        let out = BokehRenderer().render(image: img, disparity: disp, lens: lens,
                                         quality: RenderQuality(layersPerSide: 4, highlightThreshold: 2, highlightGain: 0))
        // 沿水平方向测量圆盘半径：亮度降到中心一半的位置
        let center = out.r[100 * w + 100]
        var edge = 0
        for x in 100..<w where out.r[100 * w + x] > 0.5 * center { edge = x - 100 }
        XCTAssertEqual(Float(edge), expected, accuracy: 1.0)
        // 圆盘内部亮度均匀（是圆盘，不是高斯）
        let half = out.r[100 * w + 100 + Int(expected / 2)]
        XCTAssertEqual(half / center, 1, accuracy: 0.05)
        // 总能量守恒
        let total = out.r.reduce(0, +)
        XCTAssertEqual(total, 1, accuracy: 0.02)
    }

    /// 回归测试：模糊半径落在两层之间的不透明表面不能变透明（前景、背景各测一次）
    func testSplitLayersStayOpaque() {
        let w = 240, h = 160
        var img = PlanarImage(width: w, height: h)
        var disp = [Float](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x < w / 3 {            // 前景：红色
                    img.r[i] = 0.8; img.g[i] = 0.1; img.b[i] = 0.1; disp[i] = 1.6
                } else if x < 2 * w / 3 { // 对焦面：绿色
                    img.r[i] = 0.1; img.g[i] = 0.7; img.b[i] = 0.1; disp[i] = 1
                } else {                  // 背景：蓝色
                    img.r[i] = 0.1; img.g[i] = 0.1; img.b[i] = 0.8; disp[i] = 0.6
                }
            }
        }
        // 两个角上放更极端的深度，让前景/背景的半径正好落在两层中间
        disp[0] = 2.2; disp[w * h - 1] = 0.2
        let lens = LensParameters(fNumber: 2, focusDisparity: 1, model: .thinLens, focalLength35mm: 50, maxBlurFraction: 0.1)
        let out = BokehRenderer().render(image: img, disparity: FloatMap(width: w, height: h, values: disp),
                                         lens: lens, quality: RenderQuality(layersPerSide: 4, highlightThreshold: 2, highlightGain: 0))
        let y = h / 2
        let fg = y * w + w / 6, bgPix = y * w + 5 * w / 6
        XCTAssertEqual(out.r[fg], 0.8, accuracy: 0.01)
        XCTAssertEqual(out.g[fg], 0.1, accuracy: 0.01)
        XCTAssertEqual(out.b[bgPix], 0.8, accuracy: 0.01)
        XCTAssertEqual(out.r[bgPix], 0.1, accuracy: 0.01)
        // 对焦面中心不受影响
        XCTAssertEqual(out.g[y * w + w / 2], 0.7, accuracy: 0.01)
    }

    /// 任意比例缩放和整数倍缩放结果一致；双分辨率在对焦面上原样保留全分辨率细节
    func testResampleAndDetailPreserving() {
        let w = 360, h = 240
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            bytes[i] = UInt8((x * 7 + y * 3) % 256); bytes[i + 1] = UInt8((x * 2) % 256); bytes[i + 2] = UInt8((y * 5) % 256)
        } }
        let a = bytes.withUnsafeBytes { PlanarImage(interleaved8: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, layout: .rgba, downsample: 2, maxSamplesPerAxis: 2) }
        let b = bytes.withUnsafeBytes { PlanarImage(interleaved8: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, layout: .rgba, outputWidth: w / 2, outputHeight: h / 2) }
        XCTAssertEqual(a.pixelCount, b.pixelCount)
        for i in 0..<a.pixelCount { XCTAssertEqual(a.r[i], b.r[i], accuracy: 1e-5) }

        // 全图在对焦面上：输出必须等于全分辨率原图（细节不能丢）
        let full = bytes.withUnsafeBytes { PlanarImage(interleaved8: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, layout: .rgba) }
        let disp = FloatMap(width: 40, height: 30, repeating: 1)
        let out = BokehRenderer().renderDetailPreserving(full: full, disparity: disp, lens: LensParameters(fNumber: 1.4, focusDisparity: 1), lowLongSide: 120)
        var maxErr: Float = 0
        for i in 0..<full.pixelCount { maxErr = max(maxErr, abs(out.g[i] - full.g[i])) }
        XCTAssertLessThan(maxErr, 1e-3)
    }

    /// 对焦稳定器：主体短暂离开对焦点时保持对焦；新深度持续超过 maxHold 才换焦；点按后立即换
    func testFocusStabilizer() {
        let w = 64, h = 48
        func scene(subjectX: Int) -> FloatMap {
            var v = [Float](repeating: 0.25, count: w * h)       // 背景 4 m
            for y in 10..<40 { for x in subjectX..<(subjectX + 8) { v[y * w + x] = 1.0 } }  // 主体 1 m，宽 8 像素
            return FloatMap(width: w, height: h, values: v)
        }
        var st = FocusStabilizer()
        st.smoothingTime = 1e-4
        let p: (Float, Float) = (0.5, 0.5)                       // x = 32
        XCTAssertEqual(st.update(map: scene(subjectX: 28), nx: p.0, ny: p.1, dt: 1 / 30), 1, accuracy: 1e-3)
        // 主体往右挪了 8 像素，对焦点落在背景上：仍然对在主体上
        for _ in 0..<30 {
            XCTAssertEqual(st.update(map: scene(subjectX: 37), nx: p.0, ny: p.1, dt: 1 / 30), 1, accuracy: 1e-3)
        }
        // 持续 1.5 秒以上：接受背景
        var last: Float = 0
        for _ in 0..<30 { last = st.update(map: scene(subjectX: 37), nx: p.0, ny: p.1, dt: 1 / 30) }
        XCTAssertEqual(last, 0.25, accuracy: 1e-3)
        // 主体离得很远（不在搜索窗口里）：0.3 秒后就换
        var st2 = FocusStabilizer(); st2.smoothingTime = 1e-4
        _ = st2.update(map: scene(subjectX: 28), nx: p.0, ny: p.1, dt: 1 / 30)
        for _ in 0..<12 { last = st2.update(map: scene(subjectX: 2), nx: p.0, ny: p.1, dt: 1 / 30) }
        XCTAssertEqual(last, 0.25, accuracy: 1e-3)
        // 点按换焦：reset 后立即跟随新位置
        st2.reset()
        XCTAssertEqual(st2.update(map: scene(subjectX: 2), nx: 0.08, ny: 0.5, dt: 1 / 30), 1, accuracy: 1e-3)
        // 对焦在背景上，近处的主体移进点按位置（背景仍占搜索窗口大部分）：0.3 秒左右就换到主体
        var st3 = FocusStabilizer(); st3.smoothingTime = 1e-4
        _ = st3.update(map: scene(subjectX: 2), nx: p.0, ny: p.1, dt: 1 / 30)       // 点按处是背景
        var frames = 0
        while st3.update(map: scene(subjectX: 28), nx: p.0, ny: p.1, dt: 1 / 30) < 0.9 && frames < 100 { frames += 1 }
        XCTAssertLessThanOrEqual(frames, 10)
    }

    /// 软上限：小半径几乎不变，大半径饱和在 r_sat 附近；ƒ 值越大上限越小
    func testSoftLimit() {
        let L = 2016
        var lens = LensParameters(fNumber: 4.5, focusDisparity: 3, model: .thinLens, focalLength35mm: 52, maxBlurFraction: 0.2, focusTolerance: 0)
        var phys = lens; phys.softLimitFraction = 0
        let small = lens.signedBlurRadius(disparity: 2.8, imageLongSide: L)
        XCTAssertEqual(small, phys.signedBlurRadius(disparity: 2.8, imageLongSide: L), accuracy: 0.05)
        let far = abs(lens.signedBlurRadius(disparity: 0.01, imageLongSide: L))
        XCTAssertGreaterThan(abs(phys.signedBlurRadius(disparity: 0.01, imageLongSide: L)), 45)
        XCTAssertLessThan(far, 0.012 * Float(L) + 0.5)
        XCTAssertGreaterThan(far, 0.012 * Float(L) * 0.85)
        lens.fNumber = 9
        XCTAssertLessThan(abs(lens.signedBlurRadius(disparity: 0.01, imageLongSide: L)), far * 0.55)
    }

    /// 系统模型：模糊只和相对距离有关。blurK = 0.012 时 ƒ1.4、主体 1.5 m、背景 6 m 约为长边的 0.55%
    ///（DepthBokehCamera 2 的标定）；默认 0.015 是它的 1.25 倍
    func testSystemModel() {
        let L = 1440
        let ref = LensParameters(fNumber: 1.4, focusDisparity: 1 / 1.5, blurK: 0.012)
        XCTAssertEqual(-ref.signedBlurRadius(disparity: 1 / 6, imageLongSide: L) / Float(L), 0.0055, accuracy: 0.0006)
        let lens = LensParameters(fNumber: 1.4, focusDisparity: 1 / 1.5)
        let bg = lens.signedBlurRadius(disparity: 1 / 6, imageLongSide: L)
        XCTAssertLessThan(bg, 0)
        XCTAssertEqual(bg / ref.signedBlurRadius(disparity: 1 / 6, imageLongSide: L), 1.25, accuracy: 0.01)
        // 对焦 0.46 m 的拳头、背景 3 m：和对焦 1.5 m 时差不多（相对距离接近），不会变成几倍
        let near = LensParameters(fNumber: 1.4, focusDisparity: 1 / 0.46)
        XCTAssertLessThan(abs(near.signedBlurRadius(disparity: 1 / 3, imageLongSide: L)), 1.3 * abs(bg))
        // 死区内完全清晰；前景比同样相对距离的背景柔和
        XCTAssertEqual(lens.signedBlurRadius(disparity: (1 / 1.5) * 1.05, imageLongSide: L), 0)
        let fg = lens.signedBlurRadius(disparity: (1 / 1.5) * 1.5, imageLongSide: L)
        let back = lens.signedBlurRadius(disparity: (1 / 1.5) * 0.5, imageLongSide: L)
        XCTAssertEqual(fg, -0.8 * back, accuracy: 0.01)
        // 上限 1.4%
        XCTAssertLessThanOrEqual(abs(near.signedBlurRadius(disparity: 50, imageLongSide: L)), 0.014 * Float(L) + 1e-3)
    }

    func testPullPushFillsHoles() {
        let w = 32, h = 32
        var values = [Float](repeating: 0.5, count: w * h)
        for y in 10..<20 { for x in 10..<20 { values[y * w + x] = .nan } }
        let filled = DepthRefiner.fillInvalid(FloatMap(width: w, height: h, values: values))
        for v in filled.values { XCTAssertEqual(v, 0.5, accuracy: 1e-4) }
    }

    /// 数码变焦的中心裁切：画面和深度图裁同一块，内容对得上
    func testCenterCrop() {
        // 视差 = 横坐标（像素中心），裁 2 倍后应该只剩中间一半的值域
        let w = 40, h = 30
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { values[y * w + x] = Float(x) + 0.5 } }
        let map = FloatMap(width: w, height: h, values: values)
        let c = map.centerCropped(by: 2)
        XCTAssertEqual(c.width, 20); XCTAssertEqual(c.height, 15)
        XCTAssertEqual(c[0, 7], 10.5, accuracy: 0.01)
        XCTAssertEqual(c[19, 7], 29.5, accuracy: 0.01)
        XCTAssertEqual(map.centerCropped(by: 1).width, w)
        // 空洞不会因为插值变大
        var holes = values
        holes[15 * w + 20] = .nan
        let ch = FloatMap(width: w, height: h, values: holes).centerCropped(by: 1.25)
        XCTAssertLessThanOrEqual(ch.values.filter { !$0.isFinite }.count, 2)

        // 8 位图像：sourceRect 只取中间一块
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where x >= 10 && x < 30 { for c in 0..<3 { bytes[(y * w + x) * 4 + c] = 255 } } }
        let img = bytes.withUnsafeBytes { raw in
            PlanarImage(interleaved8: raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4, layout: .rgba,
                        outputWidth: 20, outputHeight: 15, sourceRect: (10, 7.5, 20, 15))
        }
        XCTAssertEqual(img.r.min()!, 1, accuracy: 1e-4)   // 整块都是中间的白色
    }

    /// AI 单目深度：相对距离的分母有下限，对焦远处时不会把一切都当成「很远的前景」
    func testRelativeScale() {
        let L = 1000
        var lens = LensParameters(fNumber: 2, focusDisparity: 0.1)
        let raw = abs(lens.signedBlurRadius(disparity: 0.2, imageLongSide: L))
        lens.relativeScale = 0.25
        let guarded = abs(lens.signedBlurRadius(disparity: 0.2, imageLongSide: L))
        XCTAssertLessThan(guarded, raw)
        XCTAssertEqual(lens.relativeDistance(0.9), 3.2, accuracy: 1e-4)
        // 不设分母时和原公式完全一样
        let abs1 = LensParameters(fNumber: 2, focusDisparity: 0.5)
        XCTAssertEqual(abs1.relativeDistance(0.25), -0.5, accuracy: 1e-6)
    }
}
