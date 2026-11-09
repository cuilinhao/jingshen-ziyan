#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import UIKit
import BokehCore

/// 拍照调试包：每拍一张，把交给编辑器的输入原样存下来，打成 zip（相机界面右上角「发送数据」AirDrop 到 Mac），
/// 在电脑上用 BokehCore 的 CPU 参考实现原样重放编辑器（GPU 版和它逐像素一致，见 MetalParityTests），
/// 对比高光提亮开 / 关、不同门限，查成片里过曝是相机给的照片本来就这样，还是渲染加出来的。
///
/// 在 Documents/DebugRecordings/photo-日期-时间/ 里（都是传感器方向，和编辑器里的 CapturedDepthPhoto 一样）：
///  - original.heic：相机给的原始照片文件（AVCapturePhoto.fileDataRepresentation，EXIF / MakerApple、HDR 增益图都在里面）
///  - image.png：交给编辑器的图（已按倍率裁切、长边缩到 photoLongSide，8 位 sRGB）
///  - disparity.pfm：交给编辑器的视差；person.pfm / people.pfm / objects.pfm：人像遮罩、人像实例、物体分割（有才写）；
///    faces.pfm：眼镜带（FaceBand，有人脸才写）
///  - gainmap.pfm：对齐、裁好的 HDR 增益图；highlightExclusion.pfm：按它算出来的「不做焦外高光提亮」的亮区（有才写）
///  - photo.json：机型、系统、拍照那一刻的相机状态（格式、色彩空间、曝光模式 / ISO / 快门 / 曝光偏差、测光点）、
///    对焦点 / ƒ / 焦段 / 裁切、编辑器参数、照片元数据（EXIF、MakerApple）、照片里带哪些辅助图、图像亮度统计
enum PhotoDebugDump {

