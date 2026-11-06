import XCTest
@testable import BokehCore

final class MonocularDepthNormalizationTests: XCTestCase {
    /// 人从中央移到右侧，近处物体移出画面；裁切后原对焦点落在背景上。
    /// 锁焦必须仍用原来的深度标尺，不能重新按本张图的范围归一化或改焦到背景。
    func testLockedPhotoKeepsReframedPersonSharpAfterCrop() throws {
        let w = 160, h = 120
        var before = FloatMap(width: w, height: h, repeating: 0.4)
        for y in 0..<h {
            for x in 0..<16 { before[x, y] = 0 }
            for x in 144..<w { before[x, y] = 10 }
        }
        for y in 25..<95 {
            for x in 50..<95 { before[x, y] = 2 }
        }
        let preview = try XCTUnwrap(MonocularDepthNormalization.normalize(before.values))
        let lockedFocus = preview.values[60 * w + 80]
        XCTAssertEqual(lockedFocus, 0.22, accuracy: 0.0001)

        var rawPhoto = FloatMap(width: w, height: h, repeating: 0.4)
        var person = FloatMap(width: w, height: h, repeating: 0)
        for y in 0..<h {
            for x in 0..<16 { rawPhoto[x, y] = 0 }
        }
        for y in 25..<95 {
            for x in 96..<128 { rawPhoto[x, y] = 2; person[x, y] = 1 }
        }
        let normalized = try XCTUnwrap(MonocularDepthNormalization.normalize(
            rawPhoto.values, fixedRange: preview.range))
        let crop: Float = 1.25
        let depth = FloatMap(width: w, height: h, values: normalized.values).centerCropped(by: crop)
        let mask = person.centerCropped(by: crop)
        let plan = LiveFrameAnalyzer.stillPlan(
            disparity: depth, relativeDepth: true, colors: nil, fNumber: 2.8,
            focusPoint: (0.5, 0.5), personMask: mask, outputLongSide: 3024,
            settings: .init(), personInstances: mask, focalLength35mm: 13,
            lockedFocusDisparity: lockedFocus)
        XCTAssertEqual(plan.focusDisparity, 0.22, accuracy: 0.0001)
        // 原图 (112, 60) → 裁后 (96, 48) 是人，裁后中心 (64, 48) 已经是背景。
        XCTAssertEqual(depth[96, 48], 0.22, accuracy: 0.0001)
        XCTAssertLessThan(abs(plan.lens.signedBlurRadius(disparity: plan.depth[96, 48], imageLongSide: 3024)), 0.1)
        XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: plan.depth[64, 48], imageLongSide: 3024)), 1)
        XCTAssertGreaterThan(plan.seeds?.person?[96, 48] ?? 0, 0.9)
    }

    func testFirstLockedFrameUsesPreviousFrameRangeWithoutSmoothing() throws {
        let range = MonocularDepthNormalization.Range(low: 0, high: 10)
        let raw = (0..<1024).map { $0 < 512 ? Float(0.4) : 2 }
        let result = try XCTUnwrap(MonocularDepthNormalization.normalize(raw, previous: range, fixedRange: range))
        XCTAssertEqual(result.range, range)
        XCTAssertEqual(result.values[900], 0.22, accuracy: 0.0001)
    }

    func testUnlockedPhotoStillUsesItsOwnRange() throws {
        let raw = (0..<1024).map { $0 < 512 ? Float(0.4) : 2 }
        let result = try XCTUnwrap(MonocularDepthNormalization.normalize(raw))
        XCTAssertEqual(result.values[0], 0.02, accuracy: 0.0001)
        XCTAssertEqual(result.values[900], 1.02, accuracy: 0.0001)
        let depth = FloatMap(width: 32, height: 32, values: result.values)
        let plan = LiveFrameAnalyzer.stillPlan(
            disparity: depth, relativeDepth: true, colors: nil, fNumber: 2.8,
            focusPoint: (0.5, 0.75), personMask: nil, outputLongSide: 3024, settings: .init())
        XCTAssertEqual(plan.focusDisparity, 1.02, accuracy: 0.0001)
        XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: depth[4, 4], imageLongSide: 3024)), 1)
    }

    func testUnlockingResumesPreviousRangeSmoothing() throws {
        let range = MonocularDepthNormalization.Range(low: 0, high: 10)
        let raw = (0..<1024).map { $0 < 512 ? Float(0.4) : 2 }
        let result = try XCTUnwrap(MonocularDepthNormalization.normalize(raw, previous: range))
        XCTAssertEqual(result.range.low, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.range.high, 8, accuracy: 0.0001)
        XCTAssertEqual(result.values[900], 0.26050633, accuracy: 0.0001)
    }

    func testHardwareDepthKeepsLockedDistanceWhenFocusPointMovesToBackground() {
        for relative in [false, true] {
            var depth = FloatMap(width: 80, height: 60, repeating: 0.2)
            for y in 15..<45 {
                for x in 50..<75 { depth[x, y] = 0.5 }
            }
            let plan = LiveFrameAnalyzer.stillPlan(
                disparity: depth, relativeDepth: relative, colors: nil, fNumber: 2.8,
                focusPoint: (0.5, 0.5), personMask: nil, outputLongSide: 3024,
                settings: .init(), lockedFocusDisparity: 0.5)
            XCTAssertEqual(plan.focusDisparity, 0.5)
            XCTAssertLessThan(abs(plan.lens.signedBlurRadius(disparity: depth[60, 30], imageLongSide: 3024)), 0.1)
            XCTAssertGreaterThan(abs(plan.lens.signedBlurRadius(disparity: depth[40, 30], imageLongSide: 3024)), 1)
        }
    }
}
