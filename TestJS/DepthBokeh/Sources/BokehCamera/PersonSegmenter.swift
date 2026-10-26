#if os(iOS)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision
import BokehCore

/// 系统自带的人像分割（Vision 的 VNGeneratePersonSegmentationRequest）。
///
/// 深度测不到细的、伸出去的东西：侧脸时远处那片眼镜伸出脸的轮廓，后面就是背景，深度图上那里全是背景的深度，
/// 于是镜框和镜片被当成背景虚化掉，看起来蒙了一层。系统相机人像模式也是靠人像分割把整个人（包括眼镜、头发边缘）
/// 留在清晰范围里。对焦点落在人身上时，SubjectMatte 用这张遮罩把和对焦点连着的那个人整体保持清晰。
///
/// 物体也一样：斜着看到的盒子顶面在深度图里只有十来个像素高，靠后的部分拿到的是背景的深度，被虚化得像蒙了一层；
/// 系统相机的盒子却干干净净。所以再跑一个「前景物体」分割（VNGenerateForegroundInstanceMaskRequest，
/// 和相册「抠图」是同一个），对焦点落在某个物体上、深度也对得上时，整个物体保持清晰。
///
/// 实时预览：在单独的队列上跑，每帧用上一次算好的结果，不增加这一帧的延迟；上一次还没算完就跳过这一帧。
final class PersonSegmenter: @unchecked Sendable {   // 可变状态都由 lock 保护
    /// 最近一次的分割结果（都是传感器方向、整个相机画面），和算它们用的那一帧的小图
    /// （遮罩总是晚几帧：拿小图和当前画面比，变了的地方不再相信遮罩）
    struct Masks {
        /// 人像遮罩（0…1）；画面里没人时为 nil
        var person: FloatMap?
        var personColors: PlanarImage?
        /// 物体标签图（0 = 背景，1…N = 各个物体）；没有物体时为 nil
        var objects: FloatMap?
        var objectColors: PlanarImage?
        /// 物体标签图每更新一次加 1（分析时按它缓存选出来的物体，不用每帧重新选）
        var objectRevision = 0
    }

