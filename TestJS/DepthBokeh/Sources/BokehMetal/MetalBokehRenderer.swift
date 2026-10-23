#if canImport(Metal)
import Foundation
import Metal
import BokehCore

/// 景深渲染的 GPU 版本：和 `BokehRenderer.renderDetailPreserving`（CPU 参考实现）一步一步对应，结果一致。
///
/// 分工：
///  - CPU（`LiveFrameAnalyzer`）：深度图分辨率（≤ 320×240）上的小活 —— 对焦、主体太近、分层位置、主体种子、
///    手机是否在动，得到一份 `FramePlan`
///  - GPU（这里）：低分辨率 / 全分辨率上的逐像素重活 —— 缩小、深度对齐、跨帧稳定、主体遮罩、分层圆盘模糊、
///    补洞、合成，直接写进屏幕要显示的纹理，不经过 CPU
///
/// 不是线程安全的：同一个对象只在一个队列上用。每次 `encode` 之后必须提交 command buffer
/// （内部最多同时 3 帧在 GPU 上，第 4 帧会等前面的完成）。
public final class MetalBokehRenderer {

    public enum Failure: Error, CustomStringConvertible {
        case noDevice
        case missingFunction(String)
        case resource(String)

        public var description: String {
            switch self {
            case .noDevice: return "没有可用的 Metal 设备"
            case .missingFunction(let n): return "着色器里没有 \(n)"
            case .resource(let n): return "创建 \(n) 失败"
            }
        }
    }

    /// 源图里要渲染的那块（像素坐标）。数码变焦时是中间的一块
    public struct SourceRegion: Equatable {
        public var x: Float, y: Float, width: Float, height: Float
        public init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// 调试 / 测试：这一帧各步骤的中间结果（下一帧会被覆盖）
    public struct DebugTextures {
        /// 低分辨率原图（线性光，rgba32Float）
        public var low: MTLTexture
        /// 引导滤波 + 跨帧稳定之后、主体遮罩之前的视差（r32Float）
        public var refinedDepth: MTLTexture
        /// 最终视差（主体遮罩之后）
        public var depth: MTLTexture
        /// 主体遮罩 α；没有做主体遮罩时为 nil
        public var matte: MTLTexture?
        /// 低分辨率虚化结果（焦外跨帧稳定之后，rgba32Float）
        public var bokeh: MTLTexture
        /// 虚化程度 w（r32Float）
        public var weights: MTLTexture
    }

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var workspace: Workspace?
    private var uploads: [UploadSlot] = []
    private var uploadIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private let dummy: MTLTexture
    /// 没用到的纹理参数绑这个（1×1）
    var placeholder: MTLTexture { dummy }
    func pipeline(named name: String) -> MTLComputePipelineState? { pipelines[name] }

    /// 打开后 `debug` 里保留每一帧的中间结果
    public var keepDebugTextures = false
    public private(set) var debug: DebugTextures?
    /// 上一帧用了多少层
    public private(set) var lastLayerCount = 0

    static let kernelNames = [
        "downsampleKernel", "boxHKernel", "boxVKernel", "minHKernel", "minVKernel",
        "upsampleDepthKernel", "gfPrepareGrayKernel", "gfCoeffGrayKernel", "gfApplyGrayKernel",
        "temporalDepthKernel", "subjectCoreKernel", "gfPrepareColorKernel", "gfCoeffColorKernel",
        "gfApplyColorKernel", "subjectFixKernel", "cocKernel", "boostKernel", "layerTilesKernel",
        "dilateTilesKernel", "layerPrefixKernel", "layerDiskKernel", "layerUpsampleKernel",
        "layerDirectKernel", "clearKernel", "clearUIntKernel", "pullKernel", "pushTopKernel", "pushKernel",
        "finishBokehKernel", "defocusWeightKernel", "stabilizeBokehKernel", "compositeKernel",
        "staleDiffKernel", "staleMaskKernel", "staleQuarterKernel", "staleFlowKernel", "staleWarpKernel",
        "staleSnapKernel",
    ]

    /// 编译着色器（约 0.1–0.3 秒，建议在后台队列上建）
    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.resource("command queue") }
        queue.label = "DepthBokeh"
        commandQueue = queue
        let options = MTLCompileOptions()
        // 不开快速数学：exp / pow / 除法和 CPU 参考实现一致（这些 kernel 的瓶颈在读写内存，不在算术）
        options.fastMathEnabled = false
        library = try device.makeLibrary(source: BokehShaderSource.code, options: options)
        for name in Self.kernelNames {
            guard let f = library.makeFunction(name: name) else { throw Failure.missingFunction(name) }
            pipelines[name] = try device.makeComputePipelineState(function: f)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = MetalBokehRenderer.cpuStorage(device)
        guard let t = device.makeTexture(descriptor: d) else { throw Failure.resource("texture") }
        var zero: Float = 0
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        dummy = t
        uploads = (0..<3).map { _ in UploadSlot() }
    }

    // MARK: - 渲染一帧