    /// 写调试包并打成 zip。返回 zip 的位置；写不了返回 nil。在后台队列上调用（整张照片的统计要几十毫秒）
    static func save(photo: CapturedDepthPhoto, fileData: Data?, metadata: [String: Any],
                     info: [String: Any], gainMap: FloatMap? = nil) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let folder = DebugRecorder.root.appendingPathComponent("photo-" + f.string(from: Date()), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        if let fileData { try? fileData.write(to: folder.appendingPathComponent("original.heic")) }
        if let cg = ImageBridge.cgImage(from: photo.image) {
            writePNG(cg, to: folder.appendingPathComponent("image.png"))
        }
        DebugRecorder.writePFM(photo.disparity, to: folder.appendingPathComponent("disparity.pfm"))
        if let m = photo.personMask { DebugRecorder.writePFM(m, to: folder.appendingPathComponent("person.pfm")) }
        if let m = photo.personInstances { DebugRecorder.writePFM(m, to: folder.appendingPathComponent("people.pfm")) }
        if let m = photo.objectLabels { DebugRecorder.writePFM(m, to: folder.appendingPathComponent("objects.pfm")) }
        if let m = photo.faceBand { DebugRecorder.writePFM(m, to: folder.appendingPathComponent("faces.pfm")) }
        // 对齐、裁好的 HDR 增益图，和按它算出来的「不做焦外高光提亮」的亮区（HDRHighlights）
        if let g = gainMap { DebugRecorder.writePFM(g, to: folder.appendingPathComponent("gainmap.pfm")) }
        if let m = photo.highlightExclusion {
            DebugRecorder.writePFM(m, to: folder.appendingPathComponent("highlightExclusion.pfm"))
        }

        var meta = info
        meta["image"] = ["width": photo.image.width, "height": photo.image.height]
        meta["disparitySize"] = ["width": photo.disparity.width, "height": photo.disparity.height]
        meta["stats"] = stats(photo.image)
        meta["auxiliaryImages"] = auxiliaryTypes(fileData)
        if let g = gainMap { meta["gainMapSize"] = [g.width, g.height] }
        meta["photoMetadata"] = jsonSafe(metadata)
        let safe = jsonSafe(meta)
        if JSONSerialization.isValidJSONObject(safe),
           let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("photo.json"))
        } else {
            try? String(describing: meta).write(to: folder.appendingPathComponent("photo.txt"), atomically: true,
                                                encoding: .utf8)
        }
        if let s = meta["stats"] as? [String: Any] {
            print("[PhotoDebug] \(folder.lastPathComponent) 最亮通道占比 \(s["maxChannelAtLeast"] ?? "") · 相机 \(info["camera"] ?? "")")
        }
        return DebugRecorder.zip(folder)
    }

    /// 机型（iPhone17,1 = 16 Pro、iPhone17,2 = 16 Pro Max、iPhone18,x = 17 系列……）
    static func machineModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 拍照那一刻的相机状态（sessionQueue 上调用）
    static func cameraState(_ d: AVCaptureDevice) -> [String: Any] {
        let wb = d.deviceWhiteBalanceGains
        return [
            "type": d.deviceType.rawValue,
            "name": d.localizedName,
            "format": "\(d.activeFormat)",
            "colorSpace": d.activeColorSpace.rawValue,   // 0 sRGB、1 P3、2 HLG、3 AppleLog
            "videoZoomFactor": Double(d.videoZoomFactor),
            "videoHDR": d.isVideoHDREnabled,
            "exposureMode": d.exposureMode.rawValue,      // 0 locked、1 autoExpose、2 continuous、3 custom
            "exposurePointOfInterest": [Double(d.exposurePointOfInterest.x), Double(d.exposurePointOfInterest.y)],
            "iso": Double(d.iso),
            "exposureDurationSeconds": CMTimeGetSeconds(d.exposureDuration),
            "exposureTargetOffset": Double(d.exposureTargetOffset),
            "exposureTargetBias": Double(d.exposureTargetBias),
            "focusMode": d.focusMode.rawValue,
            "lensPosition": Double(d.lensPosition),
            "whiteBalanceGains": [Double(wb.redGain), Double(wb.greenGain), Double(wb.blueGain)],
        ]
    }

    /// 线性光图像的亮度统计：最亮通道超过各个门限的像素占比（高光提亮看的就是最亮通道）
    static func stats(_ img: PlanarImage) -> [String: Any] {
        let levels: [Float] = [0.5, 0.75, 0.85, 0.9, 0.95, 0.98, 0.995]
        var counts = [Int](repeating: 0, count: levels.count)
        var sum: Double = 0
        let n = img.pixelCount
        for i in 0..<n {
            let m = max(img.r[i], max(img.g[i], img.b[i]))
            sum += Double(m)
            for (k, l) in levels.enumerated() where m >= l { counts[k] += 1 }
        }
        var share: [String: Double] = [:]
        for (k, l) in levels.enumerated() {
            share[String(format: "%.3f", l)] = n > 0 ? (Double(counts[k]) / Double(n) * 1e5).rounded() / 1e5 : 0
        }
        return ["maxChannelAtLeast": share, "meanMaxChannel": n > 0 ? sum / Double(n) : 0]
    }

    /// 照片文件里带了哪些辅助图（HDR 增益图、深度、人像遮罩……）
    static func auxiliaryTypes(_ data: Data?) -> [String] {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        var types: [(String, CFString)] = [("hdrGainMap", kCGImageAuxiliaryDataTypeHDRGainMap),
                                           ("disparity", kCGImageAuxiliaryDataTypeDisparity),
                                           ("depth", kCGImageAuxiliaryDataTypeDepth),
                                           ("portraitMatte", kCGImageAuxiliaryDataTypePortraitEffectsMatte)]
        if #available(iOS 18.0, *) { types.append(("isoGainMap", kCGImageAuxiliaryDataTypeISOGainMap)) }
        return types.compactMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0.1) != nil ? $0.0 : nil }
    }

    static func writePNG(_ cg: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// 照片元数据里有 Data、非字符串键这些 JSON 存不了的东西：转成 JSON 能存的（存不了的写成文字描述）
    static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.doubleValue.isFinite ? (n as Any) : (NSNull() as Any)
        case let d as [String: Any]: return d.mapValues { jsonSafe($0) }
        case let d as NSDictionary:
            var out: [String: Any] = [:]
            for (k, value) in d { out["\(k)"] = jsonSafe(value) }
            return out
        case let a as [Any]: return a.map { jsonSafe($0) }
        case let data as Data: return "<\(data.count) 字节>"
        case is NSNull: return NSNull()
        default: return String(describing: v)
        }
    }
}
#endif
