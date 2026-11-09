import Foundation

/// 眼镜带：人脸框里眼睛高度的那一条，往脸前、脸后各伸出去一截。伸出脸外的眼镜框、镜片都在这里面。
///
/// 为什么要它（录屏 yanjing-queshao、调试录制 rec-20261109-152800）：侧脸时远处那片镜片伸出脸的轮廓，
///  - LiDAR 穿过透明镜片，测到的是后面的墙；
///  - Vision 的人像遮罩在 0.5 那条线上把它切在外面，镜片只在遮罩的软边里（0.1～0.5）；人像实例、前景物体也都没包住它。
/// 深度和分割都说「是背景」，镜片就按背景虚化掉了。可是软边是整个人都有的，到处按 0.1 算人，头顶、肩膀外面会多出一圈清晰的背景（光晕）。
/// 所以只在眼睛那一条里把软边算成人（SubjectMatte.withAccessories）：眼镜在那儿，别处照旧按 0.5。
///
/// 坐标：正立画面（交给 Vision 的方向）、左上角为原点的归一化坐标；iOS 那边再转回传感器方向（和人像遮罩同一条路）。
public enum FaceBand {

    /// 一张脸（Vision 的人脸框，已转成左上角为原点）
    public struct Face: Equatable {
        public var x: Float, y: Float, width: Float, height: Float
        /// 歪头的角度（弧度，Vision 的 roll）。两个方向都按它转一遍取并集，不依赖正负号的约定
        public var roll: Float

        public init(x: Float, y: Float, width: Float, height: Float, roll: Float = 0) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.roll = roll
        }
    }

    /// 竖直方向：从脸框高度的 top 到 bottom（0 = 脸框顶，1 = 脸框底）。眉毛到颧骨，眼镜框上下都在里面
    public static let top: Float = 0.15
    public static let bottom: Float = 0.65
    /// 水平方向：脸框左右各往外伸出脸框宽度的这么多（侧脸时远处的镜片在脸框前沿外面一点）
    public static let side: Float = 0.3

    /// 画成 width×height 的 0/1 图（正立方向）；没有脸返回 nil
    public static func map(_ faces: [Face], width w: Int, height h: Int) -> FloatMap? {
        guard !faces.isEmpty, w > 0, h > 0 else { return nil }
        var v = [Float](repeating: 0, count: w * h)
        var any = false
        for f in faces where f.width > 0 && f.height > 0 {
            // 眼镜带（脸框坐标系里的矩形），按 ±roll 绕脸框中心转，取外接矩形的并集
            let cx = f.x + f.width / 2, cy = f.y + f.height / 2
            let bx0 = f.x - side * f.width, bx1 = f.x + f.width * (1 + side)
            let by0 = f.y + top * f.height, by1 = f.y + bottom * f.height
            var x0 = Float.infinity, x1 = -Float.infinity, y0 = Float.infinity, y1 = -Float.infinity
            for a in Set([f.roll, -f.roll]) {
                let c = cosf(a), s = sinf(a)
                for (px, py) in [(bx0, by0), (bx1, by0), (bx0, by1), (bx1, by1)] {
                    // 归一化坐标的宽高比不是 1：转之前换成按高度算的单位
                    let dx = (px - cx) * Float(w) / Float(h), dy = py - cy
                    let rx = (c * dx - s * dy) * Float(h) / Float(w) + cx, ry = s * dx + c * dy + cy
                    x0 = min(x0, rx); x1 = max(x1, rx); y0 = min(y0, ry); y1 = max(y1, ry)
                }
            }
            let ix0 = max(0, Int((x0 * Float(w)).rounded(.down))), ix1 = min(w - 1, Int((x1 * Float(w)).rounded(.up)))
            let iy0 = max(0, Int((y0 * Float(h)).rounded(.down))), iy1 = min(h - 1, Int((y1 * Float(h)).rounded(.up)))
            guard ix0 <= ix1, iy0 <= iy1 else { continue }
            for y in iy0...iy1 { for x in ix0...ix1 { v[y * w + x] = 1 } }
            any = true
        }
        return any ? FloatMap(width: w, height: h, values: v) : nil
    }
}
