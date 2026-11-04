#if os(iOS)
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UIKit
import Vision
import BokehCore

/// 相册里的一张图（别的 App 拍的、截图、下载的图都行）→ 可以调景深、点按换主体的 `CapturedDepthPhoto`，
/// 交给 `PhotoBokehEditor`，和拍完照以后编辑一模一样（点哪儿换主体的规则都在 `LiveFrameAnalyzer.stillPlan` 里）。
///
/// 1. 原始文件：调用方用 PhotosPicker 的 `.current` 编码按 Data 取（`.automatic` 可能把 HEIC 转成 JPEG，深度和增益图会丢）。
///    `.current` 是「带编辑的当前版本」：人像照片的虚化是相册里的一个编辑，已经画进像素里了（背景本来就糊，
///    点人也清晰不了，ƒ16 也还是糊的）。所以带深度的照片再用 `unadjustedOriginal` 取没编辑过的原图（清晰 + 深度），
///    和系统相册的景深编辑一样（要相册读取权限）；
/// 2. 按 EXIF 方向直接解成正向的图，长边缩到 `maxLongSide`（48MP 不整张解码）。之后画面、深度、分割、点按坐标都是
///    正向的（方向 `.up`），不用再管旋转和镜像；
/// 3. 深度：照片自带的深度优先（系统相机人像照、iPhone 15 以后拍到人或宠物时自动存的深度、部分第三方相机），
///    和画面宽高比对不上（照片被裁过）就不用；没有就用 AI 单目深度（Depth Anything V2，和 0.5× 超广角同一个模型），
///    按照片自己的宽高比送进去（`MonocularDepthEstimator.estimateStill`）；
/// 4. 增益图、三种分割、组装：和相机拍照同一段代码（`StillPhotoBuilder`）；
/// 5. 打开时先对焦在：最大的人脸 → 最大的人 → 最大的前景物体 → EXIF 里的主体区域 → 画面中心。
///
/// AI 深度是每张图归一化的相对值（最近 ≈ 1、最远 ≈ 0），不是米：风景照这种实际全在远处的画面也会被拉开，
/// 虚化量不是物理意义上的；也不按 EXIF 焦距放大虚化（长焦图在归一化深度上会整张糊掉）。
public enum PhotoLibraryImporter {
    public enum ImportError: LocalizedError {
        case unreadable
        case depthModelUnavailable(String)
        case depthEstimationFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "读不出这张图片"
            case .depthModelUnavailable(let why): return "AI 深度模型没准备好：\(why)"
            case .depthEstimationFailed: return "AI 深度估计失败"
            }
        }
    }

    /// 编辑器里显示的深度来源
    public static let embeddedDepthLabel = "照片自带深度"
    public static let aiDepthLabel = "AI 深度"

    private static let queue = DispatchQueue(label: "depthbokeh.import", qos: .userInitiated)

    /// 解码、深度、分割都在后台做（几百毫秒到一两秒；第一次用 AI 深度还要等模型下载 / 编译）。
    /// - Parameters:
    ///   - data: 照片的原始文件
    ///   - fNumber: 打开时的光圈
    ///   - maxLongSide: 编辑分辨率（长边），和拍照一样默认 3024
    ///   - segmentation: 分割开关（关掉只按深度虚化）
    ///   - onStatus: 进度文字（任意线程）
    public static func makePhoto(from data: Data, fNumber: Float = 4.5, maxLongSide: Int = 3024,
                                 segmentation: Bool = true,
                                 onStatus: @escaping @Sendable (String) -> Void = { _ in }) async throws
        -> CapturedDepthPhoto {
        onStatus("读取照片…")
        let prepared = try await onQueue { try prepare(data, maxLongSide: maxLongSide) }
        let estimator: MonocularDepthEstimator?
        if prepared.embeddedDepth == nil {
            estimator = try await waitForDepthModel(onStatus: onStatus)
        } else {
            estimator = nil
        }
        onStatus(prepared.embeddedDepth != nil ? "分割主体…" : "AI 估计深度…")
        return try await onQueue {
            try finish(prepared, estimator: estimator, fNumber: fNumber, segmentation: segmentation,
                       onStatus: onStatus)
        }
    }

    // MARK: - 原图

    /// 照片文件里有没有自带的深度（视差 / 深度辅助图）。有的话 PhotosPicker 给的版本可能已经带着系统的人像虚化
    public static func hasEmbeddedDepth(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil
        }
    }

    /// 相册里这张是不是人像照片（系统的人像虚化是一个编辑）。只在已经有相册读取权限时查，不弹窗；没权限返回 false
    public static func isPortraitAsset(localIdentifier: String) -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return false }
        return asset.mediaSubtypes.contains(.photoDepthEffect)
    }

    /// 相册里这张照片没有编辑过的原图文件（人像照片：清晰的原图 + 深度，系统的人像虚化不在里面）。
    /// 要相册读取权限（第一次会弹窗）；没权限、照片不在「有限访问」选中的范围里、或者取不到时返回 nil
    public static func unadjustedOriginal(localIdentifier: String) async -> Data? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            print("[Import] 没有相册读取权限（\(status.rawValue)），用 PhotosPicker 给的当前版本")
            return nil
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            print("[Import] 相册里找不到这张照片（有限访问没选它？），用 PhotosPicker 给的当前版本")
            return nil
        }
        let options = PHImageRequestOptions()
        options.version = .unadjusted          // 去掉所有编辑（人像虚化、滤镜、裁剪）的原图
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true   // iCloud 里只存了缩略图时下载原图
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                print("[Import] 原图 \(data.map { "\($0.count / 1024) KB" } ?? "取不到")，\(uti ?? "?")")
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - 步骤

    private struct Prepared {
        let data: Data
        /// 正向的画面（长边 ≤ maxLongSide）
        let cgImage: CGImage
        let image: PlanarImage
        /// 照片自带的深度（已转正）和它是不是相对值
        let embeddedDepth: (disparity: FloatMap, relative: Bool)?
        let focalLength35mm: Float?
        /// EXIF 主体区域的中心（正向画面的归一化坐标）
        let subjectArea: CGPoint?
        let startedAt: Date
    }

    private static func prepare(_ data: Data, maxLongSide: Int) throws -> Prepared {
        let t0 = Date()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { throw ImportError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientationRaw = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        guard let decoded = decodeUpright(source, props: props, maxLongSide: maxLongSide) else {
            throw ImportError.unreadable
        }
        let cg = flattenedIfTransparent(decoded)
        let image = ImageBridge.planarImage(from: cg, maxLongSide: maxLongSide)
        let uprightAspect = Double(cg.width) / Double(max(1, cg.height))
        let depth = embeddedDepth(source, orientation: orientation, uprightAspect: uprightAspect)

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let focal = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.floatValue
        let pw = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let ph = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        var subject: CGPoint?
        if let area = exif?[kCGImagePropertyExifSubjectArea as String] as? [NSNumber], area.count >= 2, pw > 0, ph > 0 {
            // EXIF 坐标是存储方向的像素坐标
            let raw = CGPoint(x: area[0].doubleValue / Double(pw), y: area[1].doubleValue / Double(ph))
            if (0...1).contains(raw.x), (0...1).contains(raw.y) { subject = uprightPoint(raw, orientation: orientation) }
        }
        var depthText = "没有自带深度"
        if let depth {
            depthText = "自带深度 \(depth.disparity.width)×\(depth.disparity.height)" + (depth.relative ? "（相对）" : "")
        }
        let focalText = focal.map { String(format: "%.0fmm", $0) } ?? "未知"
        let ms = Int(-t0.timeIntervalSinceNow * 1000)
        print("[Import] 原图 \(pw)×\(ph) 方向 \(orientationRaw) → \(cg.width)×\(cg.height)，\(depthText)，焦距 \(focalText)，"
              + "用时 \(ms)ms")
        return Prepared(data: data, cgImage: cg, image: image, embeddedDepth: depth,
                        focalLength35mm: focal.flatMap { $0 > 0 ? $0 : nil }, subjectArea: subject, startedAt: t0)
    }

    private static func finish(_ p: Prepared, estimator: MonocularDepthEstimator?, fNumber: Float,
                               segmentation: Bool, onStatus: @Sendable (String) -> Void) throws -> CapturedDepthPhoto {
        var steps: [String] = []
        var stepStart = Date()
        func mark(_ name: String) {
            steps.append(String(format: "%@ %.0fms", name, -stepStart.timeIntervalSinceNow * 1000))
            stepStart = Date()
        }
        let disparity: FloatMap
        let relative: Bool
        let label: String
        // 照片自带深度时才按 EXIF 焦距放大虚化（和相机拍照一致）；AI 深度是归一化的，不放大
        let focal: Float?
        if let embedded = p.embeddedDepth {
            disparity = embedded.disparity
            relative = embedded.relative
            label = embeddedDepthLabel
            focal = p.focalLength35mm
        } else {
            guard let estimator, let mono = estimator.estimateStill(cgImage: p.cgImage, orientation: .up) else {
                throw ImportError.depthEstimationFailed
            }
            disparity = mono
            relative = true
            label = aiDepthLabel
            focal = nil
            mark("AI 深度")
            onStatus("分割主体…")
        }
        let built = StillPhotoBuilder.build(.init(cgImage: p.cgImage, image: p.image, orientation: .up,
                                                  displayOrientation: .up, disparity: disparity,
                                                  isRelativeDepth: relative, fileData: p.data, gainCrop: 1,
                                                  focusPoint: CGPoint(x: 0.5, y: 0.5), fNumber: fNumber,
                                                  focalLength35mm: focal, lockedFocusDisparity: nil,
                                                  segmentation: segmentation, depthSourceLabel: label),
                                            mark: mark)
        var photo = built.photo
        photo.focusPoint = initialFocus(cgImage: p.cgImage, personInstances: photo.personInstances,
                                        objects: photo.objectLabels, subjectArea: p.subjectArea)
        mark("初始对焦点")
        let focusText = String(format: "(%.2f, %.2f)", Double(photo.focusPoint.x), Double(photo.focusPoint.y))
        let total = Int(-p.startedAt.timeIntervalSinceNow * 1000)
        print("[Import] \(label) · \(steps.joined(separator: " · "))，对焦 \(focusText)，共 \(total)ms")
        return photo
    }

    // MARK: - 解码

    /// 按 EXIF 方向转正、长边不超过 maxLongSide 的 CGImage（ImageIO 直接解到这个大小，不先整张解码）
    static func decodeUpright(_ source: CGImageSource, props: [String: Any], maxLongSide: Int) -> CGImage? {
        let pw = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let ph = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let long = max(pw, ph)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // 不用文件里嵌的小缩略图
            kCGImageSourceCreateThumbnailWithTransform: true,     // 按 EXIF 方向转正（含镜像）
            kCGImageSourceThumbnailMaxPixelSize: long > 0 ? min(maxLongSide, long) : maxLongSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 带透明通道的图（PNG 贴纸、截图）铺在白底上：透明的地方直接画进 RGB 会变成黑色
    static func flattenedIfTransparent(_ cg: CGImage) -> CGImage {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return cg
        default: break
        }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage() ?? cg
    }

    /// 照片文件自带的深度（视差优先，其次深度），按 EXIF 方向转正后转成视差图（1/米；双摄是相对值）。
    /// 和画面的宽高比对不上（照片在相册里被裁过）、或者几乎没有有效像素时不用
    static func embeddedDepth(_ source: CGImageSource, orientation: CGImagePropertyOrientation,
                              uprightAspect: Double) -> (disparity: FloatMap, relative: Bool)? {
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { continue }
            if orientation != .up { depth = depth.applyingExifOrientation(orientation) }
            let map = ImageBridge.disparityMap(from: depth)
            let aspect = Double(map.width) / Double(max(1, map.height))
            guard abs(log(aspect / uprightAspect)) < 0.03 else {
                print("[Import] 自带深度 \(map.width)×\(map.height) 和画面比例对不上（照片被裁过？），改用 AI 深度")
                return nil
            }
            let valid = map.values.reduce(0) { $1.isFinite ? $0 + 1 : $0 }
            guard valid * 4 >= map.values.count else {
                print("[Import] 自带深度有效像素只有 \(valid * 100 / max(1, map.values.count))%，改用 AI 深度")
                return nil
            }
            return (map, depth.depthDataAccuracy == .relative)
        }
        return nil
    }

    /// 存储方向的归一化坐标 → 按 EXIF 方向转正以后的归一化坐标
    static func uprightPoint(_ p: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        let u = p.x, v = p.y
        switch orientation {
        case .up: return CGPoint(x: u, y: v)
        case .upMirrored: return CGPoint(x: 1 - u, y: v)
        case .down: return CGPoint(x: 1 - u, y: 1 - v)
        case .downMirrored: return CGPoint(x: u, y: 1 - v)
        case .leftMirrored: return CGPoint(x: v, y: u)
        case .right: return CGPoint(x: 1 - v, y: u)
        case .rightMirrored: return CGPoint(x: 1 - v, y: 1 - u)
        case .left: return CGPoint(x: v, y: 1 - u)
        @unknown default: return p
        }
    }

    // MARK: - 打开时的对焦点

    /// 正向画面的归一化坐标：最大的人脸 → 最大的人 → 最大的前景物体 → EXIF 主体区域 → 画面中心
    static func initialFocus(cgImage: CGImage, personInstances: FloatMap?, objects: FloatMap?,
                             subjectArea: CGPoint?) -> CGPoint {
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        if (try? handler.perform([faces])) != nil,
           let face = faces.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }),
           area(face.boundingBox) > 0.0004 {
            // Vision 的坐标原点在左下角
            return CGPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY)
        }
        if let personInstances, let p = largestInstancePoint(personInstances) { return p }
        if let objects, let p = largestInstancePoint(objects) { return p }
        return subjectArea ?? CGPoint(x: 0.5, y: 0.5)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// 标签图里像素最多的那个实例上、离它重心最近的像素（重心可能落在实例外面：弯着的手臂、甜甜圈）。
    /// 最大的实例不到画面的 0.25% 就当没有
    static func largestInstancePoint(_ labels: FloatMap) -> CGPoint? {
        let w = labels.width, h = labels.height
        guard w > 0, h > 0 else { return nil }
        var count: [Int: Int] = [:]
        var sumX: [Int: Double] = [:], sumY: [Int: Double] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let l = Int(labels.values[y * w + x].rounded())
                guard l > 0 else { continue }
                count[l, default: 0] += 1
                sumX[l, default: 0] += Double(x)
                sumY[l, default: 0] += Double(y)
            }
        }
        guard let best = count.max(by: { $0.value < $1.value }), best.value * 400 >= w * h else { return nil }
        let cx = sumX[best.key, default: 0] / Double(best.value)
        let cy = sumY[best.key, default: 0] / Double(best.value)
        var bestD = Double.infinity, bx = 0, by = 0
        for y in 0..<h {
            for x in 0..<w where Int(labels.values[y * w + x].rounded()) == best.key {
                let d = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                if d < bestD { bestD = d; bx = x; by = y }
            }
        }
        return CGPoint(x: (Double(bx) + 0.5) / Double(w), y: (Double(by) + 0.5) / Double(h))
    }

    // MARK: - AI 深度模型

    /// 等 AI 深度模型准备好：没下载过要先下载约 50 MB 并在手机上编译；每次装 App 后第一次加载也要编译一会儿
    private static func waitForDepthModel(onStatus: @escaping @Sendable (String) -> Void) async throws
        -> MonocularDepthEstimator {
        let store = DepthModelStore.shared
        if let ready = store.estimator { return ready }
        store.prepare()
        var last = ""
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            if let ready = store.estimator { return ready }
            let text: String
            switch store.status {
            case .downloading(let progress):
                text = String(format: "下载 AI 深度模型（约 50 MB）%.0f%%", progress * 100)
            case .idle, .compiling, .ready:
                text = "加载 AI 深度模型…（装好 App 后第一次要几十秒）"
            case .failed(let why):
                throw ImportError.depthModelUnavailable(why)
            }
            if text != last {
                onStatus(text)
                last = text
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ImportError.depthModelUnavailable("等了 15 分钟还没好")
    }

    // MARK: - 后台队列

    private static func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
#endif
