#if canImport(Metal)
import XCTest
import Metal
@testable import BokehCore
@testable import BokehMetal

/// GPU（Metal）版和 CPU 参考实现逐步对比。
///
/// 场景是代码生成的：远处有纹理和高光点的背景、中间的盒子（对焦主体）、左下角的前景横杆，
/// 深度图分辨率比画面低、边缘发糊、有空洞（和手机上的深度流一样）。每一步的中间结果
/// （低分辨率原图、对齐后的深度、主体遮罩、虚化结果、虚化程度 w、最终输出）都读回来和 CPU 比，
/// 不一致时打印是哪一步、最大误差在哪个像素。
final class MetalParityTests: XCTestCase {

    // MARK: - 场景

    struct Scene {
        var image: PlanarImage
        var disparity: FloatMap
        var colors: PlanarImage
        var person: FloatMap?
    }

    /// - Parameters:
    ///   - shift: 整幅画面平移的像素（模拟手机在动）
    ///   - barShift: 前景横杆往上移的像素（画面里有东西在动，手机不动）
    static func makeScene(width W: Int = 960, height H: Int = 720, depthWidth dw: Int = 240, depthHeight dh: Int = 180,
                          shift: Int = 0, withPerson: Bool = false, barShift: Int = 0) -> Scene {
        var img = PlanarImage(width: W, height: H)
        var truth = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let sx = x + shift
                // 背景：渐变 + 棋盘 + 高光点，4 米
                var r: Float = 0.25 + 0.2 * Float(sx) / Float(W), g: Float = 0.3 + 0.15 * Float(y) / Float(H), b: Float = 0.35
                if ((sx / 24) + (y / 24)) % 2 == 0 { r *= 0.6; g *= 0.6; b *= 0.6 }
                if (sx % 97) < 4 && (y % 83) < 4 { r = 1; g = 0.95; b = 0.8 }       // 灯珠
                var d: Float = 0.25
                // 盒子：1 米，蓝色带条纹
                let bx = sx - W * 3 / 8, by = y - H / 4
                if bx >= 0 && bx < W / 4 && by >= 0 && by < H / 2 {
                    r = 0.08; g = 0.12; b = 0.55 + 0.2 * Float((bx / 8) % 2)
                    d = 1
                }
                // 盒子上的「头」：圆，1 米，肤色
                let hx = Float(sx - W / 2), hy = Float(y - H / 5)
                if hx * hx + hy * hy < Float(W * W) / 225 { r = 0.7; g = 0.45; b = 0.35; d = 1 }
                // 前景横杆：0.4 米
                let by0 = H * 3 / 4 - barShift
                if y > by0 && y < by0 + H / 12 && sx < W / 2 { r = 0.6; g = 0.55; b = 0.1; d = 2.5 }
                img.r[i] = r; img.g[i] = g; img.b[i] = b
                truth[i] = d
            }
        }
        // 深度图：低分辨率、边缘发糊、有空洞
        let full = FloatMap(width: W, height: H, values: truth)
        var low = full.resized(width: dw, height: dh).values
        low = BoxFilter.mean(low, width: dw, height: dh, radius: 1)
        for y in (dh / 3)..<(dh / 3 + 4) { for x in (dw / 6)..<(dw / 6 + 6) { low[y * dw + x] = .nan } }
        let disparity = FloatMap(width: dw, height: dh, values: low)
        var person: FloatMap?
        if withPerson {
            var m = [Float](repeating: 0, count: 192 * 144)
            for y in 0..<144 { for x in 0..<192 {
                let px = Float(x) / 192 - 0.5 - Float(shift) / Float(W), py = Float(y) / 144 - 0.2
                if px * px + py * py < 0.012 || (abs(px) < 0.1 && py > 0 && py < 0.45) { m[y * 192 + x] = 1 }
            } }
            person = FloatMap(width: 192, height: 144, values: m)
        }
        return Scene(image: img, disparity: disparity, colors: img.resized(width: dw, height: dh), person: person)
    }

    // MARK: - 对比

    struct Diff: CustomStringConvertible {
        var name: String, maxAbs: Float, mean: Float, p999: Float, at: (Int, Int), cpu: Float, gpu: Float, nan: Int
        var description: String {
            String(format: "%@: 最大差 %.2e（%d,%d：CPU %.4f / GPU %.4f），99.9%% 分位 %.2e，平均 %.2e%@", name, maxAbs,
                   at.0, at.1, cpu, gpu, p999, mean, nan > 0 ? "，NaN \(nan) 个" : "")
        }
    }

    /// cpu：每个像素 channels 个值（平面或交错都转成交错），gpu：readBack 的结果
    static func diff(_ name: String, cpu: [Float], gpu: [Float], width: Int, channels: Int, gpuChannels: Int) -> Diff {
        var d = Diff(name: name, maxAbs: 0, mean: 0, p999: 0, at: (0, 0), cpu: 0, gpu: 0, nan: 0)
        let n = cpu.count / channels
        var sum: Double = 0
        var errors = [Float]()
        errors.reserveCapacity(n * channels)
        for i in 0..<n {
            for c in 0..<channels {
                let a = cpu[i * channels + c], b = gpu[i * gpuChannels + c]
                if !b.isFinite || !a.isFinite { if a.isFinite != b.isFinite { d.nan += 1 }; continue }
                let e = abs(a - b)
                sum += Double(e)
                errors.append(e)
                if e > d.maxAbs { d.maxAbs = e; d.at = (i % width, i / width); d.cpu = a; d.gpu = b }
            }
        }
        d.mean = Float(sum / Double(max(1, n * channels)))
        if !errors.isEmpty {
            errors.sort()
            d.p999 = errors[min(errors.count - 1, Int(Double(errors.count) * 0.999))]
        }
        return d
    }

    static func interleave(_ img: PlanarImage) -> [Float] {
        var out = [Float](repeating: 0, count: img.pixelCount * 3)
        for i in 0..<img.pixelCount { out[3 * i] = img.r[i]; out[3 * i + 1] = img.g[i]; out[3 * i + 2] = img.b[i] }
        return out
    }

    func makeRenderer() throws -> MetalBokehRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("没有 Metal 设备") }
        return try MetalBokehRenderer(device: device)
    }

    func outputTexture(_ r: MetalBokehRenderer, _ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return r.device.makeTexture(descriptor: d)!
    }

    /// 跑一帧 GPU，返回各步骤和 CPU 的差异
    func compareFrame(_ r: MetalBokehRenderer, cpu: BokehRenderer, scene: Scene, plan: FramePlan, quality: RenderQuality,
                      refinePasses: Int, cpuTemporal: TemporalState?, gpuTemporal: MetalTemporalState?,
                      label: String) throws -> [Diff] {
        let img = scene.image
        cpu.captureDebugMaps = true
        let hint = plan.seeds.map { SubjectHint(point: plan.focusPoint, parameters: plan.matte, seeds: $0) }
        let ref = cpu.renderDetailPreserving(full: img, disparity: plan.depth, lens: plan.lens, lowLongSide: plan.lowLongSide,
                                             quality: quality, refinePasses: refinePasses, temporal: cpuTemporal,
                                             subject: hint, layerCenters: plan.layerCenters, stillness: plan.stillness,
                                             depthAge: plan.depthAge)
        let src = try XCTUnwrap(r.makeTexture(from: img))
        let out = outputTexture(r, img.width, img.height)
        r.keepDebugTextures = true
        let cb = try XCTUnwrap(r.commandQueue.makeCommandBuffer())
        r.encode(plan: plan, quality: quality, refinePasses: refinePasses, source: src, output: out, encodeSRGB: false,
                 temporal: gpuTemporal, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error, "GPU 出错：\(String(describing: cb.error))")
        let dbg = try XCTUnwrap(r.debug)
        let lw = dbg.low.width
        var diffs: [Diff] = []
        diffs.append(Self.diff("低分辨率原图", cpu: Self.interleave(try XCTUnwrap(cpu.debugLow)), gpu: r.readBack(dbg.low),
                               width: lw, channels: 3, gpuChannels: 4))
        diffs.append(Self.diff("对齐后的深度", cpu: try XCTUnwrap(cpu.debugRefinedDisparity).values,
                               gpu: r.readBack(dbg.refinedDepth), width: lw, channels: 1, gpuChannels: 1))
        if let m = cpu.debugMatte, let gm = dbg.matte {
            diffs.append(Self.diff("主体遮罩", cpu: m.values, gpu: r.readBack(gm), width: lw, channels: 1, gpuChannels: 1))
        } else {
            XCTAssertEqual(cpu.debugMatte == nil, dbg.matte == nil, "\(label)：CPU / GPU 一个做了主体遮罩一个没做")
        }
        diffs.append(Self.diff("最终深度", cpu: try XCTUnwrap(cpu.debugLowDisparity).values, gpu: r.readBack(dbg.depth),
                               width: lw, channels: 1, gpuChannels: 1))
        diffs.append(Self.diff("低分辨率虚化", cpu: Self.interleave(try XCTUnwrap(cpu.debugBokeh)), gpu: r.readBack(dbg.bokeh),
                               width: lw, channels: 3, gpuChannels: 4))
        diffs.append(Self.diff("虚化程度 w", cpu: try XCTUnwrap(cpu.debugWeights).values, gpu: r.readBack(dbg.weights),
                               width: lw, channels: 1, gpuChannels: 1))
        diffs.append(Self.diff("输出", cpu: Self.interleave(ref), gpu: r.readBack(out), width: img.width, channels: 3,
                               gpuChannels: 4))
        print("[\(label)] \(r.lastLayerCount) 层，低分辨率 \(lw)×\(dbg.low.height)")
        for d in diffs { print("  " + d.description) }
        return diffs
    }

    /// 各步骤的容差（线性光 / 视差单位）
    static let tolerance: [String: Float] = [
        "低分辨率原图": 1e-5, "对齐后的深度": 2e-3, "主体遮罩": 0.02, "最终深度": 0.01,
        "低分辨率虚化": 4e-3, "虚化程度 w": 0.03, "输出": 6e-3,
    ]

    func check(_ diffs: [Diff], _ label: String, tolerance scale: Float = 1) {
        for d in diffs {
            XCTAssertEqual(d.nan, 0, "\(label) \(d.name) 有 NaN")
            let tol = (Self.tolerance[d.name] ?? 1e-3) * scale
            // 千分之一的像素可以超（GPU 的乘加融合让刚好落在门限上的个别像素翻到另一边），但不能差很多
            XCTAssertLessThanOrEqual(d.p999, tol, "\(label) \(d)")
            XCTAssertLessThanOrEqual(d.maxAbs, max(tol * 20, 0.05), "\(label) \(d)")
            XCTAssertLessThanOrEqual(d.mean, tol / 20, "\(label) \(d)")
        }
    }

    // MARK: - 测试

    func testShadersCompile() throws {
        let r = try makeRenderer()
        print("Metal 设备：\(r.device.name)")
    }

    /// 拍照编辑（两遍引导滤波、照片质量、没有跨帧状态）：LiDAR 和双摄相对深度各一次
    func testPhotoParity() throws {
        let r = try makeRenderer()
        let scene = Self.makeScene()
        for relative in [false, true] {
            let plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: relative, colors: scene.colors,
                                                   fNumber: 1.4, focusPoint: (0.5, 0.45), personMask: nil,
                                                   outputLongSide: scene.image.longSide,
                                                   settings: { var s = LiveFrameAnalyzer.Settings(); s.layersPerSide = 9; return s }())
            let label = relative ? "照片·相对深度" : "照片·绝对深度"
            let d = try compareFrame(r, cpu: BokehRenderer(), scene: scene, plan: plan, quality: .photo, refinePasses: 2,
                                     cpuTemporal: nil, gpuTemporal: nil, label: label)
            check(d, label)
        }
    }

    /// 对焦在前景横杆上（大部分画面是背景虚化、前景层很少）+ 人像遮罩
    func testForegroundFocusAndPersonParity() throws {
        let r = try makeRenderer()
        let scene = Self.makeScene(withPerson: true)
        var plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: true, colors: scene.colors,
                                               fNumber: 2, focusPoint: (0.5, 0.2), personMask: scene.person,
                                               outputLongSide: scene.image.longSide, settings: LiveFrameAnalyzer.Settings())
        XCTAssertNotNil(plan.seeds?.person, "对焦点在人身上，应该有人像种子")
        var d = try compareFrame(r, cpu: BokehRenderer(), scene: scene, plan: plan, quality: .preview, refinePasses: 1,
                                 cpuTemporal: nil, gpuTemporal: nil, label: "人像")
        check(d, "人像")
        plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: false, colors: scene.colors,
                                           fNumber: 2, focusPoint: (0.2, 0.8), personMask: nil,
                                           outputLongSide: scene.image.longSide, settings: LiveFrameAnalyzer.Settings())
        d = try compareFrame(r, cpu: BokehRenderer(), scene: scene, plan: plan, quality: .preview, refinePasses: 1,
                             cpuTemporal: nil, gpuTemporal: nil, label: "对焦前景")
        check(d, "对焦前景")
    }

    /// 大半径（层先缩小再模糊的那条路径，q > 1）
    func testLargeRadiusParity() throws {
        let r = try makeRenderer()
        let scene = Self.makeScene()
        var plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: false, colors: scene.colors,
                                               fNumber: 1.4, focusPoint: (0.5, 0.45), personMask: nil,
                                               outputLongSide: scene.image.longSide, settings: LiveFrameAnalyzer.Settings())
        plan.lens.maxBlurFraction = 0.12
        plan.lens.blurK = 0.25
        let L = plan.lowLongSide
        let sMin = min(0, plan.lens.signedBlurRadius(disparity: 0.25, imageLongSide: L))
        let sMax = max(0, plan.lens.signedBlurRadius(disparity: 2.5, imageLongSide: L))
        plan.layerCenters = BokehRenderer.layerCenters(sMin: sMin, sMax: sMax, perSide: 5)
        XCTAssertGreaterThanOrEqual(abs(plan.layerCenters.first!), 32, "要覆盖到 q ≥ 4")
        let d = try compareFrame(r, cpu: BokehRenderer(), scene: scene, plan: plan, quality: .preview, refinePasses: 1,
                                 cpuTemporal: nil, gpuTemporal: nil, label: "大半径")
        check(d, "大半径", tolerance: 2)
    }

    /// 实时预览：连续几帧，跨帧稳定（深度、高光、焦外）的历史在 CPU / GPU 两边要一致；中间有一帧在「扫镜头」
    func testLiveSequenceParity() throws {
        let r = try makeRenderer()
        let cpu = BokehRenderer()
        let cpuTemporal = TemporalState()
        let gpuTemporal = MetalTemporalState()
        let analyzer = LiveFrameAnalyzer()
        let shifts = [0, 0, 1, 12, 12, 13]
        for (k, s) in shifts.enumerated() {
            let scene = Self.makeScene(shift: s)
            let plan = analyzer.analyze(LiveFrameAnalyzer.Frame(
                disparity: scene.disparity, relativeDepth: true, crop: 1, fNumber: 1.8, focusPoint: (0.5, 0.45),
                focusTapped: k == 0, time: Double(k) / 30, colors: scene.colors, personMask: nil,
                outputLongSide: scene.image.longSide))
            let label = "预览第 \(k + 1) 帧（平移 \(plan.cameraShift)）"
            let d = try compareFrame(r, cpu: cpu, scene: scene, plan: plan, quality: .preview, refinePasses: 1,
                                     cpuTemporal: cpuTemporal, gpuTemporal: gpuTemporal, label: label)
            check(d, label, tolerance: 1.5)
        }
    }

    /// 画面里的横杆在往上移，深度每 3 帧才有一张新的：其余帧把上一帧的深度按画面搬过来（StaleDepth），
    /// 新深度来的那一帧不沿用被搬过的区域。CPU / GPU 每一帧都要一致
    func testStaleDepthSequenceParity() throws {
        let r = try makeRenderer()
        let cpu = BokehRenderer()
        let cpuTemporal = TemporalState()
        let gpuTemporal = MetalTemporalState()
        let analyzer = LiveFrameAnalyzer()
        var lastFresh: FloatMap?
        for k in 0..<7 {
            let scene = Self.makeScene(barShift: 14 * k)
            let age = k % 3
            if age == 0 { lastFresh = scene.disparity }
            let plan = analyzer.analyze(LiveFrameAnalyzer.Frame(
                disparity: try XCTUnwrap(lastFresh), relativeDepth: false, crop: 1, fNumber: 1.4, focusPoint: (0.5, 0.45),
                focusTapped: k == 0, time: Double(k) / 30, colors: scene.colors, personMask: nil,
                outputLongSide: scene.image.longSide, depthAge: age))
            XCTAssertEqual(plan.depthAge, k == 0 ? 0 : age)
            let label = "沿用旧深度第 \(k + 1) 帧（深度是 \(age) 帧前的）"
            let d = try compareFrame(r, cpu: cpu, scene: scene, plan: plan, quality: .preview, refinePasses: 1,
                                     cpuTemporal: cpuTemporal, gpuTemporal: gpuTemporal, label: label)
            check(d, label, tolerance: 2)
        }
    }

    /// 主体太近（景深淡出）：直接输出原图
    func testNoEffectCopiesSource() throws {
        let r = try makeRenderer()
        let scene = Self.makeScene(width: 120, height: 90, depthWidth: 40, depthHeight: 30)
        var plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: false, colors: nil, fNumber: 2,
                                               focusPoint: (0.5, 0.5), personMask: nil, outputLongSide: 120,
                                               settings: LiveFrameAnalyzer.Settings())
        plan.renderEffect = false
        let src = try XCTUnwrap(r.makeTexture(from: scene.image))
        let out = outputTexture(r, 120, 90)
        let cb = try XCTUnwrap(r.commandQueue.makeCommandBuffer())
        r.encode(plan: plan, source: src, output: out, encodeSRGB: false, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        let d = Self.diff("原图", cpu: Self.interleave(scene.image), gpu: r.readBack(out), width: 120, channels: 3, gpuChannels: 4)
        XCTAssertLessThan(d.maxAbs, 1e-6, d.description)
    }

    /// 输出 sRGB 编码（显示用）、源图按比例缩放（相机帧比输出大，走线性采样路径）：和 CPU 的 sRGB 编码一致、没有 NaN
    func testScaledSourceAndSRGBOutput() throws {
        let r = try makeRenderer()
        let scene = Self.makeScene(width: 640, height: 480, depthWidth: 160, depthHeight: 120)
        let plan = LiveFrameAnalyzer.stillPlan(disparity: scene.disparity, relativeDepth: false, colors: scene.colors,
                                               fNumber: 2, focusPoint: (0.5, 0.45), personMask: nil, outputLongSide: 480,
                                               settings: LiveFrameAnalyzer.Settings())
        let src = try XCTUnwrap(r.makeTexture(from: scene.image, pixelFormat: .rgba16Float) ?? r.makeTexture(from: scene.image))
        let out = outputTexture(r, 480, 360)
        let cb = try XCTUnwrap(r.commandQueue.makeCommandBuffer())
        r.encode(plan: plan, source: src, output: out, encodeSRGB: true, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        let px = r.readBack(out)
        XCTAssertEqual(px.count, 480 * 360 * 4)
        XCTAssertFalse(px.contains { !$0.isFinite }, "输出有 NaN")
        // 对焦的盒子中间（一条蓝色条纹的正中）：GPU 输出 ≈ 原图（sRGB 编码）
        let cx = 243, cy = 170
        let si = 226 * 640 + 324
        XCTAssertEqual(px[(cy * 480 + cx) * 4 + 2], SRGB.encodeFloat(scene.image.b[si]), accuracy: 0.03)
    }

    /// 预览显示的坐标变换：竖屏显示横的传感器帧（顺时针转 90°），和点按对焦的换算一致
    func testDisplayTransform() {
        func check(_ t: DisplayTransform, _ u: Double, _ v: Double, _ x: Double, _ y: Double, line: UInt = #line) {
            let p = t.framePoint(u: u, v: v)
            XCTAssertEqual(p.x, x, accuracy: 1e-5, line: line)
            XCTAssertEqual(p.y, y, accuracy: 1e-5, line: line)
        }
        let t = DisplayTransform.portrait(frameWidth: 1440, frameHeight: 1080, viewWidth: 300, viewHeight: 400, zoom: 1)
        check(t, 0.5, 0.5, 0.5, 0.5)
        check(t, 1, 0, 0, 0)        // 屏幕右上角 = 传感器帧的左上角
        check(t, 0, 0, 0, 1)
        check(t, 0, 1, 1, 1)
        let z = DisplayTransform.portrait(frameWidth: 1440, frameHeight: 1080, viewWidth: 300, viewHeight: 400, zoom: 2)
        check(z, 0, 0, 0.25, 0.75)
        // 方形视图：上下不留边、左右留黑边（帧外的点超出 0…1）
        let box = DisplayTransform.portrait(frameWidth: 1440, frameHeight: 1080, viewWidth: 300, viewHeight: 300, zoom: 1)
        XCTAssertGreaterThan(box.framePoint(u: 0, v: 0.5).y, 1)
        check(box, 0.5, 0, 0, 0.5)
    }

    /// 性能（只在真 GPU 上有意义）：相机大小的帧 1920×1440 → 输出 1440×1080，连续 30 帧
    func testPerformance() throws {
        let r = try makeRenderer()
        #if !os(macOS) && !os(iOS)
        throw XCTSkip("软件 Metal 不测性能")
        #else
        let scene = Self.makeScene(width: 1920, height: 1440, depthWidth: 320, depthHeight: 240)
        let src = try XCTUnwrap(r.makeTexture(from: scene.image, pixelFormat: .rgba16Float) ?? r.makeTexture(from: scene.image))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1440, height: 1080, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let out = try XCTUnwrap(r.device.makeTexture(descriptor: d))
        let analyzer = LiveFrameAnalyzer()
        let temporal = MetalTemporalState()
        var gpuMs: [Double] = [], cpuMs: [Double] = []
        for k in 0..<30 {
            let t0 = Date()
            let plan = analyzer.analyze(LiveFrameAnalyzer.Frame(
                disparity: scene.disparity, relativeDepth: false, crop: 1, fNumber: 1.8, focusPoint: (0.5, 0.45),
                focusTapped: k == 0, time: Double(k) / 30, colors: scene.colors, personMask: nil, outputLongSide: 1440))
            let cb = try XCTUnwrap(r.commandQueue.makeCommandBuffer())
            r.encode(plan: plan, source: src, output: out, encodeSRGB: true, temporal: temporal, commandBuffer: cb)
            cpuMs.append(Date().timeIntervalSince(t0) * 1000)
            cb.commit(); cb.waitUntilCompleted()
            if k >= 5 { gpuMs.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        let avg = gpuMs.reduce(0, +) / Double(gpuMs.count)
        print(String(format: "[性能] GPU 每帧 %.2f ms（最慢 %.2f ms），CPU 分析 + 编码 %.2f ms（Debug 构建）",
                     avg, gpuMs.max() ?? 0, cpuMs.dropFirst(5).reduce(0, +) / Double(cpuMs.count - 5)))
        XCTAssertLessThan(avg, 33, "GPU 一帧超过 33 ms，30 fps 跟不上")
        #endif
    }
}
#endif
