#if os(iOS)
import AVFoundation
import CoreGraphics
import UIKit
import BokehCore

/// 系统类型（CVPixelBuffer / AVDepthData / CGImage / UIImage）和 BokehCore 纯 Swift 类型之间的转换
public enum ImageBridge {

    /// BGRA 相机帧 -> 线性光图像，按整数倍降采样到大约 targetWidth 宽
    public static func planarImage(from pixelBuffer: CVPixelBuffer, targetWidth: Int) -> PlanarImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let factor = max(1, w / max(1, targetWidth))
        return PlanarImage(interleaved8: UnsafeRawPointer(base), width: w, height: h,
                           bytesPerRow: bpr, layout: .bgra, downsample: factor, maxSamplesPerAxis: 2)
    }

    /// 相机帧 -> 线性光图像，缩放到长边为 longSide（任意比例）。支持 BGRA。
    /// crop > 1 时只取中间 1/crop（数码变焦），输出不超过裁出来那块的原始像素数（不做放大）
    public static func planarImage(from pixelBuffer: CVPixelBuffer, longSide: Int, crop: CGFloat = 1) -> PlanarImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        return PlanarImage.cameraFrame(interleaved8: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: bpr,
                                       layout: .bgra, longSide: longSide, crop: Float(crop))
    }

    /// 相机帧中间的 1/crop 缩放到 width×height（小图：给 CPU 上的分析按颜色补主体边缘、判断画面在不在动）。
    /// 每个输出像素在它覆盖的区域里取 2×2 个样本
    public static func planarImage(from pixelBuffer: CVPixelBuffer, width: Int, height: Int, crop: CGFloat) -> PlanarImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let c = crop.isFinite ? max(1, Double(crop)) : 1
        let cw = Double(w) / c, ch = Double(h) / c
        return PlanarImage(interleaved8: UnsafeRawPointer(base), width: w, height: h, bytesPerRow: bpr, layout: .bgra,
                           outputWidth: max(1, width), outputHeight: max(1, height),
                           sourceRect: (Float((Double(w) - cw) / 2), Float((Double(h) - ch) / 2), Float(cw), Float(ch)))
    }

    /// 图像中间的 1/crop（传感器方向，任何旋转下都居中）
    public static func centerCrop(_ image: CGImage, by crop: CGFloat) -> CGImage {
        guard crop.isFinite, crop > 1.001 else { return image }
        let width = (CGFloat(image.width) / crop).rounded()
        let height = (CGFloat(image.height) / crop).rounded()
        let rect = CGRect(x: ((CGFloat(image.width) - width) / 2).rounded(),
                          y: ((CGFloat(image.height) - height) / 2).rounded(), width: width, height: height)
        return image.cropping(to: rect) ?? image
    }

    /// AVDepthData -> 视差图（单位 1/米）。无效值写成 NaN，后面由 DepthRefiner 补洞。
    /// 双摄的视差精度是「相对」的（depthDataAccuracy = .relative），可能带偏移、出现 ≤ 0 的值：
    /// 这时保留所有有限值，整体平移到最小值约 0.02（相对距离由 LensParameters.relativeScale 保护）
    public static func disparityMap(from depthData: AVDepthData) -> FloatMap {
        var map = absoluteOrRawDisparity(from: depthData)
        if depthData.depthDataAccuracy == .relative, let p = map.percentiles(0.02, 0.98), p.low < 0.02 {
            let shift = 0.02 - p.low
            for i in 0..<map.values.count where map.values[i].isFinite {
                map.values[i] = max(map.values[i] + shift, 0.005)
            }
        }
        return map
    }

    private static func absoluteOrRawDisparity(from depthData: AVDepthData) -> FloatMap {
        let relative = depthData.depthDataAccuracy == .relative
        let converted = depthData.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = converted.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        let base = CVPixelBufferGetBaseAddress(map)!
        var values = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let v = row[x]
                if v.isFinite && (relative || v > 0) { values[y * w + x] = v }
            }
        }
        return FloatMap(width: w, height: h, values: values)
    }

    /// CGImage -> 线性光图像，长边缩到 maxLongSide 以内
    public static func planarImage(from cgImage: CGImage, maxLongSide: Int) -> PlanarImage {
        let scale = min(1, Double(maxLongSide) / Double(max(cgImage.width, cgImage.height)))
        let w = max(1, Int(Double(cgImage.width) * scale))
        let h = max(1, Int(Double(cgImage.height) * scale))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes.withUnsafeBytes { raw in
            PlanarImage(interleaved8: raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4, layout: .rgba)
        }
    }

    /// 线性光图像 -> CGImage（sRGB）
    public static func cgImage(from image: PlanarImage) -> CGImage? {
        let rgba = image.interleavedRGBA8()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    public static func uiImage(from image: PlanarImage, orientation: UIImage.Orientation) -> UIImage? {
        guard let cg = cgImage(from: image) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    public static func uiOrientation(_ o: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch o {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// 屏幕上显示的图片里的归一化坐标 (u, v) -> 原始（传感器方向）图像里的归一化坐标。
    /// 相机原始帧是横着的，竖屏显示时带了旋转，点按对焦要换算回去。
    public static func rawPoint(fromDisplayed p: CGPoint, orientation: UIImage.Orientation) -> CGPoint {
        let u = p.x, v = p.y
        switch orientation {
        case .right, .rightMirrored: return CGPoint(x: v, y: 1 - u)   // 显示 = 原图顺时针转 90°
        case .left, .leftMirrored: return CGPoint(x: 1 - v, y: u)     // 显示 = 原图逆时针转 90°
        case .down, .downMirrored: return CGPoint(x: 1 - u, y: 1 - v)
        default: return CGPoint(x: u, y: v)
        }
    }
}
#endif
