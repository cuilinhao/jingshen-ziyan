import Foundation

/// 单目模型的相对逆深度标尺。预览和照片必须用同一个标尺，才能复用锁定的对焦值。
public enum MonocularDepthNormalization {
    public struct Range: Equatable, Sendable {
        public var low: Float
        public var high: Float

        public init(low: Float, high: Float) {
            self.low = low
            self.high = high
        }
    }

    /// 不锁焦时按 2% / 98% 百分位归一化；视频用 previous 做原有的 0.25 平滑。
    /// 锁焦时 fixedRange 优先于 previous：原始逆深度到视差的映射保持不变。
    public static func normalize(_ raw: [Float], previous: Range? = nil, fixedRange: Range? = nil)
        -> (values: [Float], range: Range)? {
        var sample: [Float] = []
        sample.reserveCapacity(raw.count / 16 + 1)
        var i = 0
        while i < raw.count {
            let v = raw[i]
            if v.isFinite { sample.append(v) }
            i += 16
        }
        guard sample.count > 16 else { return nil }
        sample.sort()
        var low = sample[sample.count * 2 / 100]
        var high = sample[min(sample.count - 1, sample.count * 98 / 100)]
        if let fixedRange {
            low = fixedRange.low
            high = fixedRange.high
        } else if let previous {
            low = previous.low + (low - previous.low) * 0.25
            high = previous.high + (high - previous.high) * 0.25
        }
        let span = max(high - low, 1e-6)
        let values = raw.map { v in
            v.isFinite ? min(max((v - low) / span, 0), 1.5) + 0.02 : 0.02
        }
        return (values, Range(low: low, high: high))
    }
}
