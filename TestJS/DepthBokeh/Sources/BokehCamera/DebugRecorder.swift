#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Foundation
import UIKit
import BokehCore

/// 调试数据录制：出问题的时候录几秒 App 实际收到、实际用到的数据，拷到电脑上用同一份分析代码
/// （bokeh-cli --live）原样重放，看深度在哪一步出错。
///
/// 录下来的东西（都是传感器原始方向，横向；在 Documents/DebugRecordings/rec-日期-时间/ 里）：
///  - img_NNNN.jpg：每一帧相机整帧（长边最多 1920）
///  - depth_raw_NNNN.pfm：系统给的原始深度（转成 32 位视差，无效值 NaN / 0 / 负数原样保留），只在有新深度的帧写
///  - depth_NNNN.pfm：App 实际交给分析的视差图（ImageBridge.disparityMap 之后：无效值是 NaN，相对视差平移过）
///  - person_NNNN.pfm / people_NNNN.pfm / objects_NNNN.pfm 和对应的 *_img.ppm：分割结果和算它那一帧的小图（变了才写）
///  - frames.jsonl：每帧一行（时间、用的哪张图 / 深度、深度格式、是否系统滤波过、裁切、焦段、对焦点、点按、ƒ、
///    锁定对焦、分割开关、这一帧分析出来的对焦视差 / 距离……）
///  - recording.json：机型、系统、相机设备和格式、标定参数、录制过程中滤波开关的时间点
/// PFM：每个像素一个 32 位小端浮点数，行从下往上存（和 bokeh-cli 读写的一样）。
final class DebugRecorder: @unchecked Sendable {   // 可变状态由 lock 保护，或只在 writer 队列上用
    let folder: URL
    private let writer = DispatchQueue(label: "depthbokeh.recorder", qos: .utility)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var lines: [String] = []
    private var frameIndex = 0
    private var inFlight = 0
    private var skippedImages = 0
    private var lastDepthFile: NSObject = NSNull()
    private var lastMaskRevision: (person: Int, people: Int, objects: Int) = (-1, -1, -1)
    private var maskFiles: [String: Any] = [:]
    private var events: [[String: Any]] = []
    private var calibration: [String: Any]?
    private let start = CACurrentMediaTime()

