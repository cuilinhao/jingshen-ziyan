#if os(iOS)
import MetalKit
import QuartzCore
import SwiftUI
import UIKit
import BokehMetal

/// 预览显示：数据线程把 GPU 渲染好的最新一帧（纹理）放进来，MTKView 在主线程把它画到屏幕上。
///
/// 省电：平时不按屏幕刷新率空转，只在来了新帧、拖刻度盘时画一次；只有点数字的 0.3 秒平滑变焦、
/// 换相机时上一帧淡出这两段动画期间才连续刷新
public final class PreviewDisplay: @unchecked Sendable {   // 可变状态都由 lock 保护，view 只在主线程用

    struct Shown {
        let texture: MTLTexture
        /// 这一帧的视场倍率（1× = 主摄）
        let zoom: CGFloat
        let rotation: Int
        let mirrored: Bool
    }

    let device: MTLDevice
    private let lock = NSLock()
    private var renderer: MetalBokehRenderer?
    private var pipeline: MTLRenderPipelineState?
    private var current: Shown?
    private var held: (frame: Shown, start: CFTimeInterval)?
    private var animateUntil: CFTimeInterval = 0
    /// 此刻刻度盘上的倍率（任意线程可调）
    var zoomProvider: () -> CGFloat = { 1 }
    weak var view: MTKView?
    static let fadeDuration: CFTimeInterval = 0.2

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
    }

    /// 着色器编译好以后接上渲染器
    func attach(_ renderer: MetalBokehRenderer) {
        let pipeline = try? renderer.makeDisplayPipeline(pixelFormat: .bgra8Unorm)
        lock.lock()
        self.renderer = renderer
        self.pipeline = pipeline
        lock.unlock()
        requestRedraw()
    }

    /// 任意线程：显示一帧。holdPrevious = 换相机后的第一帧（或者从原图换成带虚化的第一帧），屏幕上原来那一帧淡出
    func show(_ texture: MTLTexture, zoom: CGFloat, holdPrevious: Bool, rotation: Int = 90, mirrored: Bool = false) {
        lock.lock()
        let now = CACurrentMediaTime()
        if holdPrevious, let old = current {
            // 上一段淡出还没走完（比如新相机先出了原图，紧接着深度到了）：让它接着淡完，不从中间换掉，免得闪一下
            if held.map({ now - $0.start >= Self.fadeDuration }) ?? true {
                held = (old, now)
            }
            animateUntil = max(animateUntil, now + Self.fadeDuration + 0.05)
        }
        current = Shown(texture: texture, zoom: zoom, rotation: rotation, mirrored: mirrored)
        lock.unlock()
        if holdPrevious { animate(until: now + Self.fadeDuration + 0.05) } else { requestRedraw() }
    }

    /// 屏幕上正在显示的那一帧（换相机时要把它留下来淡出，输出纹理池不能再写它）
    var displayedTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return current?.texture
    }

    /// 任意线程：重画一次（拖刻度盘时补上倍率差）
    func requestRedraw() {
        DispatchQueue.main.async { self.view?.setNeedsDisplay() }
    }

    /// 任意线程：到 until 为止连续刷新（平滑变焦、淡出）
    func animate(until: CFTimeInterval) {
        lock.lock()
        animateUntil = max(animateUntil, until)
        lock.unlock()
        DispatchQueue.main.async {
            guard let v = self.view, v.isPaused else { return }
            v.enableSetNeedsDisplay = false
            v.preferredFramesPerSecond = 60
            v.isPaused = false
        }
    }

    /// 视图坐标 → 屏幕上那一帧（传感器方向）的归一化坐标；点在帧外面返回 nil
    public func framePoint(fromView point: CGPoint, viewSize: CGSize) -> CGPoint? {
        lock.lock()
        let frame = current
        lock.unlock()
        guard let frame, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let t = transform(for: frame, viewSize: viewSize, zoom: zoomProvider())
        let p = t.framePoint(u: Double(point.x / viewSize.width), v: Double(point.y / viewSize.height))
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    private func transform(for frame: Shown, viewSize: CGSize, zoom: CGFloat) -> DisplayTransform {
        // 帧的倍率比此刻小多少就放大多少（只放大：裁过的帧补不出更广的画面）
        let residual = frame.zoom > 0 && zoom.isFinite ? max(1, zoom / frame.zoom) : 1
        return DisplayTransform.portrait(frameWidth: frame.texture.width, frameHeight: frame.texture.height,
                                         viewWidth: Double(viewSize.width), viewHeight: Double(viewSize.height),
                                         zoom: Double(residual), rotation: frame.rotation, mirrored: frame.mirrored)
    }

    /// 主线程（MTKView 回调）
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        lock.lock()
        let renderer = self.renderer, pipeline = self.pipeline, frame = current
        var heldFrame = held
        if let h = heldFrame, now - h.start >= Self.fadeDuration { held = nil; heldFrame = nil }
        let animating = now < animateUntil || heldFrame != nil
        lock.unlock()
        if !animating && !view.isPaused {
            // 动画结束：回到「有新帧才画」
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
        guard let renderer, let pipeline, let frame,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = renderer.commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        let zoom = zoomProvider()
        var mix: Float = 0
        var heldTransform = DisplayTransform.identity
        if let h = heldFrame {
            let t = Float(min(max((now - h.start) / Self.fadeDuration, 0), 1))
            mix = 1 - t * t * (3 - 2 * t)
            heldTransform = transform(for: h.frame, viewSize: size, zoom: zoom)
        }
        renderer.encodeDisplay(enc, pipeline: pipeline, frame: frame.texture,
                               transform: transform(for: frame, viewSize: size, zoom: zoom),
                               previous: heldFrame?.frame.texture, previousTransform: heldTransform, previousMix: mix)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

/// SwiftUI 里的预览视图
public struct MetalPreviewView: UIViewRepresentable {
    let display: PreviewDisplay

    public init(display: PreviewDisplay) {
        self.display = display
    }

    public func makeCoordinator() -> Coordinator { Coordinator(display: display) }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: display.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.autoResizeDrawable = true
        // 点按对焦由外面的 SwiftUI 手势处理
        view.isUserInteractionEnabled = false
        // 有新帧才画（setNeedsDisplay），动画期间 PreviewDisplay 临时打开连续刷新
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        display.view = view
        return view
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        display.view = uiView
    }

    public final class Coordinator: NSObject, MTKViewDelegate {
        let display: PreviewDisplay
        init(display: PreviewDisplay) { self.display = display }
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }
        public func draw(in view: MTKView) { display.draw(in: view) }
    }
}
#endif
