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

    /// 系统模型：模糊只和视差差有关（像真实镜头），大视差差饱和；对焦面前面有一段全清晰区
    func testSystemModel() {
        let L = 1440
        // 固定原始标定值验证距离曲线，调节默认强度时无需同步修改这些断言。
        let calibratedBlurK: Float = 0.015
        func pct(_ lens: LensParameters, _ d: Float) -> Float { lens.signedBlurRadius(disparity: d, imageLongSide: L) / Float(L) * 100 }
        // 原始标定：ƒ1.4、主体 1.5 m、背景 6 m，背景半径约为长边的 0.66%
        let p15 = LensParameters(fNumber: 1.4, focusDisparity: 1 / 1.5, blurK: calibratedBlurK)
        XCTAssertEqual(pct(p15, 1 / 6), -0.66, accuracy: 0.05)
        // 拳头 0.46 m、背景 3 m：饱和在长边的 1% 左右
        let fist = LensParameters(fNumber: 1.4, focusDisparity: 1 / 0.46, blurK: calibratedBlurK)
        XCTAssertEqual(pct(fist, 1 / 3), -1.0, accuracy: 0.1)
        // 对焦在 3.5 m 的柜子：前面 1.7 m 的人几乎清晰，1.4 m 的杯子轻微虚化
        let far = LensParameters(fNumber: 1.4, focusDisparity: 1 / 3.5, blurK: calibratedBlurK)
        XCTAssertLessThan(pct(far, 1 / 1.7), 0.12)
        XCTAssertGreaterThan(pct(far, 1 / 1.4), 0.15)
        XCTAssertLessThan(pct(far, 1 / 1.4), 0.4)
        // 全清晰区：前面 0.25、后面 0.04（视差差）
        XCTAssertEqual(far.signedBlurRadius(disparity: 1 / 3.5 + 0.24, imageLongSide: L), 0)
        XCTAssertEqual(far.signedBlurRadius(disparity: 1 / 3.5 - 0.035, imageLongSide: L), 0)
        // 双摄视差的偏移不影响模糊
        var shifted = far
        shifted.focusDisparity += 0.3
        XCTAssertEqual(pct(shifted, 1 / 1.4 + 0.3), pct(far, 1 / 1.4), accuracy: 1e-4)
        // 上限 1.4%
        XCTAssertLessThanOrEqual(abs(fist.signedBlurRadius(disparity: 50, imageLongSide: L)), 0.014 * Float(L) + 1e-3)
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

    /// 相对距离（主体遮罩用）：相对深度时分母有下限；模糊本身只看视差差，不受这个分母影响
    func testRelativeScale() {
        let L = 1000
        var lens = LensParameters(fNumber: 2, focusDisparity: 0.1)
        let raw = lens.signedBlurRadius(disparity: 0.2, imageLongSide: L)
        lens.relativeScale = 0.25
        XCTAssertEqual(lens.signedBlurRadius(disparity: 0.6, imageLongSide: L) > raw, true)
        XCTAssertEqual(lens.signedBlurRadius(disparity: 0.2, imageLongSide: L), raw)
        XCTAssertEqual(lens.relativeDistance(0.9), 3.2, accuracy: 1e-4)
        // 不设分母时和原公式完全一样
        let abs1 = LensParameters(fNumber: 2, focusDisparity: 0.5)
        XCTAssertEqual(abs1.relativeDistance(0.25), -0.5, accuracy: 1e-6)
    }

    /// 手机移动时整幅画面的平移量估计（扫镜头时不再沿用上一帧，避免拖影 / 延迟感）
    func testGlobalShift() {
        let w = 480, h = 360
        let rng = SystemRandomNumberGenerator()
        // 有纹理的图：随机块
        var base = [Float](repeating: 0, count: (w + 16) * h)
        for y in 0..<h { for x in 0..<(w + 16) { base[y * (w + 16) + x] = Float((x / 6 + y / 5 * 7) % 11) / 11 } }
        _ = rng
        func crop(_ dx: Int) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { out[y * w + x] = base[y * (w + 16) + x + dx] } }
            return out
        }
        let a = crop(4)
        XCTAssertEqual(TemporalState.globalShift(a, a, width: w, height: h), 0)
        let s = TemporalState.globalShift(crop(10), a, width: w, height: h)
        XCTAssertEqual(s, 6, accuracy: 2.1)
    }

    /// 深度边界往里缩了一圈（双摄视差、4× 长焦常见）：颜色和主体一样的那一圈要补回主体
    func testColorGrowthRestoresSubjectEdge() {
        let w = 160, h = 120, n = w * h
        var img = PlanarImage(width: w, height: h)
        var d = [Float](repeating: 0.25, count: n)            // 背景 4 m
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let inBox = x >= 50 && x < 110 && y >= 30 && y < 100
                if inBox {
                    img.r[i] = 0.05; img.g[i] = 0.05; img.b[i] = 0.6   // 蓝色盒子
                    if y >= 42 { d[i] = 1 }                            // 深度只覆盖到 y = 42，顶上 12 行拿到的是背景深度
                } else {
                    img.r[i] = 0.8; img.g[i] = 0.8; img.b[i] = 0.75   // 白色桌面
                }
            }
        }
        let disp = FloatMap(width: w, height: h, values: d)
        var params = SubjectMatteParameters()
        params.colorGrowth = 0
        let off = SubjectMatte.apply(disparity: disp, image: img, focusDisparity: 1, focusPoint: (0.5, 0.6), parameters: params)
        params.colorGrowth = 1.0 / 8
        let on = SubjectMatte.apply(disparity: disp, image: img, focusDisparity: 1, focusPoint: (0.5, 0.6), parameters: params)
        let strip = 33 * w + 80   // 盒子顶上那一圈里的像素
        XCTAssertLessThan(off.1.values[strip], 0.5)
        XCTAssertGreaterThan(on.1.values[strip], 0.9)
        XCTAssertGreaterThan(on.0.values[strip], 0.9)          // 视差被拉回对焦面
        // 背景不受影响
        XCTAssertLessThan(on.1.values[10 * w + 10], 0.05)
        XCTAssertLessThan(on.1.values[60 * w + 140], 0.05)
    }

    /// 人像遮罩：只保留对焦点所在的那个人；对焦点不在人身上时不起作用
    func testPersonRegion() {
        let w = 100, h = 80
        var m = [Float](repeating: 0, count: w * h)
        for y in 10..<70 { for x in 10..<30 { m[y * w + x] = 1 } }   // 人 A
        for y in 10..<70 { for x in 60..<80 { m[y * w + x] = 1 } }   // 人 B
        let mask = FloatMap(width: w, height: h, values: m)
        let a = SubjectMatte.personRegion(mask, width: w, height: h, focusPoint: (0.2, 0.5))!
        XCTAssertEqual(a[40 * w + 20], 1, accuracy: 1e-4)
        XCTAssertEqual(a[40 * w + 70], 0, accuracy: 1e-4)
        XCTAssertNil(SubjectMatte.personRegion(mask, width: w, height: h, focusPoint: (0.5, 0.5)))
    }

    /// 手（肤色方块，近处）在纹理背景前往右下移了 10 像素，深度还是上一帧的：
    /// 重新对齐后手新移到的地方是近处，手离开、露出来的背景是远处
    func testStaleDepthFollowsMovingObject() {
        let w = 160, h = 120
        func frame(_ ox: Int, _ oy: Int) -> (PlanarImage, FloatMap) {
            var img = PlanarImage(width: w, height: h)
            var d = [Float](repeating: 0.3, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    // 背景：灰色带竖条纹
                    let v: Float = (x / 6) % 2 == 0 ? 0.35 : 0.2
                    img.r[i] = v; img.g[i] = v; img.b[i] = v * 1.1
                    if x >= ox && x < ox + 40 && y >= oy && y < oy + 40 {
                        img.r[i] = 0.55; img.g[i] = 0.3; img.b[i] = 0.22
                        d[i] = 3
                    }
                }
            }
            return (img, FloatMap(width: w, height: h, values: d))
        }
        let (prevImg, prevDepth) = frame(50, 40)
        let (nowImg, nowTruth) = frame(60, 46)
        let r = StaleDepth.realign(depth: prevDepth, now: nowImg, previous: prevImg,
                                   guideLuma: nowImg.perceptualLuma(), gfRadius: 3)
        var staleWrong = 0, fixedWrong = 0
        for i in 0..<(w * h) {
            if abs(prevDepth.values[i] - nowTruth.values[i]) > 1 { staleWrong += 1 }
            if abs(r.depth.values[i] - nowTruth.values[i]) > 1 { fixedWrong += 1 }
        }
        var far: [(Int, Int)] = []
        for i in 0..<(w * h) where abs(r.depth.values[i] - nowTruth.values[i]) > 1 {
            let x = i % w, y = i / w
            let edge = min(abs(x - 60), abs(x - 99), abs(y - 46), abs(y - 85))
            if edge > 2 { far.append((x, y)) }
        }
        XCTAssertGreaterThan(staleWrong, 600)
        // 剩下的只是手的轮廓上 1–2 像素的过渡（按这一帧亮度引导滤波，边缘是软的）
        XCTAssertLessThan(fixedWrong, staleWrong / 5, "旧深度错 \(staleWrong) 个像素，对齐后还错 \(fixedWrong) 个")
        XCTAssertTrue(far.isEmpty, "离手的轮廓超过 2 像素还有错的：\(far.prefix(20))")
        // 手新移到的角（右下）是近处，手离开的角（左上）是远处
        XCTAssertGreaterThan(r.depth[95, 82], 2.5)
        XCTAssertLessThan(r.depth[52, 42], 0.8)
        // 没动的背景完全不变
        XCTAssertEqual(r.depth[150, 5], prevDepth[150, 5])
    }

    /// 人像遮罩是几帧前的：人挥手离开的地方不再相信遮罩，没动的地方照旧
    func testStaleMaskDropped() {
        let w = 80, h = 60
        func image(_ ox: Int) -> PlanarImage {
            var img = PlanarImage(width: w, height: h)
            for i in 0..<(w * h) {
                let x = i % w
                let inHand = x >= ox && x < ox + 20
                img.r[i] = inHand ? 0.55 : 0.2; img.g[i] = inHand ? 0.3 : 0.2; img.b[i] = inHand ? 0.22 : 0.25
            }
            return img
        }
        var mv = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where (i % w) >= 10 && (i % w) < 30 { mv[i] = 1 }
        let mask = FloatMap(width: w, height: h, values: mv)
        // 手从 x = 10 移到了 x = 40
        let out = LiveFrameAnalyzer.dropStaleMask(mask, maskColors: image(10), colors: image(40))
        XCTAssertLessThan(out[15, 30], 0.05, "手离开的地方")
        let same = LiveFrameAnalyzer.dropStaleMask(mask, maskColors: image(10), colors: image(10))
        XCTAssertEqual(same[15, 30], 1, accuracy: 1e-4, "没动")
    }

    /// Vision 的结果（竖图）转回传感器方向：正方形（物体分割的标签图总是 512×512）也要转
    func testVisionOrientationSensorFromRight() {
        // 竖图 宽 3、高 4，值 = 行 × 10 + 列
        var p = [Float](repeating: 0, count: 12)
        for r in 0..<4 { for c in 0..<3 { p[r * 3 + c] = Float(r * 10 + c) } }
        let s = VisionOrientation.sensorFromRight(p, width: 3, height: 4)
        XCTAssertEqual(s.width, 4); XCTAssertEqual(s.height, 3)
        // 传感器 (x, y) = 竖图 (行 x, 列 宽 − 1 − y)
        XCTAssertEqual(s[0, 0], 2); XCTAssertEqual(s[1, 0], 12); XCTAssertEqual(s[3, 2], 30); XCTAssertEqual(s[3, 0], 32)
        // 正方形：竖图左上角的标记转到传感器的左下角
        var q = [Float](repeating: 0, count: 16)
        q[0] = 1
        let t = VisionOrientation.sensorFromRight(q, width: 4, height: 4)
        XCTAssertEqual(t[0, 3], 1); XCTAssertEqual(t[0, 0], 0)
    }

    /// 0/1 图的快速膨胀和逐像素取最大值结果一样（各种半径、贴边）
    func testDilateBinaryMatchesMaxFilter() {
        let w = 67, h = 41
        var v = [Float](repeating: 0, count: w * h)
        var seed: UInt32 = 12345
        for i in 0..<(w * h) {
            seed = seed &* 1664525 &+ 1013904223
            if seed >> 28 == 0 { v[i] = 1 }
        }
        v[0] = 1; v[w * h - 1] = 1
        for r in [1, 2, 5, 8, 40, 80] {
            XCTAssertEqual(SubjectMatte.dilateBinary(v, width: w, height: h, radius: r),
                           SubjectMatte.maxFilter(v, width: w, height: h, radius: r), "r = \(r)")
        }
    }

    /// 物体标签图里按对焦点选物体：点在物体上、点在物体旁边一点点、点离物体很远
    func testInstanceAt() {
        let w = 100, h = 80
        var v = [Float](repeating: 0, count: w * h)
        for y in 20..<40 { for x in 10..<30 { v[y * w + x] = 1 } }
        for y in 30..<60 { for x in 50..<80 { v[y * w + x] = 2 } }
        let labels = FloatMap(width: w, height: h, values: v)
        let a = SubjectMatte.instanceAt(labels, point: (0.65, 0.55))
        XCTAssertEqual(a?[60, 40], 1); XCTAssertEqual(a?[20, 30], 0)
        let near = SubjectMatte.instanceAt(labels, point: (0.31, 0.3))   // 物体 1 右边一个像素
        XCTAssertEqual(near?[15, 25], 1)
        XCTAssertNil(SubjectMatte.instanceAt(labels, point: (0.5, 0.9)))
    }

    /// 斜着看到的盒子顶面在深度图里拿到的是背景的深度：物体分割把整个盒子（包括顶面）补成主体；
    /// 深度大部分对不上的「物体」（一路延伸到远处的桌面）不用
    func testObjectMaskKeepsBoxTop() {
        let w = 80, h = 60
        var d = [Float](repeating: 0.4, count: w * h)          // 背景 2.5 m
        var labels = [Float](repeating: 0, count: w * h)
        for y in 20..<50 {
            for x in 30..<50 {
                labels[y * w + x] = 1
                d[y * w + x] = y < 26 ? 0.5 : 2.2                  // 顶面（前 6 行）深度错成背景
            }
        }
        // 桌面：从近处一路到远处，深度大部分不在对焦面附近
        for y in 50..<60 { for x in 0..<w { labels[y * w + x] = 2; d[y * w + x] = 0.4 + Float(y - 50) * 0.02 } }
        for y in 56..<60 { for x in 0..<w { d[y * w + x] = 2.2 } }
        var img = PlanarImage(width: w, height: h)
        for i in 0..<(w * h) { img.r[i] = 0.3; img.g[i] = 0.3; img.b[i] = 0.3 }
        let analyzer = LiveFrameAnalyzer()
        func plan(_ fx: Float, _ fy: Float) -> FramePlan {
            analyzer.resetHistory()
            return analyzer.analyze(LiveFrameAnalyzer.Frame(
                disparity: FloatMap(width: w, height: h, values: d), relativeDepth: false, crop: 1, fNumber: 1.4,
                focusPoint: (fx, fy), focusTapped: true, time: 0, colors: img, personMask: nil, outputLongSide: 480,
                objectLabels: FloatMap(width: w, height: h, values: labels)))
        }
        let box = plan(0.5, 0.6)
        let person = box.seeds?.person
        XCTAssertNotNil(person, "对焦在盒子上，应该用上物体遮罩")
        XCTAssertGreaterThan(person?[40, 22] ?? 0, 0.5, "盒子顶面")
        XCTAssertGreaterThan(box.seeds?.extra?[40, 22] ?? 0, 0.5, "盒子顶面算进主体核心")
        XCTAssertLessThan(person?[10, 22] ?? 1, 0.5, "盒子外面")
        // 对焦在桌面近处：桌面这个「物体」深度大部分对不上，不用
        let table = plan(0.5, 0.97)
        XCTAssertNil(table.seeds?.person)
    }

    /// 物体分割把盒子后面挨着的罐子也算进了同一个物体：罐子（深度对不上、成块）不能被当成主体保持清晰；
    /// 盒子顶面（深度对不上、但只是贴着盒子的一条）照样补回来
    func testObjectRefineDropsMergedNeighbour() {
        let w = 80, h = 60
        var d = [Float](repeating: 0.4, count: w * h)         // 背景
        var obj = [Float](repeating: 0, count: w * h)
        for y in 20..<50 {
            for x in 40..<60 {
                obj[y * w + x] = 1
                d[y * w + x] = y < 24 ? 0.4 : 2.8              // 盒子，顶面 4 行深度错成背景
            }
        }
        // 罐子：在盒子左边、连着，深度在后面（1.6），成块
        for y in 26..<46 { for x in 18..<40 { obj[y * w + x] = 1; d[y * w + x] = 1.6 } }
        let out = LiveFrameAnalyzer.refineObject(FloatMap(width: w, height: h, values: obj),
                                                 depth: FloatMap(width: w, height: h, values: d),
                                                 focusDisparity: 2.8, norm: 2.8, band: 0.25, reach: 3)
        XCTAssertEqual(out[50, 22], 1, "盒子顶面保留")
        XCTAssertEqual(out[50, 35], 1, "盒子本身")
        XCTAssertEqual(out[25, 35], 0, "罐子中间去掉")
        XCTAssertEqual(out[38, 35], 0, "罐子贴着盒子的地方也去掉")
        // 顶面很厚、整个拿到了背景的深度：也是物体
        var d2 = d, obj2 = obj
        for y in 8..<20 { for x in 40..<60 { obj2[y * w + x] = 1; d2[y * w + x] = 0.4 } }
        let out2 = LiveFrameAnalyzer.refineObject(FloatMap(width: w, height: h, values: obj2),
                                                  depth: FloatMap(width: w, height: h, values: d2),
                                                  focusDisparity: 2.8, norm: 2.8, band: 0.25, reach: 3)
        XCTAssertEqual(out2[50, 10], 1, "厚的顶面，深度和背景一样")
        XCTAssertEqual(out2[25, 35], 0, "罐子还是去掉")
    }

    /// 长焦手持：算遮罩那一帧和现在整体错开两三个像素（盒子顶边是强边缘），遮罩不能因此被扔掉；
    /// 盒子真的被拿走了才扔
    func testStaleMaskToleratesShake() {
        let w = 80, h = 60
        func image(dx: Int, dy: Int, boxX: Int) -> PlanarImage {
            var img = PlanarImage(width: w, height: h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let sx = x - dx, sy = y - dy
                    // 暗背景 + 一点纹理，盒子是亮的、带条纹
                    var v: Float = 0.02 + 0.03 * Float((sx / 3 + sy / 4) % 2)
                    if sx >= boxX && sx < boxX + 24 && sy >= 20 && sy < 50 { v = (sx / 2) % 2 == 0 ? 0.7 : 0.4 }
                    img.r[i] = v; img.g[i] = v; img.b[i] = v
                }
            }
            return img
        }
        var mv = [Float](repeating: 0, count: w * h)
        for y in 20..<50 { for x in 30..<54 { mv[y * w + x] = 1 } }
        let mask = FloatMap(width: w, height: h, values: mv)
        let then = image(dx: 0, dy: 0, boxX: 30)
        // 整幅画面往右下挪了 (2, 1)：遮罩跟着挪过去，没有被扔掉，也不用重新分割
        let shaken = LiveFrameAnalyzer.alignMask(mask, maskColors: then, colors: image(dx: 2, dy: 1, boxX: 30))
        var kept: Float = 0
        for y in 21..<51 { for x in 32..<56 { kept += shaken.mask[x, y] } }
        XCTAssertGreaterThan(kept / Float(30 * 24), 0.9, "手抖不算「变了」")
        XCTAssertLessThan(shaken.mask[31, 35], 0.2, "遮罩跟着画面挪了（左边原来的位置现在是背景）")
        XCTAssertGreaterThan(shaken.mask[55, 35], 0.8, "遮罩跟着画面挪了（右边）")
        XCTAssertLessThan(shaken.changed, LiveFrameAnalyzer.maskStaleFraction, "手抖不用重新分割")
        let moved = LiveFrameAnalyzer.alignMask(mask, maskColors: then, colors: image(dx: 0, dy: 0, boxX: 2))
        XCTAssertLessThan(moved.mask[45, 35], 0.1, "盒子被拿走了")
        XCTAssertGreaterThan(moved.changed, LiveFrameAnalyzer.maskStaleFraction, "盒子被拿走了：该重新分割")
        let same = LiveFrameAnalyzer.alignMask(mask, maskColors: then, colors: then)
        XCTAssertEqual(same.changed, 0, accuracy: 1e-4)
        XCTAssertEqual(same.mask[40, 35], 1, accuracy: 1e-4)
    }

    /// 对焦在坐着的人（B）身上，后面站着的同事（C）在画面上和 B 挨着：人像遮罩把两个人连成一片，
    /// C 不能因此被当成主体保持清晰。有人像实例（每个人一个编号）时，不是对焦的那个人、深度也对不上的去掉；
    /// 站在旁边、和 B 差不多远的人（A）照样保持清晰
    func testPersonInstancesDropPersonBehind() {
        let w = 100, h = 80
        var d = [Float](repeating: 0.3, count: w * h)          // 背景 3.3 m
        var m = [Float](repeating: 0, count: w * h)            // 人像遮罩：三个人连成一片
        var labels = [Float](repeating: 0, count: w * h)       // 人像实例
        for y in 20..<80 { for x in 25..<50 { let i = y * w + x; m[i] = 1; labels[i] = 1; d[i] = 1.4 } }   // B：0.7 m，对焦
        for y in 5..<60 { for x in 50..<75 { let i = y * w + x; m[i] = 1; labels[i] = 2; d[i] = 0.5 } }    // C：2 m，挨着 B
        for y in 20..<80 { for x in 8..<25 { let i = y * w + x; m[i] = 1; labels[i] = 3; d[i] = 1.35 } }   // A：和 B 差不多远
        let disparity = FloatMap(width: w, height: h, values: d)
        let mask = FloatMap(width: w, height: h, values: m)
        let people = FloatMap(width: w, height: h, values: labels)
        let analyzer = LiveFrameAnalyzer()
        func plan(_ instances: FloatMap?) -> FramePlan {
            analyzer.resetHistory()
            return analyzer.analyze(LiveFrameAnalyzer.Frame(
                disparity: disparity, relativeDepth: false, crop: 1, fNumber: 2.8, focusPoint: (0.37, 0.6),
                focusTapped: true, time: 0, colors: nil, personMask: mask, outputLongSide: 480,
                personInstances: instances))
        }
        // 只有人像遮罩：C 和 B 连着，被一起保持清晰（原来的问题）
        XCTAssertGreaterThan(plan(nil).seeds?.person?[62, 30] ?? 0, 0.5)
        let live = plan(people).seeds?.person
        XCTAssertGreaterThan(live?[37, 50] ?? 0, 0.5, "对焦的 B")
        XCTAssertLessThan(live?[62, 30] ?? 1, 0.05, "B 后面的 C 不算主体")
        XCTAssertLessThan(live?[51, 40] ?? 1, 0.05, "C 贴着 B 的地方也不算")
        XCTAssertGreaterThan(live?[15, 50] ?? 0, 0.5, "旁边和 B 差不多远的 A 照样算")
        // 拍下来的照片：同样的规则
        let still = LiveFrameAnalyzer.stillPlan(disparity: disparity, relativeDepth: false, colors: nil, fNumber: 2.8,
                                                focusPoint: (0.37, 0.6), personMask: mask, outputLongSide: 480,
                                                settings: LiveFrameAnalyzer.Settings(), personInstances: people)
        XCTAssertGreaterThan(still.seeds?.person?[37, 50] ?? 0, 0.5)
        XCTAssertLessThan(still.seeds?.person?[62, 30] ?? 1, 0.05)
        XCTAssertGreaterThan(still.seeds?.person?[15, 50] ?? 0, 0.5)
    }
}
