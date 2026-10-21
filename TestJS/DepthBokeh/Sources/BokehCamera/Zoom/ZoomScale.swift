// 从 DepthBokehCamera 2（commit 510c420「修改调节焦段 UI」）原样迁移，只加了 public
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ZoomStop: Identifiable, Equatable {
    public let factor: CGFloat
    public let focalLength: Int
    public var id: CGFloat { factor }
    public init(factor: CGFloat, focalLength: Int) {
        self.factor = factor
        self.focalLength = focalLength
    }
}

public struct ZoomScale {
    public let range: ClosedRange<CGFloat>

    public init(range: ClosedRange<CGFloat>) {
        self.range = range.lowerBound.isFinite && range.upperBound.isFinite && range.lowerBound > 0
            ? range : 1...1
    }

    public func clamped(_ factor: CGFloat) -> CGFloat {
        min(max(factor.isFinite ? factor : 1, range.lowerBound), range.upperBound)
    }

    // One stop of magnification takes the same finger travel anywhere on the dial.
    public func progress(for factor: CGFloat) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return log(clamped(factor) / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    public func factor(at progress: CGFloat) -> CGFloat {
        let position = min(max(progress.isFinite ? progress : 0, 0), 1)
        return clamped(range.lowerBound * pow(range.upperBound / range.lowerBound, position))
    }

    /// Equivalent focal length follows Cam's 24mm main-camera display convention.
    public static func focalLength(for factor: CGFloat) -> Int {
        guard factor.isFinite else { return 24 }
        return Int(min(max((factor * 24).rounded(), 13), CGFloat(Int32.max)))
    }

    public static func nativeIndex(for factor: CGFloat, nativeFactors: [CGFloat]) -> Int? {
        let valid = nativeFactors.enumerated().filter { $0.element.isFinite && $0.element > 0 }
        let value = factor.isFinite ? factor : 1
        return valid.filter { $0.element <= value }.max { $0.element < $1.element }?.offset
            ?? valid.min { $0.element < $1.element }?.offset
    }

    public static func selectedStop(for factor: CGFloat, stops: [ZoomStop]) -> ZoomStop? {
        guard let index = nativeIndex(for: factor, nativeFactors: stops.map(\.factor)) else { return nil }
        return stops[index]
    }

    public static func supportsDepth(at factor: CGFloat, ranges: [ClosedRange<CGFloat>]) -> Bool {
        // Treat disjoint supported ranges separately: the space between them is unsafe.
        factor.isFinite && factor > 0 && ranges.contains { $0.contains(factor) }
    }
}