    /// 把一帧的渲染编码进 command buffer。
    /// - Parameters:
    ///   - plan: CPU 上的分析结果（`LiveFrameAnalyzer.analyze` 或 `stillPlan`）
    ///   - source: 全分辨率原图。读出来要是线性光（相机帧用 `.bgra8Unorm_srgb`，测试用 `.rgba32Float`）。
    ///     输出和 region 不一样大时要能线性采样
    ///   - region: 源图里要渲染的那块（像素坐标）；nil = 整张
    ///   - output: 输出纹理（要有 shaderWrite），决定输出尺寸。encodeSRGB = true 时写 sRGB 编码值（显示用 `.bgra8Unorm`），
    ///     否则写线性光（测试用 `.rgba32Float`）
    ///   - temporal: 实时预览传同一个对象，跨帧稳定；拍照编辑传 nil
    public func encode(plan: FramePlan, quality: RenderQuality = .preview, refinePasses: Int = 1,
                       source: MTLTexture, region: SourceRegion? = nil, output: MTLTexture, encodeSRGB: Bool,
                       temporal: MetalTemporalState? = nil, commandBuffer: MTLCommandBuffer) {
        let W = output.width, H = output.height
        let reg = region ?? SourceRegion(x: 0, y: 0, width: Float(source.width), height: Float(source.height))
        let direct = Float(W) == reg.width && Float(H) == reg.height
            && reg.x == reg.x.rounded() && reg.y == reg.y.rounded()
        var composite = GPUComposite(
            cropOrigin: SIMD2(reg.x / Float(source.width), reg.y / Float(source.height)),
            cropSize: SIMD2(reg.width / Float(source.width), reg.height / Float(source.height)),
            readOrigin: SIMD2(Int32(reg.x), Int32(reg.y)), directRead: direct ? 1 : 0,
            encodeSRGB: encodeSRGB ? 1 : 0, effect: 0, pad0: 0, pad1: 0, pad2: 0)

        guard plan.renderEffect else {
            // 景深淡出到几乎没有（主体太近）：直接输出原图
            debug = nil
            encodeCopy(source: source, region: region, output: output, encodeSRGB: encodeSRGB, commandBuffer: commandBuffer)
            return
        }

        // ---- 尺寸（和 CPU 的 renderDetailPreserving / downsample 一样）----
        let fullLong = max(W, H)
        let lowLong = max(1, plan.lowLongSide)
        let fullRes = Float(lowLong) / Float(fullLong) >= 0.95
        var lw = W, lh = H, boxFactor = 1
        if !fullRes {
            let k = fullLong / lowLong
            if k >= 2 && fullLong % lowLong == 0 && W % k == 0 && H % k == 0 {
                lw = W / k; lh = H / k; boxFactor = k
            } else {
                let s = Float(lowLong) / Float(fullLong)
                lw = max(1, Int((Float(W) * s).rounded())); lh = max(1, Int((Float(H) * s).rounded()))
                boxFactor = 0
            }
        }
        if !direct { boxFactor = 0 }
        let L = max(lw, lh)
        let ws = workspace(width: lw, height: lh)
        temporal?.ensure(device: device, width: lw, height: lh)

        // ---- 上传深度图和主体种子（CPU 写，所以 3 份轮流用）----
        inFlight.wait()
        let slot = uploads[uploadIndex]
        uploadIndex = (uploadIndex + 1) % uploads.count
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let lens = plan.lens
        let depthMap = DepthRefiner.fillInvalid(plan.depth)
        let upscale = Float(L) / Float(max(depthMap.width, depthMap.height))
        let gfRadius = min(max(2, Int((2.5 * upscale).rounded())), max(2, L / 40))
        let depthTex = slot.upload(depthMap.halvedToFit(width: lw, height: lh), into: \.depth, device: device)
        let df = lens.focusDisparity
        let seeds = (plan.seeds != nil && df > 0) ? plan.seeds : nil
        let connectTex = seeds?.connect.map { slot.upload($0, into: \.connect, device: device) }
        let extraTex = seeds?.extra.map { slot.upload($0, into: \.extra, device: device) }
        let personTex = seeds?.person.map { slot.upload($0, into: \.person, device: device) }

        var gpuLens = GPULens(lens, longSide: L)
        let centers = plan.layerCenters
        let zeroIndex = centers.firstIndex(of: 0) ?? 0
        lastLayerCount = centers.count
        let tilesX = (lw + Self.tile - 1) / Self.tile, tilesY = (lh + Self.tile - 1) / Self.tile

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "景深"

        // ---- 1. 缩小 + 亮度 ----
        // 低分辨率原图：实时预览时留两份轮流写（沿用旧深度的帧要和上一帧比，见 StaleDepth）
        let low = temporal.map { $0.color[$0.cur] } ?? ws.low
        let lumaTex = temporal?.luma[temporal!.cur] ?? ws.luma
        var down = GPUDown(cropOrigin: composite.cropOrigin, cropSize: composite.cropSize,
                           samples: Int32(min(4, max(1, Int((reg.width / Float(lw) / 2).rounded(.up))))),
                           boxFactor: Int32(boxFactor), boxOrigin: composite.readOrigin)
        run(enc, "downsampleKernel", lw, lh) { e in
            e.setTexture(source, index: 0); e.setTexture(low, index: 1); e.setTexture(lumaTex, index: 2)
            self.setValue(e, &down, 0)
        }

        // ---- 2. 深度对齐 ----
        var depthCur = ws.depthA, depthNext = ws.depthB
        // 这一帧没有新深度：不用旧的那张，把上一帧对齐好的深度搬到这一帧（TemporalState.realignStaleDepth）
        let stale = plan.depthAge > 0 && (temporal.map { $0.strength > 0 && $0.hasDepthHistory } ?? false)
        if let t = temporal, stale {
            let prev = 1 - t.cur
            run(enc, "staleDiffKernel", lw, lh) { e in
                e.setTexture(low, index: 0); e.setTexture(t.color[prev], index: 1); e.setTexture(ws.r1a, index: 2)
            }
            var mp = GPUStaleMask(suspectValid: t.suspectValid ? 1 : 0, pad0: 0, pad1: 0, pad2: 0)
            run(enc, "staleMaskKernel", lw, lh) { e in
                e.setTexture(ws.r1a, index: 0)
                e.setTexture(t.suspectValid ? t.suspect[t.suspectCur] : self.dummy, index: 1)
                e.setTexture(ws.staleU, index: 2); e.setTexture(ws.staleUs, index: 3)
                e.setTexture(t.suspect[1 - t.suspectCur], index: 4)
                self.setValue(e, &mp, 0)
            }
            let bw = ws.qNow.width, bh = ws.qNow.height
            run(enc, "staleQuarterKernel", bw, bh) { e in
                e.setTexture(low, index: 0); e.setTexture(t.color[prev], index: 1); e.setTexture(ws.staleU, index: 2)
                e.setTexture(ws.qNow, index: 3); e.setTexture(ws.qPrev, index: 4); e.setTexture(ws.qU, index: 5)
            }
            run(enc, "staleFlowKernel", bw, bh) { e in
                e.setTexture(ws.qNow, index: 0); e.setTexture(ws.qPrev, index: 1); e.setTexture(ws.qU, index: 2)
                e.setTexture(ws.qFlow, index: 3)
            }
            run(enc, "staleWarpKernel", lw, lh) { e in
                e.setTexture(t.depth[prev], index: 0); e.setTexture(low, index: 1); e.setTexture(t.color[prev], index: 2)
                e.setTexture(ws.staleU, index: 3); e.setTexture(ws.qFlow, index: 4); e.setTexture(ws.depthA, index: 5)
            }
            guidedGray(enc, ws, guide: lumaTex, input: ws.depthA, output: ws.r1a, radius: gfRadius)
            run(enc, "staleSnapKernel", lw, lh) { e in
                e.setTexture(ws.depthA, index: 0); e.setTexture(ws.r1a, index: 1); e.setTexture(ws.staleUs, index: 2)
                e.setTexture(ws.depthB, index: 3)
            }
            depthCur = ws.depthB; depthNext = ws.depthA
        } else {
            // 上采样 + 灰度引导滤波
            run(enc, "upsampleDepthKernel", lw, lh) { e in
                e.setTexture(depthTex, index: 0); e.setTexture(ws.depthA, index: 1)
            }
            for pass in 0..<max(0, refinePasses) {
                let r = pass == 0 ? gfRadius : max(1, gfRadius / 2)
                guidedGray(enc, ws, guide: lumaTex, input: depthCur, output: depthNext, radius: r)
                swap(&depthCur, &depthNext)
            }
        }

        // ---- 3. 跨帧稳定（深度）----
        if let t = temporal {
            let prev = 1 - t.cur
            if t.hasDepthHistory { t.stillness = plan.stillness ?? 1 }
            // 新深度来的这一帧：之前被重新对齐过的区域不沿用上一帧
            let gate = !stale && t.suspectValid
            var tp = GPUTemporal(strength: t.strength * t.stillness, invSigma: 1 / t.sigma,
                                 hasHistory: t.hasDepthHistory && t.strength > 0 ? 1 : 0, gate: gate ? 1 : 0)
            let out = t.depth[t.cur]
            run(enc, "temporalDepthKernel", lw, lh) { e in
                e.setTexture(t.luma[t.cur], index: 0); e.setTexture(t.luma[prev], index: 1)
                e.setTexture(depthCur, index: 2); e.setTexture(t.depth[prev], index: 3)
                e.setTexture(out, index: 4); e.setTexture(ws.blend, index: 5)
                e.setTexture(gate ? t.suspect[t.suspectCur] : self.dummy, index: 6)
                self.setValue(e, &tp, 0)
            }
            depthCur = out
            if stale {
                t.suspectCur = 1 - t.suspectCur
                t.suspectValid = true
            } else {
                t.suspectValid = false
            }
        }
        let refinedDepth = depthCur

        // ---- 4. 主体遮罩 ----
        var matte: MTLTexture?
        if let seeds {
            var sp = GPUSubject(focusDisparity: df, normScale: max(lens.relativeScale ?? df, 1e-3),
                                band: plan.matte.band, eps: plan.matte.epsilon,
                                hasConnect: seeds.connect != nil ? 1 : 0, hasExtra: seeds.extra != nil ? 1 : 0,
                                hasPerson: seeds.person != nil ? 1 : 0, pad: 0)
            let r = SubjectMatte.radius(width: lw, height: lh, parameters: plan.matte)
            run(enc, "subjectCoreKernel", lw, lh) { e in
                e.setTexture(depthCur, index: 0)
                e.setTexture(connectTex ?? self.dummy, index: 1); e.setTexture(extraTex ?? self.dummy, index: 2)
                e.setTexture(ws.core, index: 3); e.setTexture(ws.depthCore, index: 4)
                self.setValue(e, &sp, 0)
            }
            run(enc, "gfPrepareColorKernel", lw, lh) { e in
                e.setTexture(low, index: 0); e.setTexture(ws.core, index: 1)
                e.setTexture(ws.m1, index: 2); e.setTexture(ws.m2, index: 3); e.setTexture(ws.m3, index: 4)
            }
            box(enc, ws.m1, temp: ws.f4a, radius: r)
            box(enc, ws.m2, temp: ws.f4a, radius: r)
            box(enc, ws.m3, temp: ws.f4a, radius: r)
            var eps = plan.matte.epsilon
            run(enc, "gfCoeffColorKernel", lw, lh) { e in
                e.setTexture(ws.m1, index: 0); e.setTexture(ws.m2, index: 1); e.setTexture(ws.m3, index: 2)
                e.setTexture(ws.f4b, index: 3); e.setTexture(ws.f4c, index: 4)
                self.setValue(e, &eps, 0)
            }
            box(enc, ws.f4b, temp: ws.f4a, radius: r)
            box(enc, ws.f4c, temp: ws.f4a, radius: r)
            run(enc, "gfApplyColorKernel", lw, lh) { e in
                e.setTexture(low, index: 0); e.setTexture(ws.f4b, index: 1); e.setTexture(ws.f4c, index: 2)
                e.setTexture(personTex ?? self.dummy, index: 3); e.setTexture(ws.alpha, index: 4)
                self.setValue(e, &sp, 0)
            }
            var rr = Int32(r)
            run(enc, "minHKernel", lw, lh) { e in
                e.setTexture(depthCur, index: 0); e.setTexture(ws.r1a, index: 1); self.setValue(e, &rr, 0)
            }
            run(enc, "minVKernel", lw, lh) { e in
                e.setTexture(ws.r1a, index: 0); e.setTexture(ws.r1b, index: 1); self.setValue(e, &rr, 0)
            }
            let fixed = depthCur === ws.depthA ? ws.depthB : ws.depthA
            run(enc, "subjectFixKernel", lw, lh) { e in
                e.setTexture(depthCur, index: 0); e.setTexture(ws.alpha, index: 1); e.setTexture(ws.depthCore, index: 2)
                e.setTexture(ws.r1b, index: 3); e.setTexture(fixed, index: 4)
                self.setValue(e, &sp, 0)
            }
            depthCur = fixed
            matte = ws.alpha
        }

        // ---- 5. 模糊半径、分层、高光 ----
        let gain = quality.highlightGain
        let hasBoostHistory = temporal.map { $0.hasBoostHistory && $0.hasDepthHistory } ?? false
        var lp = GPULayerParams(count: Int32(centers.count), zeroIndex: Int32(zeroIndex), tilesX: Int32(tilesX),
                                tilesY: Int32(tilesY), highlightThreshold: quality.highlightThreshold,
                                highlightGain: gain, hasBoostHistory: hasBoostHistory ? 1 : 0, pad: 0)
        var centerValues = centers
        run(enc, "cocKernel", lw, lh) { e in
            e.setTexture(depthCur, index: 0); e.setTexture(low, index: 1)
            e.setTexture(ws.s, index: 2); e.setTexture(ws.maxC, index: 3)
            e.setBuffer(ws.layerPos, offset: 0, index: 0)
            self.setValue(e, &gpuLens, 1)
            self.setArray(e, &centerValues, 2)
            self.setValue(e, &lp, 3)
        }
        if gain > 0 {
            box(enc, ws.maxC, temp: ws.r1a, radius: max(3, L / 25), output: ws.localMean)
        }
        let boostOut = temporal.map { $0.boost[$0.cur] } ?? ws.boost
        let prevBoost = temporal.map { $0.boost[1 - $0.cur] } ?? dummy
        run(enc, "boostKernel", lw, lh) { e in
            e.setTexture(low, index: 0); e.setTexture(ws.s, index: 1); e.setTexture(ws.maxC, index: 2)
            e.setTexture(gain > 0 ? ws.localMean : self.dummy, index: 3)
            e.setTexture(hasBoostHistory ? prevBoost : self.dummy, index: 4)
            e.setTexture(temporal != nil ? ws.blend : self.dummy, index: 5)
            e.setTexture(boostOut, index: 6)
            e.setBuffer(ws.src, offset: 0, index: 0)
            self.setValue(e, &lp, 1)
        }

        // ---- 6. 分层模糊 ----
        // 每层的 q（先缩小几倍）、缩小后的半径、能够到的分块数
        let passes: [GPULayerPass] = centers.indices.map { k in
            let r = abs(centers[k])
            let q = Self.downsampleFactor(forRadius: r)
            return GPULayerPass(layer: Int32(k), q: Int32(q), planeW: Int32((lw + q - 1) / q),
                                planeH: Int32((lh + q - 1) / q), fullW: Int32(lw), fullH: Int32(lh),
                                additive: k > zeroIndex ? 1 : 0, tilesX: Int32(tilesX), radius: r / Float(q),
                                pad0: 0, pad1: 0, pad2: 0)
        }
        var reach: [Int32] = passes.map { p in
            if abs(centers[Int(p.layer)]) < 0.5 { return 0 }
            let Ri = Int(p.radius)
            return Int32(((Ri + 3) * Int(p.q) + Self.tile - 1) / Self.tile)
        }
        clearUInt(enc, ws.tiles, count: tilesX * tilesY)
        var size = SIMD2<Int32>(Int32(lw), Int32(lh))
        run(enc, "layerTilesKernel", tilesX, lh) { e in
            e.setBuffer(ws.layerPos, offset: 0, index: 0); e.setBuffer(ws.tiles, offset: 0, index: 1)
            self.setValue(e, &lp, 2); self.setValue(e, &size, 3)
        }
        run(enc, "dilateTilesKernel", tilesX, tilesY) { e in
            e.setBuffer(ws.tiles, offset: 0, index: 0); e.setBuffer(ws.dilated, offset: 0, index: 1)
            e.setBuffer(ws.rowMask, offset: 0, index: 2)
            self.setArray(e, &reach, 3)
            self.setValue(e, &lp, 4)
        }
        // 背景层 + 对焦层：从远到近 over 合成
        clear(enc, ws.acc, count: lw * lh)
        for k in 0...zeroIndex { encodeLayer(enc, ws, passes[k], centers[k], into: ws.acc) }
        // 补洞
        pullPush(enc, ws)
        // 前景层：加法累积
        let hasForeground = zeroIndex + 1 < centers.count
        if hasForeground {
            clear(enc, ws.fg, count: lw * lh)
            for k in (zeroIndex + 1)..<centers.count { encodeLayer(enc, ws, passes[k], centers[k], into: ws.fg) }
        }
        var fgFlag: Int32 = hasForeground ? 1 : 0
        run(enc, "finishBokehKernel", lw, lh) { e in
            e.setBuffer(ws.acc, offset: 0, index: 0); e.setBuffer(ws.filled[0], offset: 0, index: 1)
            e.setBuffer(ws.fg, offset: 0, index: 2); self.setValue(e, &fgFlag, 3)
            e.setTexture(ws.bokeh, index: 0)
        }

        // ---- 7. 虚化程度 w、焦外跨帧稳定 ----
        run(enc, "defocusWeightKernel", lw, lh) { e in
            e.setTexture(depthCur, index: 0); e.setTexture(low, index: 1); e.setTexture(ws.bokeh, index: 2)
            e.setTexture(ws.w, index: 3)
            self.setValue(e, &gpuLens, 0)
        }
        var bokehFinal = ws.bokeh
        if let t = temporal, !fullRes {
            var tp = GPUTemporal(strength: t.backgroundStrength * t.stillness, invSigma: 1 / t.backgroundSigma,
                                 hasHistory: t.hasBokehHistory && t.backgroundStrength > 0 ? 1 : 0, gate: 0)
            let out = t.bokeh[t.cur]
            run(enc, "stabilizeBokehKernel", lw, lh) { e in
                e.setTexture(ws.bokeh, index: 0); e.setTexture(t.bokeh[1 - t.cur], index: 1)
                e.setTexture(ws.w, index: 2); e.setTexture(out, index: 3)
                self.setValue(e, &tp, 0)
            }
            bokehFinal = out
        }

        // ---- 8. 合成到全分辨率 ----
        composite.effect = fullRes ? 2 : 1
        run(enc, "compositeKernel", W, H) { e in
            e.setTexture(source, index: 0); e.setTexture(low, index: 1); e.setTexture(bokehFinal, index: 2)
            e.setTexture(ws.w, index: 3); e.setTexture(output, index: 4)
            self.setValue(e, &composite, 0)
        }
        enc.endEncoding()

        if let t = temporal {
            t.hasDepthHistory = true
            t.hasBoostHistory = gain > 0
            if !fullRes { t.hasBokehHistory = true }
            t.cur = 1 - t.cur
        }
        debug = keepDebugTextures
            ? DebugTextures(low: low, refinedDepth: refinedDepth, depth: depthCur, matte: matte,
                            bokeh: bokehFinal, weights: ws.w)
            : nil
    }