    /// 录制文件夹的上级目录（Documents/DebugRecordings）
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DebugRecordings", isDirectory: true)
    }

    init?() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        folder = Self.root.appendingPathComponent("rec-" + f.string(from: Date()), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
    }

    /// 录制过程中的事件（滤波开 / 关），写进 recording.json
    func mark(_ name: String) {
        lock.lock()
        events.append(["t": CACurrentMediaTime() - start, "event": name])
        lock.unlock()
    }

    /// dataQueue：记一帧。info 是这一帧的参数（JSON 能存的类型）
    func addFrame(pixelBuffer: CVPixelBuffer, rawDepth: AVDepthData?, pipelineDepth: FloatMap?, depthAge: Int,
                  masks: PersonSegmenter.Masks?, info: [String: Any]) {
        lock.lock()
        let i = frameIndex
        frameIndex += 1
        // 写图跟不上（发热、存储慢）：这一帧不写图，只记参数，不拖慢预览
        let writeImage = inFlight < 4
        if writeImage { inFlight += 1 } else { skippedImages += 1 }
        lock.unlock()

        var line = info
        line["i"] = i
        line["t"] = CACurrentMediaTime() - start
        line["depthAge"] = depthAge
        let imgName = String(format: "img_%04d.jpg", i)
        line["img"] = writeImage ? imgName as Any : NSNull()
        if let rawDepth {
            let rawName = String(format: "depth_raw_%04d.pfm", i)
            line["depthRaw"] = rawName
            line["depthType"] = Self.fourCC(rawDepth.depthDataType)
            line["depthAccuracy"] = rawDepth.depthDataAccuracy == .relative ? "relative" : "absolute"
            line["depthFiltered"] = rawDepth.isDepthDataFiltered
            line["depthQuality"] = rawDepth.depthDataQuality == .high ? "high" : "low"
            lock.lock()
            if calibration == nil, let c = rawDepth.cameraCalibrationData { calibration = Self.describe(c) }
            lock.unlock()
            writer.async { Self.writePFM(Self.rawDisparity(rawDepth), to: self.folder.appendingPathComponent(rawName)) }
        }
        // 这一帧交给分析的新深度（硬件深度换算后的，或者 0.5× 的 AI 深度）；沿用旧深度的帧记上一张的文件名
        if let pipelineDepth {
            let name = String(format: "depth_%04d.pfm", i)
            lock.lock(); lastDepthFile = name as NSString; lock.unlock()
            writer.async { Self.writePFM(pipelineDepth, to: self.folder.appendingPathComponent(name)) }
        }
        lock.lock()
        line["depth"] = lastDepthFile
        lock.unlock()
        // 分割结果：变了才写
        if let masks { line.merge(saveMasks(masks, frame: i)) { _, new in new } }
        if writeImage {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            writer.async {
                Self.writeJPEG(image, ci: self.ci, to: self.folder.appendingPathComponent(imgName))
                self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: Self.sanitized(line), options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            lock.lock(); lines.append(s); lock.unlock()
        }
    }

    private func saveMasks(_ m: PersonSegmenter.Masks, frame i: Int) -> [String: Any] {
        lock.lock()
        let last = lastMaskRevision
        lastMaskRevision = (m.personRevision, m.personInstanceRevision, m.objectRevision)
        lock.unlock()
        func save(_ map: FloatMap?, _ colors: PlanarImage?, _ prefix: String) -> String? {
            guard let map else { return nil }
            let name = String(format: "%@_%04d", prefix, i)
            writer.async {
                Self.writePFM(map, to: self.folder.appendingPathComponent(name + ".pfm"))
                if let colors { Self.writePPM(colors, to: self.folder.appendingPathComponent(name + "_img.ppm")) }
            }
            return name
        }
        func orNull(_ s: String?) -> Any { if let s { return s } else { return NSNull() } }
        lock.lock()
        if m.personRevision != last.person { maskFiles["person"] = orNull(save(m.person, m.personColors, "person")) }
        if m.personInstanceRevision != last.people {
            maskFiles["people"] = orNull(save(m.personInstances, m.personInstanceColors, "people"))
        }
        if m.objectRevision != last.objects { maskFiles["objects"] = orNull(save(m.objects, m.objectColors, "objects")) }
        let files = maskFiles
        lock.unlock()
        return ["masks": files]
    }

    /// 写完所有文件、frames.jsonl 和 recording.json，再打成 zip（AirDrop 用）。完成后在主线程回调 zip 的位置
    func finish(meta: [String: Any], completion: @escaping @Sendable (URL?) -> Void) {
        writer.async {
            self.lock.lock()
            let lines = self.lines
            var meta = meta
            meta["frames"] = self.frameIndex
            meta["skippedImages"] = self.skippedImages
            meta["events"] = self.events
            if let c = self.calibration { meta["calibration"] = c } else { meta["calibration"] = NSNull() }
            self.lock.unlock()
            try? (lines.joined(separator: "\n") + "\n").write(to: self.folder.appendingPathComponent("frames.jsonl"),
                                                              atomically: true, encoding: .utf8)
            if let data = try? JSONSerialization.data(withJSONObject: Self.sanitized(meta),
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.folder.appendingPathComponent("recording.json"))
            }
            let zip = Self.zip(self.folder)
            DispatchQueue.main.async { completion(zip) }
        }
    }

    // MARK: - 写文件

    /// 系统给的深度原样转成 32 位视差（不做任何补洞、平移；深度格式 1/米 换算）
    static func rawDisparity(_ depth: AVDepthData) -> FloatMap {
        let d = depth.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = d.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), bpr = CVPixelBufferGetBytesPerRow(map)
        var values = [Float](repeating: .nan, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(map) {
            for y in 0..<h {
                let row = (base + y * bpr).assumingMemoryBound(to: Float32.self)
                for x in 0..<w { values[y * w + x] = row[x] }
            }
        }
        return FloatMap(width: w, height: h, values: values)
    }

    static func writePFM(_ m: FloatMap, to url: URL) {
        var data = Data("Pf\n\(m.width) \(m.height)\n-1.0\n".utf8)
        data.reserveCapacity(data.count + m.width * m.height * 4)
        for y in stride(from: m.height - 1, through: 0, by: -1) {
            for x in 0..<m.width {
                var bits = m.values[y * m.width + x].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        try? data.write(to: url)
    }

    /// 线性光的小图 → 8 位 sRGB 的 PPM
    static func writePPM(_ img: PlanarImage, to url: URL) {
        var data = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
        func enc(_ l: Float) -> UInt8 {
            let v = min(max(l, 0), 1)
            let s = v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055
            return UInt8(min(255, max(0, (s * 255).rounded())))
        }
        for i in 0..<(img.width * img.height) {
            data.append(enc(img.r[i])); data.append(enc(img.g[i])); data.append(enc(img.b[i]))
        }
        try? data.write(to: url)
    }

    static func writeJPEG(_ image: CIImage, ci: CIContext, to url: URL) {
        var img = image
        let long = max(image.extent.width, image.extent.height)
        if long > 1920 {
            let s = 1920 / long
            img = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let data = ci.jpegRepresentation(of: img, colorSpace: space, options: [key: 0.92]) {
            try? data.write(to: url)
        }
    }

    /// 整个文件夹打成 zip（系统自带的打包：NSFileCoordinator .forUploading），放在文件夹旁边
    static func zip(_ folder: URL) -> URL? {
        let target = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &error) { tmp in
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: tmp, to: target)) != nil { result = target }
        }
        return result
    }

    // MARK: - 元数据

    static func describe(_ c: AVCameraCalibrationData) -> [String: Any] {
        let k = c.intrinsicMatrix, e = c.extrinsicMatrix
        return [
            "intrinsic": [[k.columns.0.x, k.columns.1.x, k.columns.2.x],
                          [k.columns.0.y, k.columns.1.y, k.columns.2.y],
                          [k.columns.0.z, k.columns.1.z, k.columns.2.z]].map { $0.map(Double.init) },
            "intrinsicReferenceDimensions": [Double(c.intrinsicMatrixReferenceDimensions.width),
                                             Double(c.intrinsicMatrixReferenceDimensions.height)],
            "extrinsic": [e.columns.0, e.columns.1, e.columns.2, e.columns.3].map { [Double($0.x), Double($0.y), Double($0.z)] },
            "pixelSizeMM": Double(c.pixelSize),
            "lensDistortionCenter": [Double(c.lensDistortionCenter.x), Double(c.lensDistortionCenter.y)],
        ]
    }

    static func fourCC(_ t: OSType) -> String {
        switch t {
        case kCVPixelFormatType_DisparityFloat16: return "disparity16"
        case kCVPixelFormatType_DisparityFloat32: return "disparity32"
        case kCVPixelFormatType_DepthFloat16: return "depth16"
        case kCVPixelFormatType_DepthFloat32: return "depth32"
        default: return String(t)
        }
    }

    /// JSON 不能存 NaN / 无穷：换成 null
    static func sanitized(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues { sanitized($0) }
        case let a as [Any]: return a.map { sanitized($0) }
        case let f as Float: return f.isFinite ? Double(f) as Any : NSNull()
        case let f as Double: return f.isFinite ? f as Any : NSNull()
        case let f as CGFloat: return f.isFinite ? Double(f) as Any : NSNull()
        default: return v
        }
    }
}
#endif
