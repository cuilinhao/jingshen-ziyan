#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import BokehCore

/// 一张静态照片（画面 + 已经拿到的视差图）→ 可以反复调景深的 `CapturedDepthPhoto`。
///
/// 相机拍照（`DepthCameraController` 的拍照回调）和相册导入（`PhotoLibraryImporter`）都走这里，
/// 「HDR 增益图 → 人像分割 → 眼镜带 → 人像实例 → 物体分割 → 组装」的规则只在这一处。
/// 深度从哪来（硬件深度、照片文件自带的深度、AI 单目深度）由调用方决定，这里不管。
enum StillPhotoBuilder {
    struct Input {
        /// 送给 Vision 的画面（已裁好）；像素方向由 `orientation` 描述
        var cgImage: CGImage
        /// 同一块画面转好的线性光图像（和 cgImage 同一个像素方向）
        var image: PlanarImage
        /// cgImage 的 EXIF 方向：Vision 按它把画面转正，结果再转回像素方向
        var orientation: CGImagePropertyOrientation
        /// 显示方向
        var displayOrientation: UIImage.Orientation
        /// 视差图（和 image 同方向、同一块画面，可以有 NaN 洞）；nil = 没有深度，整张图当作在对焦面上
        var disparity: FloatMap?
        /// 视差只有相对值（双摄 / AI 单目深度）
        var isRelativeDepth: Bool
        /// 原始照片文件（取 HDR 增益图）；nil = 没有
        var fileData: Data?
        /// 增益图要从中间裁掉的倍数（和画面一样的数码变焦裁切）；相册导入为 1
        var gainCrop: Float = 1
        /// 对焦点（image 的归一化坐标）
        var focusPoint: CGPoint
        var fNumber: Float
        /// 35mm 等效焦距；nil = 不按焦距放大虚化
        var focalLength35mm: Float?
        var lockedFocusDisparity: Float?
        /// 分割开关：关掉时不跑 Vision，只按深度虚化
        var segmentation: Bool
        /// 编辑器里显示的深度来源（「照片自带深度」「AI 深度」）；相机拍的为 nil
        var depthSourceLabel: String?
        /// Apple 拍照时给的眼镜遮罩（和 image 同方向、同一块画面）；没有为 nil
        var glassesMatte: FloatMap? = nil
    }

    struct Output {
        let photo: CapturedDepthPhoto
        /// 对齐好的 HDR 增益图（拍照调试包要用）；照片没带增益图时为 nil
        let alignedGain: FloatMap?
    }

    /// 耗时（增益图 + 三次 Vision，几百毫秒），在后台队列上调用。`mark`：每做完一步调一次（拍照计时日志用）
    static func build(_ input: Input, mark: (String) -> Void = { _ in }) -> Output {
        let image = input.image
        let cg = input.cgImage
        let o = input.orientation
        // HDR 增益图：照片里过曝、但不是光源的地方（被灯照亮的白色表面）不做焦外高光提亮（HDRHighlights）。
        // 16 Pro 超广角会把这些表面直接压到 255，只看照片分不出它和灯（录屏 0.5x-baoguang）
        var exclusion: FloatMap?
        var alignedGain: FloatMap?
        if let disparity = input.disparity, let fileData = input.fileData,
           let gain = ImageBridge.hdrGainMap(from: fileData) {
            let g = HDRHighlights.align(gain.centerCropped(by: input.gainCrop), to: image)
            alignedGain = g
            exclusion = HDRHighlights.nonLightMask(image: image, gainMap: g,
                                                   threshold: RenderQuality.photo.highlightThreshold,
                                                   width: disparity.width, height: disparity.height)
        }
        mark(alignedGain != nil ? "增益图" : "没有增益图")
        // 人像分割（高质量）：对焦在人身上时整个人保持清晰；物体分割：对焦的物体整个保持清晰。和预览一致。
        // 没有深度、或者分割开关关掉时不跑
        let segment = input.disparity != nil && input.segmentation
        let person = segment ? PersonSegmenter.photoMask(cg, orientation: o) : nil
        mark("人像分割")
        // 眼镜带：人脸框里眼睛那一条，伸出脸外的镜片在这里按人像遮罩的软边算人（FaceBand）。
        // 相机给了眼镜遮罩时编辑器用眼镜遮罩，眼镜带照样算（拍照调试包里对比用）
        let faceBand = person != nil ? PersonSegmenter.photoFaceBand(cg, orientation: o) : nil
        mark("人脸")
        // 人像实例：画面上和对焦的人挨着的别人（后面站着的同事）不跟着保持清晰
        let people = person != nil ? PersonSegmenter.photoPersonInstances(cg, orientation: o) : nil
        mark("人像实例")
        let objects = segment ? PersonSegmenter.photoObjects(cg, orientation: o) : nil
        mark("物体分割")
        var photo = CapturedDepthPhoto(image: image,
                                       disparity: input.disparity ?? FloatMap(width: 64, height: 48, repeating: 1),
                                       orientation: input.displayOrientation, focusPoint: input.focusPoint,
                                       fNumber: input.fNumber, isRelativeDepth: input.isRelativeDepth,
                                       personMask: person, objectLabels: objects, personInstances: people,
                                       focalLength35mm: input.focalLength35mm,
                                       lockedFocusDisparity: input.lockedFocusDisparity,
                                       highlightExclusion: exclusion)
        photo.depthSourceLabel = input.depthSourceLabel
        photo.faceBand = faceBand
        photo.glassesMatte = person != nil ? input.glassesMatte : nil
        return Output(photo: photo, alignedGain: alignedGain)
    }
}
#endif