    // MARK: - 分层

    static let tile = 16

    /// BokehRenderer.downsampleFactor：半径大的层先缩小再模糊
    static func downsampleFactor(forRadius r: Float) -> Int {
        var q = 1
        while q < 8 && r / Float(q * 2) >= 8 { q *= 2 }
        return q
    }

    private func encodeLayer(_ enc: MTLComputeCommandEncoder, _ ws: Workspace, _ pass: GPULayerPass,
                             _ center: Float, into acc: MTLBuffer) {
        var p = pass
        let lw = Int(p.fullW), lh = Int(p.fullH)
        if abs(center) < 0.5 {
            run(enc, "layerDirectKernel", lw, lh) { e in
                e.setBuffer(ws.src, offset: 0, index: 0); e.setBuffer(ws.layerPos, offset: 0, index: 1)
                e.setBuffer(acc, offset: 0, index: 2); e.setBuffer(ws.dilated, offset: 0, index: 3)
                self.setValue(e, &p, 4)
            }
            return
        }
        let pw = Int(p.planeW), ph = Int(p.planeH)
        // 逐行前缀和：一个线程组（64 线程）一行
        let prefix = pipelines["layerPrefixKernel"]!
        enc.setComputePipelineState(prefix)
        enc.setBuffer(ws.src, offset: 0, index: 0); enc.setBuffer(ws.layerPos, offset: 0, index: 1)
        enc.setBuffer(ws.prefix, offset: 0, index: 2); enc.setBuffer(ws.rowMask, offset: 0, index: 3)
        setValue(enc, &p, 4)
        enc.dispatchThreadgroups(MTLSize(width: ph, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        run(enc, "layerDiskKernel", pw, ph) { e in
            e.setBuffer(ws.prefix, offset: 0, index: 0); e.setBuffer(acc, offset: 0, index: 1)
            e.setBuffer(ws.lowOut, offset: 0, index: 2); e.setBuffer(ws.dilated, offset: 0, index: 3)
            self.setValue(e, &p, 4)
        }
        if p.q > 1 {
            run(enc, "layerUpsampleKernel", lw, lh) { e in
                e.setBuffer(ws.lowOut, offset: 0, index: 0); e.setBuffer(acc, offset: 0, index: 1)
                e.setBuffer(ws.dilated, offset: 0, index: 2)
                self.setValue(e, &p, 3)
            }
        }
    }

    /// PullPush.fill：acc（预乘颜色 + 覆盖率）→ ws.filled[0]
    private func pullPush(_ enc: MTLComputeCommandEncoder, _ ws: Workspace) {
        let dims = ws.levelDims
        func level(_ l: Int) -> MTLBuffer { l == 0 ? ws.acc : ws.pulled[l] }
        for l in 1..<max(1, dims.count) {
            var d = GPULevelDims(w: Int32(dims[l].0), h: Int32(dims[l].1),
                                 cw: Int32(dims[l - 1].0), ch: Int32(dims[l - 1].1))
            run(enc, "pullKernel", dims[l].0, dims[l].1) { e in
                e.setBuffer(level(l - 1), offset: 0, index: 0); e.setBuffer(level(l), offset: 0, index: 1)
                self.setValue(e, &d, 2)
            }
        }
        let top = dims.count - 1
        run(enc, "pushTopKernel", 1, 1) { e in
            e.setBuffer(level(top), offset: 0, index: 0); e.setBuffer(ws.filled[top], offset: 0, index: 1)
        }
        if top >= 1 {
            for l in stride(from: top - 1, through: 0, by: -1) {
                var d = GPULevelDims(w: Int32(dims[l].0), h: Int32(dims[l].1),
                                     cw: Int32(dims[l + 1].0), ch: Int32(dims[l + 1].1))
                run(enc, "pushKernel", dims[l].0, dims[l].1) { e in
                    e.setBuffer(level(l), offset: 0, index: 0); e.setBuffer(ws.filled[l + 1], offset: 0, index: 1)
                    e.setBuffer(ws.filled[l], offset: 0, index: 2)
                    self.setValue(e, &d, 3)
                }
            }
        }
    }

    // MARK: - 小工具

    /// 可分离盒式均值：tex → (水平) → temp → (垂直) → output（默认写回 tex）
    /// 灰度引导滤波（DepthRefiner.guidedFilter，eps 2e-4）。f4a / f4b / f4c 当临时纹理
    private func guidedGray(_ enc: MTLComputeCommandEncoder, _ ws: Workspace, guide: MTLTexture, input: MTLTexture,
                            output: MTLTexture, radius r: Int) {
        run(enc, "gfPrepareGrayKernel", ws.width, ws.height) { e in
            e.setTexture(guide, index: 0); e.setTexture(input, index: 1); e.setTexture(ws.f4a, index: 2)
        }
        box(enc, ws.f4a, temp: ws.f4b, radius: r)
        var eps: Float = 2e-4
        run(enc, "gfCoeffGrayKernel", ws.width, ws.height) { e in
            e.setTexture(ws.f4a, index: 0); e.setTexture(ws.f4c, index: 1)
            self.setValue(e, &eps, 0)
        }
        box(enc, ws.f4c, temp: ws.f4b, radius: r)
        run(enc, "gfApplyGrayKernel", ws.width, ws.height) { e in
            e.setTexture(guide, index: 0); e.setTexture(ws.f4c, index: 1); e.setTexture(output, index: 2)
        }
    }

    private func box(_ enc: MTLComputeCommandEncoder, _ tex: MTLTexture, temp: MTLTexture, radius: Int,
                     output: MTLTexture? = nil) {
        let w = tex.width, h = tex.height, seg = 16
        var r = Int32(radius)
        run(enc, "boxHKernel", (w + seg - 1) / seg, h) { e in
            e.setTexture(tex, index: 0); e.setTexture(temp, index: 1); self.setValue(e, &r, 0)
        }
        run(enc, "boxVKernel", w, (h + seg - 1) / seg) { e in
            e.setTexture(temp, index: 0); e.setTexture(output ?? tex, index: 1); self.setValue(e, &r, 0)
        }
    }

    private func clear(_ enc: MTLComputeCommandEncoder, _ buffer: MTLBuffer, count: Int) {
        var n = UInt32(count)
        run(enc, "clearKernel", count, 1) { e in
            e.setBuffer(buffer, offset: 0, index: 0); self.setValue(e, &n, 1)
        }
    }

    private func clearUInt(_ enc: MTLComputeCommandEncoder, _ buffer: MTLBuffer, count: Int) {
        var n = UInt32(count)
        run(enc, "clearUIntKernel", count, 1) { e in
            e.setBuffer(buffer, offset: 0, index: 0); self.setValue(e, &n, 1)
        }
    }

    private func run(_ enc: MTLComputeCommandEncoder, _ name: String, _ w: Int, _ h: Int,
                     _ bind: (MTLComputeCommandEncoder) -> Void) {
        guard w > 0, h > 0, let p = pipelines[name] else { return }
        enc.setComputePipelineState(p)
        bind(enc)
        let tw = p.threadExecutionWidth
        let th = h == 1 ? 1 : max(1, min(p.maxTotalThreadsPerThreadgroup / tw, 8))
        let width = h == 1 ? min(p.maxTotalThreadsPerThreadgroup, 256) : tw
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: th, depth: 1))
    }