    private let queue = DispatchQueue(label: "depthbokeh.segmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var mask: FloatMap?
    /// 算遮罩那一帧的小图（整个相机画面，线性光）
    private var maskColors: PlanarImage?
    private var objects: FloatMap?
    private var objectColors: PlanarImage?
    private var objectRevision = 0
    private var generation = 0
    /// 最近一秒每次分割的开始时间和耗时（毫秒），状态栏显示
    private var runs: [(start: TimeInterval, ms: Double)] = []
    // 什么时候跑（Vision 跑在神经网络引擎 / GPU 上，跑得越勤越热）。折中：对焦的那个主体在动时和以前一样勤，
    // 不动、或者不是对焦的主体时少跑一些（遮罩本来就用上一次的结果，分析时还会按整体平移挪到这一帧的位置）：
    //  - 点了对焦、换了相机 → 人像、物体都马上跑一次
    //  - 人像：对焦在人身上，人在动（遮罩那块变了）→ 每秒 10 次，没动 → 每秒 5 次；
    //    画面里有人但对焦点不在人身上 → 每秒 2 次；最近 1.5 秒没见过人 → 每秒 2 次（看有没有人进来）
    //  - 物体：对焦点在人身上时不跑（人像遮罩已经管了）。对焦的物体那块变了 → 每秒约 3 次，没变 → 每秒 1 次；
    //    对焦点上没有物体：画面在动 → 每秒 2 次，静止 → 每秒 1 次，动完停下来 → 马上再跑一次
    private var lastObjectStart: TimeInterval = -1
    private var objectsPending = true
    private var personPending = true
    private var movedSinceObjects = false
    /// 物体分割的请求（只在 queue 上用；重复用同一个，不用每次重新准备模型）
    private let objectRequest = VNGenerateForegroundInstanceMaskRequest()
    private let handler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// 最近一次的遮罩（传感器方向，0…1）；画面里没人时全是 0
    var latestMask: FloatMap? {
        lock.lock()
        defer { lock.unlock() }
        return mask
    }

    /// 最近一次的人像 / 物体分割
    var latest: Masks {
        lock.lock()
        defer { lock.unlock() }
        return Masks(person: mask, personColors: maskColors, objects: objects, objectColors: objectColors,
                     objectRevision: objectRevision)
    }

    /// 最近一秒跑了几次分割、平均每次多少毫秒（状态栏）
    func recentLoad(now: TimeInterval) -> (count: Int, ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        runs.removeAll { now - $0.start > 1 }
        return (runs.count, runs.isEmpty ? 0 : runs.map(\.ms).reduce(0, +) / Double(runs.count))
    }

    /// 点了新的对焦点：马上重新分一次人像和物体
    func focusChanged() {
        lock.lock()
        objectsPending = true
        personPending = true
        lock.unlock()
    }

    /// 换了相机：旧画面的遮罩不能再用
    func reset() {
        lock.lock()
        mask = nil
        maskColors = nil
        objects = nil
        objectColors = nil
        objectRevision &+= 1
        generation &+= 1
        lastStart = -1
        lastObjectStart = -1
        objectsPending = true
        personPending = true
        movedSinceObjects = false
        lock.unlock()
    }

    /// 上一次开始分割的时间、最近一次看到人的时间
    private var lastStart: TimeInterval = -1
    private var lastPersonSeen: TimeInterval = -100

    /// 用这一帧更新遮罩（异步，按上面的规则决定这一帧跑不跑、跑哪个）。
    /// - Parameters:
    ///   - moving: 画面在动（手机在动或画面里有东西在动，上一帧的分析结果）
    ///   - personChanged: 上一帧分析时，人像遮罩那块变了不少（FramePlan.personMaskStale）；nil = 不知道
    ///   - objectChanged: 同上，对焦的物体（FramePlan.objectMaskStale）；nil = 对焦点上没有物体
    ///   - focusPoint: 对焦点（相机画面坐标）：落在人身上时不分物体
    ///   - orientation: 原始像素转到正立画面所需的方向（不含预览镜像）
    func update(with pixelBuffer: CVPixelBuffer, now: TimeInterval, moving: Bool, personChanged: Bool?,
                objectChanged: Bool?, focusPoint: (Float, Float), orientation: CGImagePropertyOrientation = .right) {
        lock.lock()
        if busy {
            if moving { movedSinceObjects = true }
            lock.unlock()
            return
        }
        // 对焦点在人身上（允许偏一点：点在眼镜、头发边上）
        let onPerson = mask.map { m in
            let cx = min(m.width - 1, max(0, Int(focusPoint.0 * Float(m.width))))
            let cy = min(m.height - 1, max(0, Int(focusPoint.1 * Float(m.height))))
            let r = max(1, max(m.width, m.height) / 100)
            for y in max(0, cy - r)...min(m.height - 1, cy + r) {
                for x in max(0, cx - r)...min(m.width - 1, cx + r) where m[x, y] > 0.5 { return true }
            }
            return false
        } ?? false
        let personInterval: TimeInterval
        if !onPerson || now - lastPersonSeen > 1.5 {
            personInterval = 0.5
        } else {
            personInterval = (personChanged ?? moving) ? 0.1 : 0.2
        }
        let doPerson = personPending || now - lastStart >= personInterval
        if moving { movedSinceObjects = true }
        var doObjects = false
        if !onPerson {
            if objectsPending {
                doObjects = true
            } else if let changed = objectChanged {
                doObjects = now - lastObjectStart >= (changed ? 0.3 : 1)
            } else if moving {
                doObjects = now - lastObjectStart >= 0.5
            } else {
                doObjects = movedSinceObjects || now - lastObjectStart >= 1
            }
        }
        guard doPerson || doObjects else {
            lock.unlock()
            return
        }
        busy = true
        if doPerson {
            lastStart = now
            personPending = false
        }
        if doObjects {
            lastObjectStart = now
            objectsPending = false
            if !moving { movedSinceObjects = false }
        }
        let gen = generation
        let runObjects = doObjects
        lock.unlock()
        queue.async {
            let t0 = Date().timeIntervalSinceReferenceDate
            let result = doPerson ? self.segment(pixelBuffer, orientation: orientation) : nil
            let hasPerson = result.map { m in m.values.contains { $0 > 0.5 } } ?? false
            let labels = runObjects ? Self.objectLabels(pixelBuffer, request: self.objectRequest, orientation: orientation) : nil
            let hasObjects = labels.map { m in m.values.contains { $0 > 0.5 } } ?? false
            // 同一帧的小图（160 长边够判断哪里变了）
            let thumb = hasPerson || hasObjects ? Self.thumbnail(pixelBuffer) : nil
            let ms = (Date().timeIntervalSinceReferenceDate - t0) * 1000
            self.lock.lock()
            if gen == self.generation {
                if doPerson {
                    self.mask = hasPerson ? result : nil
                    self.maskColors = hasPerson ? thumb : nil
                }
                if runObjects {
                    self.objects = hasObjects ? labels : nil
                    self.objectColors = hasObjects ? thumb : nil
                    self.objectRevision &+= 1
                }
            }
            if hasPerson { self.lastPersonSeen = now }
            self.runs.append((now, ms))
            self.busy = false
            self.lock.unlock()
        }
    }

    /// 前景物体分割（传感器方向的标签图）。不支持的设备（没有神经网络引擎）返回 nil
    static func objectLabels(_ pixelBuffer: CVPixelBuffer,
                             request: VNGenerateForegroundInstanceMaskRequest = VNGenerateForegroundInstanceMaskRequest(),
                             orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        return sensorMask(obs.instanceMask, labels: true, orientation: orientation)
    }

    /// 拍下来的照片（传感器方向）的物体标签图
    static func photoObjects(_ image: CGImage, orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        return sensorMask(obs.instanceMask, labels: true, orientation: orientation)
    }

    private func segment(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        do {
            // 按正立方向交给 Vision；前置传感器的安装方向可能和后置不同
            try handler.perform([request], on: pixelBuffer, orientation: orientation)
            guard let out = request.results?.first?.pixelBuffer else { return nil }
            return Self.sensorMask(out, orientation: orientation)
        } catch {
            return nil
        }
    }

    /// 整个相机画面的小图（传感器方向，线性光，长边 160）
    static func thumbnail(_ pixelBuffer: CVPixelBuffer) -> PlanarImage {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let s = 160 / Double(max(w, h, 1))
        return ImageBridge.planarImage(from: pixelBuffer, width: max(1, Int((Double(w) * s).rounded())),
                                       height: max(1, Int((Double(h) * s).rounded())), crop: 1)
    }

    /// 拍下来的照片（传感器方向）用高质量的分割
    static func photoMask(_ image: CGImage, orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil, let out = request.results?.first?.pixelBuffer else { return nil }
        return sensorMask(out, orientation: orientation)
    }

    /// Vision 输出的遮罩转回原始像素方向；正方形标签图也必须按传入方向旋转。
    /// labels = true：标签图，保留原始整数值（不除以 255）
    static func sensorMask(_ buffer: CVPixelBuffer, labels: Bool = false,
                           orientation: CGImagePropertyOrientation = .right) -> FloatMap? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        // 人像遮罩是 8 位；物体标签图一般也是 8 位（每个像素是物体编号），以防万一也认 32 位浮点
        let isFloat = labels && format == kCVPixelFormatType_OneComponent32Float
        guard format == kCVPixelFormatType_OneComponent8 || isFloat else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard mw > 1, mh > 1 else { return nil }
        var portrait = [Float](repeating: 0, count: mw * mh)
        let scale: Float = labels ? 1 : 1.0 / 255
        for row in 0..<mh {
            let line = base.advanced(by: row * bpr)
            if isFloat {
                let p = line.assumingMemoryBound(to: Float.self)
                for col in 0..<mw { portrait[row * mw + col] = p[col] }
            } else {
                let p = line.assumingMemoryBound(to: UInt8.self)
                for col in 0..<mw { portrait[row * mw + col] = Float(p[col]) * scale }
            }
        }
        return CameraImageOrientation.sensorMap(portrait, width: mw, height: mh, orientation: orientation)
    }
}

/// 把按指定方向送入 Vision / Core ML 的结果转回原始像素坐标；镜像只在显示层处理。
enum CameraImageOrientation {
    static func quarterTurns(for orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .right, .rightMirrored: return 1
        case .down, .downMirrored: return 2
        case .left, .leftMirrored: return 3
        default: return 0
        }
    }

    static func sensorMap(_ values: [Float], width: Int, height: Int,
                          orientation: CGImagePropertyOrientation = .right) -> FloatMap {
        let turns = quarterTurns(for: orientation)
        if turns == 0 { return FloatMap(width: width, height: height, values: values) }
        let rawWidth = turns % 2 == 0 ? width : height
        let rawHeight = turns % 2 == 0 ? height : width
        var raw = [Float](repeating: 0, count: values.count)
        for y in 0..<rawHeight {
            for x in 0..<rawWidth {
                let index: Int
                switch turns {
                case 1: index = x * width + width - 1 - y
                case 2: index = (height - 1 - y) * width + width - 1 - x
                default: index = (height - 1 - x) * width + y
                }
                raw[y * rawWidth + x] = values[index]
            }
        }
        return FloatMap(width: rawWidth, height: rawHeight, values: raw)
    }
}
#endif
