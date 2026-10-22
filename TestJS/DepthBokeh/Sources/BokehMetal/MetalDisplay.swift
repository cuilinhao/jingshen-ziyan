#if canImport(Metal)
import Foundation
import Metal

/// 屏幕上的一点 ↔ 帧上的一点。帧是传感器方向（横）的，竖屏显示时顺时针转 90°，
/// 按比例放进视图（fit：留黑边，fill：裁掉多出来的），再以中心放大 zoom 倍（帧的倍率比此刻的刻度小多少就放大多少）。
public struct DisplayTransform: Equatable {
    /// 视图归一化坐标 (u 向右, v 向下) → 帧归一化坐标：fx = a·u + b·v + tx，fy = c·u + d·v + ty
    public var a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float

    public static let identity = DisplayTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// - Parameters:
    ///   - frameWidth/frameHeight: 帧（传感器方向）的像素尺寸
    ///   - viewWidth/viewHeight: 视图尺寸（像素或点，只看比例）
    ///   - zoom: 以中心放大的倍数（≥ 1）
    public static func portrait(frameWidth: Int, frameHeight: Int, viewWidth: Double, viewHeight: Double,
                                zoom: Double, fill: Bool = false) -> DisplayTransform {
        // 竖着显示的图：宽 = 帧高，高 = 帧宽
        let wu = Double(max(frameHeight, 1)), hu = Double(max(frameWidth, 1))
        let vw = max(viewWidth, 1), vh = max(viewHeight, 1)
        let k = fill ? max(vw / wu, vh / hu) : min(vw / wu, vh / hu)
        let z = zoom.isFinite ? max(zoom, 1) : 1
        let su = vw / (wu * k) / z, sv = vh / (hu * k) / z
        // 竖图坐标 U = 0.5 + (u − 0.5)·su，V = 0.5 + (v − 0.5)·sv；帧坐标 = (V, 1 − U)
        return DisplayTransform(a: 0, b: Float(sv), c: Float(-su), d: 0,
                                tx: Float(0.5 - 0.5 * sv), ty: Float(0.5 + 0.5 * su))
    }

    /// 视图归一化坐标 → 帧归一化坐标
    public func framePoint(u: Double, v: Double) -> (x: Double, y: Double) {
        (Double(a) * u + Double(b) * v + Double(tx), Double(c) * u + Double(d) * v + Double(ty))
    }
}

extension MetalBokehRenderer {

    /// 不做虚化，直接把源图（region 那块）缩放进 output（没有深度的帧）
    public func encodeCopy(source: MTLTexture, region: SourceRegion? = nil, output: MTLTexture, encodeSRGB: Bool,
                           commandBuffer: MTLCommandBuffer) {
        let reg = region ?? SourceRegion(x: 0, y: 0, width: Float(source.width), height: Float(source.height))
        let direct = Float(output.width) == reg.width && Float(output.height) == reg.height
            && reg.x == reg.x.rounded() && reg.y == reg.y.rounded()
        var p = GPUComposite(
            cropOrigin: SIMD2(reg.x / Float(source.width), reg.y / Float(source.height)),
            cropSize: SIMD2(reg.width / Float(source.width), reg.height / Float(source.height)),
            readOrigin: SIMD2(Int32(reg.x), Int32(reg.y)), directRead: direct ? 1 : 0,
            encodeSRGB: encodeSRGB ? 1 : 0, effect: 0, pad0: 0, pad1: 0, pad2: 0)
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "原图"
        guard let pipeline = pipeline(named: "compositeKernel") else { enc.endEncoding(); return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(placeholder, index: 1); enc.setTexture(placeholder, index: 2); enc.setTexture(placeholder, index: 3)
        enc.setTexture(output, index: 4)
        withUnsafeBytes(of: &p) { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let tw = pipeline.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / tw)), depth: 1))
        enc.endEncoding()
    }

    /// 显示用的渲染管线（画一个盖住整个视图的三角形，按 DisplayTransform 采样帧）
    public func makeDisplayPipeline(pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let v = library.makeFunction(name: "displayVertex"), let f = library.makeFunction(name: "displayFragment")
        else { throw Failure.missingFunction("displayVertex / displayFragment") }
        let d = MTLRenderPipelineDescriptor()
        d.label = "预览显示"
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// 把帧画进一个 render pass（previous 不为 nil 时按 previousMix 叠上正在淡出的上一帧）
    public func encodeDisplay(_ encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                              frame: MTLTexture, transform: DisplayTransform,
                              previous: MTLTexture? = nil, previousTransform: DisplayTransform = .identity,
                              previousMix: Float = 0) {
        var p = GPUDisplay(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx, ty: transform.ty,
                           pa: previousTransform.a, pb: previousTransform.b, pc: previousTransform.c,
                           pd: previousTransform.d, ptx: previousTransform.tx, pty: previousTransform.ty,
                           previousMix: previous == nil ? 0 : previousMix, pad0: 0, pad1: 0, pad2: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentTexture(previous ?? frame, index: 1)
        withUnsafeBytes(of: &p) { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

struct GPUDisplay {
    var a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float
    var pa: Float, pb: Float, pc: Float, pd: Float, ptx: Float, pty: Float
    var previousMix: Float
    var pad0: Float, pad1: Float, pad2: Float
}
#endif