    private func setValue<T>(_ enc: MTLComputeCommandEncoder, _ value: inout T, _ index: Int) {
        withUnsafeBytes(of: &value) { enc.setBytes($0.baseAddress!, length: $0.count, index: index) }
    }

    private func setArray<T>(_ enc: MTLComputeCommandEncoder, _ values: inout [T], _ index: Int) {
        values.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: max(4, $0.count), index: index) }
    }

    /// 释放中间结果（拍照编辑器关闭时调用：照片分辨率的中间结果有一两百 MB）。下次 encode 会重新分配
    public func purgeIntermediates() {
        workspace = nil
        debug = nil
        uploads = (0..<3).map { _ in UploadSlot() }
    }

    private func workspace(width: Int, height: Int) -> Workspace {
        if let ws = workspace, ws.width == width, ws.height == height { return ws }
        let ws = Workspace(device: device, width: width, height: height)
        workspace = ws
        return ws
    }

    /// CPU 要写的纹理用的存储方式（iOS 和 Apple 芯片的 Mac 是统一内存；Intel Mac 用 managed）
    static func cpuStorage(_ device: MTLDevice) -> MTLStorageMode {
        #if os(macOS)
        return device.hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }

    // MARK: - 测试 / 调试用的读写

    /// 把 PlanarImage（线性光）上传成纹理（.rgba32Float，或 Apple 芯片上的 .rgba16Float）
    public func makeTexture(from image: PlanarImage, pixelFormat: MTLPixelFormat = .rgba32Float) -> MTLTexture? {
        let w = image.width, h = image.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = MetalBokehRenderer.cpuStorage(device)
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let region = MTLRegionMake2D(0, 0, w, h)
        switch pixelFormat {
        case .rgba32Float:
            var px = [Float](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) { px[4 * i] = image.r[i]; px[4 * i + 1] = image.g[i]; px[4 * i + 2] = image.b[i] }
            px.withUnsafeBytes { t.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        #if arch(arm64)
        case .rgba16Float:
            var px = [Float16](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) {
                px[4 * i] = Float16(image.r[i]); px[4 * i + 1] = Float16(image.g[i]); px[4 * i + 2] = Float16(image.b[i])
            }
            px.withUnsafeBytes { t.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        #endif
        default:
            return nil
        }
        return t
    }

    /// 同步读回一张 r32Float / rgba32Float 纹理（每个像素 1 或 4 个 Float）
    public func readBack(_ texture: MTLTexture) -> [Float] {
        let channels = texture.pixelFormat == .rgba32Float ? 4 : 1
        let bytesPerRow = texture.width * channels * 4
        let length = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let cb = commandQueue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = buffer.contents().bindMemory(to: Float.self, capacity: length / 4)
        return Array(UnsafeBufferPointer(start: p, count: length / 4))
    }
}

// MARK: - 跨帧状态

/// 实时预览的跨帧历史（GPU 上）。和 `TemporalState` 的参数、规则一样
public final class MetalTemporalState {
    /// 画面完全静止的像素沿用上一帧的比例（0 = 关闭）
    public var strength: Float = 0.6
    /// 亮度变化的尺度
    public var sigma: Float = 0.025
    /// 焦外区域的时间平滑强度
    public var backgroundStrength: Float = 0.7
    public var backgroundSigma: Float = 0.25

    var width = 0, height = 0
    var luma: [MTLTexture] = [], depth: [MTLTexture] = [], boost: [MTLTexture] = [], bokeh: [MTLTexture] = []
    /// 低分辨率原图（线性光）
    var color: [MTLTexture] = []
    var cur = 0
    var hasDepthHistory = false, hasBoostHistory = false, hasBokehHistory = false
    var stillness: Float = 1
    /// 上一张新深度以来被重新对齐过的区域（TemporalState.suspect）。只在写的时候换一份
    var suspect: [MTLTexture] = []
    var suspectCur = 0
    var suspectValid = false

    public init() {}

    /// 换了相机或倍率：历史作废
    public func reset() {
        hasDepthHistory = false; hasBoostHistory = false; hasBokehHistory = false
        stillness = 1
        suspectValid = false
    }

    func ensure(device: MTLDevice, width w: Int, height h: Int) {
        guard w != width || h != height || luma.isEmpty else { return }
        width = w; height = h
        func make(_ f: MTLPixelFormat) -> [MTLTexture] { (0..<2).map { _ in Workspace.texture(device, w, h, f) } }
        luma = make(.r32Float); depth = make(.r32Float); boost = make(.r32Float); bokeh = make(.rgba32Float)
        color = make(.rgba32Float); suspect = make(.r32Float)
        hasDepthHistory = false; hasBoostHistory = false; hasBokehHistory = false
        suspectValid = false
        cur = 0
    }
}

// MARK: - 工作区（低分辨率上的中间结果）

final class Workspace {
    let width: Int, height: Int
    let low, luma, depthA, depthB, blend: MTLTexture
    let f4a, f4b, f4c, m1, m2, m3: MTLTexture
    let core, depthCore, alpha, r1a, r1b: MTLTexture
    let s, maxC, localMean, boost, bokeh, w: MTLTexture
    /// 沿用旧深度时（StaleDepth）：变了的程度 U、贴边范围 Us；1/4 分辨率的颜色、U、运动
    let staleU, staleUs, qNow, qPrev, qU, qFlow: MTLTexture
    let src, layerPos, prefix, lowOut, acc, fg: MTLBuffer
    let tiles, dilated, rowMask: MTLBuffer
    let levelDims: [(Int, Int)]
    let pulled: [MTLBuffer]   // [0] 不用（第 0 级就是 acc）
    let filled: [MTLBuffer]

    static func texture(_ device: MTLDevice, _ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    init(device: MTLDevice, width: Int, height: Int) {
        self.width = width; self.height = height
        func t1() -> MTLTexture { Self.texture(device, width, height, .r32Float) }
        func t4() -> MTLTexture { Self.texture(device, width, height, .rgba32Float) }
        func buf(_ bytes: Int) -> MTLBuffer { device.makeBuffer(length: max(16, bytes), options: .storageModePrivate)! }
        low = t4(); luma = t1(); depthA = t1(); depthB = t1(); blend = t1()
        f4a = t4(); f4b = t4(); f4c = t4(); m1 = t4(); m2 = t4(); m3 = t4()
        core = t1(); depthCore = t1(); alpha = t1(); r1a = t1(); r1b = t1()
        s = t1(); maxC = t1(); localMean = t1(); boost = t1(); bokeh = t4(); w = t1()
        staleU = t1(); staleUs = t1()
        let bw = (width + StaleDepth.block - 1) / StaleDepth.block, bh = (height + StaleDepth.block - 1) / StaleDepth.block
        qNow = Self.texture(device, bw, bh, .rgba32Float); qPrev = Self.texture(device, bw, bh, .rgba32Float)
        qU = Self.texture(device, bw, bh, .r32Float); qFlow = Self.texture(device, bw, bh, .rgba32Float)
        let n = width * height
        src = buf(n * 16); layerPos = buf(n * 8)
        prefix = buf((width + 1) * height * 16)
        lowOut = buf(((width + 1) / 2) * ((height + 1) / 2) * 16)
        acc = buf(n * 16); fg = buf(n * 16)
        let tx = (width + MetalBokehRenderer.tile - 1) / MetalBokehRenderer.tile
        let ty = (height + MetalBokehRenderer.tile - 1) / MetalBokehRenderer.tile
        tiles = buf(tx * ty * 4); dilated = buf(tx * ty * 4); rowMask = buf(ty * 4)
        var dims = [(width, height)]
        while dims.last!.0 > 1 || dims.last!.1 > 1 {
            let (pw, ph) = dims.last!
            dims.append((max(1, (pw + 1) / 2), max(1, (ph + 1) / 2)))
        }
        levelDims = dims
        pulled = dims.enumerated().map { i, d in i == 0 ? buf(16) : buf(d.0 * d.1 * 16) }
        filled = dims.map { d in buf(d.0 * d.1 * 16) }
    }
}

/// CPU 每帧写入的纹理（深度图、主体种子）。GPU 可能还在用上一帧的，所以轮流用 3 份
final class UploadSlot {
    var depth: MTLTexture?
    var connect: MTLTexture?
    var extra: MTLTexture?
    var person: MTLTexture?

    func upload(_ map: FloatMap, into key: ReferenceWritableKeyPath<UploadSlot, MTLTexture?>, device: MTLDevice) -> MTLTexture {
        var t = self[keyPath: key]
        if t == nil || t!.width != map.width || t!.height != map.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: map.width,
                                                             height: map.height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = MetalBokehRenderer.cpuStorage(device)
            t = device.makeTexture(descriptor: d)
            self[keyPath: key] = t
        }
        map.values.withUnsafeBytes {
            t!.replace(region: MTLRegionMake2D(0, 0, map.width, map.height), mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: map.width * 4)
        }
        return t!
    }
}

// MARK: - 传给着色器的参数（字段顺序、类型和 BokehShaderSource 里的 struct 一一对应）

struct GPULens {
    var fNumber: Float
    var focusDisparity: Float
    var focalLength35mm: Float
    var maxBlurFraction: Float
    var focusTolerance: Float
    var blurK: Float
    var frontTolerance: Float
    var frontSlope: Float
    var frontMax: Float
    var backTolerance: Float
    var backSlope: Float
    var backMax: Float
    var softLimitFraction: Float
    var longSide: Float
    var model: Int32
    var pad: Int32 = 0

    init(_ l: LensParameters, longSide: Int) {
        fNumber = l.fNumber
        focusDisparity = l.focusDisparity
        focalLength35mm = l.focalLength35mm
        maxBlurFraction = l.maxBlurFraction
        focusTolerance = l.focusTolerance
        blurK = l.blurK
        frontTolerance = l.frontTolerance
        frontSlope = l.frontSlope
        frontMax = l.frontMax
        backTolerance = l.backTolerance
        backSlope = l.backSlope
        backMax = l.backMax
        softLimitFraction = l.softLimitFraction
        self.longSide = Float(longSide)
        model = l.model == .system ? 0 : 1
    }
}

struct GPUDown {
    var cropOrigin: SIMD2<Float>
    var cropSize: SIMD2<Float>
    var samples: Int32
    var boxFactor: Int32
    var boxOrigin: SIMD2<Int32>
}

struct GPUTemporal {
    var strength: Float
    var invSigma: Float
    var hasHistory: Int32
    var gate: Int32
}

struct GPUStaleMask {
    var suspectValid: Int32
    var pad0: Int32
    var pad1: Int32
    var pad2: Int32
}

struct GPUSubject {
    var focusDisparity: Float
    var normScale: Float
    var band: Float
    var eps: Float
    var hasConnect: Int32
    var hasExtra: Int32
    var hasPerson: Int32
    var pad: Int32
}

struct GPULayerParams {
    var count: Int32
    var zeroIndex: Int32
    var tilesX: Int32
    var tilesY: Int32
    var highlightThreshold: Float
    var highlightGain: Float
    var hasBoostHistory: Int32
    var pad: Int32
}

struct GPULayerPass {
    var layer: Int32
    var q: Int32
    var planeW: Int32
    var planeH: Int32
    var fullW: Int32
    var fullH: Int32
    var additive: Int32
    var tilesX: Int32
    var radius: Float
    var pad0: Int32
    var pad1: Int32
    var pad2: Int32
}

struct GPULevelDims {
    var w: Int32
    var h: Int32
    var cw: Int32
    var ch: Int32
}

struct GPUComposite {
    var cropOrigin: SIMD2<Float>
    var cropSize: SIMD2<Float>
    var readOrigin: SIMD2<Int32>
    var directRead: Int32
    var encodeSRGB: Int32
    var effect: Int32
    var pad0: Int32
    var pad1: Int32
    var pad2: Int32
}
#endif
