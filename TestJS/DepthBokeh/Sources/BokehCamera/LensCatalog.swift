// 从 DepthBokehCamera 2（最新工作区）迁移：每个变焦倍率该开哪颗摄像头、从哪里拿深度。
// 前置优先使用 TrueDepth，无法使用时回退到普通前置摄像头和 AI 深度。
//
//   倍率            实际用的相机                     画面裁切        深度来源
//   0.5×–0.99×     超广角 0.5×                      1–1.98×        AI 单目深度（Depth Anything V2）
//   1×–1.99×       LiDAR 1×                         1–1.99×        LiDAR
//   2×–4.16×       双摄广角 2×（主摄原生 2× 裁切）    1–2.08×        双摄视差
//   4.17×（100mm） 双摄长焦                          无             双摄视差
//
// 实时深度只在几个倍率点上有（iPhone 17 Pro Max：1×、2×、100mm 长焦）。两个点之间相机停在低的那个点，
// App 自己从中间裁切画面和深度图补足剩下的倍率 —— 开着深度时相机的非原生倍率本来就是数码放大，
// 画质一样，但深度一直有。
//
// 「能不能出深度」运行时用 supportedVideoZoomRangesForDepthDataDelivery 判断：
// 开着深度时，虚拟相机设置不在这些区间里的倍率会直接抛异常。
#if os(iOS)
@preconcurrency import AVFoundation
import CoreGraphics

enum LensKind: String {
    case ultraWide, wide, telephoto
}

struct LensOption: Identifiable, Equatable {
    let kind: LensKind
    let label: String
    let nativeZoom: CGFloat
    var id: String { kind.rawValue }
}

enum DepthSource {
    case starting, lidar, dualCamera, trueDepth, monocular, unavailable

    var label: String {
        switch self {
        case .starting: return "启动中…"
        case .lidar: return "LiDAR 深度"
        case .dualCamera: return "双摄视差"
        case .trueDepth: return "TrueDepth 深度"
        case .monocular: return "AI 深度"
        case .unavailable: return "无深度"
        }
    }

    var isHardwareDepth: Bool {
        switch self {
        case .lidar, .dualCamera, .trueDepth: return true
        default: return false
        }
    }
}

struct FormatChoice {
    let format: AVCaptureDevice.Format
    let depthFormat: AVCaptureDevice.Format?
}

/// How to open the session for one lens.
struct CameraPlan {
    let device: AVCaptureDevice
    let format: FormatChoice?
    /// Zoom factor to set before depth is enabled (selects the lens on a virtual camera).
    let zoom: CGFloat?
    let source: DepthSource
    /// Field of view of the stream as a dial zoom (main wide camera = 1×). The preview and the photo
    /// crop from here to the dial's zoom (`dial / streamZoom`, ≥ 1).
    var streamZoom: CGFloat = 1
}

enum LensCatalog {

    // Discovery and format scoring happen once. Dial updates only perform small lookup queries.
    private static let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
                      .builtInDualWideCamera, .builtInDualCamera, .builtInLiDARDepthCamera,
                      .builtInTrueDepthCamera],
        mediaType: .video, position: .unspecified).devices

    private static func device(_ type: AVCaptureDevice.DeviceType,
                               position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        devices.first { $0.deviceType == type && $0.position == position }
    }

    private static let lensOptions = makeAvailableLenses()
    private static let formatProfiles: [String: FormatProfile] = Dictionary(uniqueKeysWithValues:
        devices.map { ($0.uniqueID, FormatProfile(device: $0)) })

    // MARK: Lens buttons

    /// Physical cameras on this phone, in UI order: 0.5×, 1×, tele.
    static func availableLenses() -> [LensOption] {
        _ = formatProfiles   // Warm the profiles before the user starts dragging.
        return lensOptions
    }

    private static func makeAvailableLenses() -> [LensOption] {
        let back = devices.filter { $0.position == .back }
        let wide = back.first { $0.deviceType == .builtInWideAngleCamera }

        var lenses: [LensOption] = []
        if let ultra = back.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
            // Exact ratio from the dual-wide camera's switch-over factor (2 → 0.5×), else from the FOVs.
            var magnification = fovMagnification(of: ultra, relativeTo: wide)
            if let dualWide = device(.builtInDualWideCamera, position: .back),
               let s = dualWide.virtualDeviceSwitchOverVideoZoomFactors.first, s.doubleValue > 0 {
                magnification = 1 / s.doubleValue
            }
            lenses.append(LensOption(kind: .ultraWide, label: formatZoom(magnification, fallback: "0.5×"),
                                     nativeZoom: CGFloat(magnification ?? 0.5)))
        }
        if wide != nil {
            lenses.append(LensOption(kind: .wide, label: "1×", nativeZoom: 1))
        }
        if let tele = back.first(where: { $0.deviceType == .builtInTelephotoCamera }) {
            var magnification = fovMagnification(of: tele, relativeTo: wide)
            if let dual = device(.builtInDualCamera, position: .back),
               let s = dual.virtualDeviceSwitchOverVideoZoomFactors.last, s.doubleValue > 0 {
                magnification = s.doubleValue
            }
            // 切换倍率是取整的（17 Pro Max 报 4，长焦实际是 100mm）：有标称焦距时按真实焦距定位
            if let nominal = nominalMagnification(of: tele, relativeTo: wide) {
                magnification = nominal
            }
            lenses.append(LensOption(kind: .telephoto, label: formatZoom(magnification, fallback: "长焦"),
                                     nativeZoom: CGFloat(magnification ?? 2)))
        }
        return lenses
    }

    /// Magnification relative to the wide camera from the horizontal fields of view.
    private static func fovMagnification(of device: AVCaptureDevice, relativeTo wide: AVCaptureDevice?) -> Double? {
        guard let wide else { return nil }
        let fovWide = Double(wide.activeFormat.videoFieldOfView) * .pi / 180
        let fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        guard fovWide > 0.01, fov > 0.01 else { return nil }
        return tan(fovWide / 2) / tan(fov / 2)
    }

    /// Ratio of the nominal 35mm-equivalent focal lengths (physical cameras, iOS 26+).
    private static func nominalMagnification(of device: AVCaptureDevice, relativeTo wide: AVCaptureDevice?) -> Double? {
        guard #available(iOS 26.0, *) else { return nil }
        guard let wide else { return nil }
        let focal = Double(device.nominalFocalLengthIn35mmFilm)
        let wideFocal = Double(wide.nominalFocalLengthIn35mmFilm)
        guard focal > 0, wideFocal > 0 else { return nil }
        return focal / wideFocal
    }

    /// 0.5 → "0.5×", 2.5 → "2.5×", 4.9… → "5×".
    private static func formatZoom(_ magnification: Double?, fallback: String) -> String {
        guard let m = magnification, m.isFinite, m > 0.05, m < 100 else { return fallback }
        if abs(m - m.rounded()) < 0.08 { return "\(Int(m.rounded()))×" }
        return String(format: "%.1f×", (m * 10).rounded() / 10)
    }

    // MARK: Session plan per lens

    static func frontPlans() -> [CameraPlan] {
        [depthPlan(.builtInTrueDepthCamera, .front, .trueDepth) { _ in 1 },
         plainPlan(.builtInWideAngleCamera, .front, .monocular, zoom: 1),
         plainPlan(.builtInTrueDepthCamera, .front, .monocular, zoom: 1)].compactMap { $0 }
    }

    /// The route the session tries first for a dial zoom (back cameras).
    static func plan(forDisplayZoom zoom: CGFloat) -> CameraPlan? {
        settledPlans(displayZoom: zoom).first
    }

    /// Back-camera routes for a dial zoom, best first; the session tries them in order until one opens.
    ///   1. a depth route that delivers depth at exactly this zoom (camera zoom = dial, no crop);
    ///   2. the nearest depth anchor below: the camera stays there, the preview crops the rest
    ///      (17 Pro Max: 1×–1.99× on LiDAR 1×, 2×–4.16× on dual-wide 2×, 100mm on the dual telephoto);
    ///   3. the plain camera of this zoom's segment at its native view, cropped (AI depth). Below the
    ///      first anchor (0.5×–0.99×) only this one exists.
    static func settledPlans(displayZoom zoom: CGFloat) -> [CameraPlan] {
        guard let lens = segment(for: zoom) else { return [] }
        let direct = plans(for: lens.kind, displayZoom: zoom, nativeZoom: lens.nativeZoom)
        var result = direct.filter { $0.format?.depthFormat != nil }
        if let anchor = depthAnchors.last(where: { $0 <= zoom + 0.0001 }), abs(anchor - zoom) > 0.0001,
           let anchorLens = segment(for: anchor) {
            result += plans(for: anchorLens.kind, displayZoom: anchor, nativeZoom: anchorLens.nativeZoom)
                .filter { $0.format?.depthFormat != nil }
        }
        // Without depth, open the segment's camera at its own native view and crop as well: changing
        // the zoom of a running camera shows a few frames at the wrong scale (0.5× → 0.75× flashed).
        let plain = plans(for: lens.kind, displayZoom: lens.nativeZoom, nativeZoom: lens.nativeZoom)
            .filter { $0.format?.depthFormat == nil }
        return result + plain
    }

    /// Dial zoom factors where some back camera streams hardware depth, from the depth formats'
    /// reported zoom points (17 Pro Max: 1, 2, 4.17).
    private static let depthAnchors: [CGFloat] = {
        let dial = zoomRange(for: availableLenses())
        var points = Set<CGFloat>()
        for type in [AVCaptureDevice.DeviceType.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera] {
            guard let device = device(type, position: .back), let profile = formatProfiles[device.uniqueID] else { continue }
            for point in profile.depth.boundaries { points.insert(dialZoom(forDeviceZoom: point, of: device)) }
        }
        return points.filter { dial.contains($0) }.sorted().filter { zoom in
            guard let lens = segment(for: zoom) else { return false }
            return plans(for: lens.kind, displayZoom: zoom, nativeZoom: lens.nativeZoom)
                .contains { $0.format?.depthFormat != nil }
        }
    }()

    /// A virtual camera's zoom factor on the dial. From the telephoto switch-over on, the stream is the
    /// telephoto's own view (17 Pro Max: camera zoom 4 = 100mm = dial 4.17×), not the rounded factor.
    private static func dialZoom(forDeviceZoom zoom: CGFloat, of device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices.map(\.deviceType)
        let wideZoom = constituents.contains(.builtInUltraWideCamera) ? (firstSwitchOver(device) ?? 1) : 1
        let dial = zoom / wideZoom
        guard constituents.contains(.builtInTelephotoCamera), let switchOver = lastSwitchOver(device),
              let tele = lensOptions.first(where: { $0.kind == .telephoto }) else { return dial }
        let teleStart = switchOver / wideZoom
        return dial >= teleStart - 0.0001 ? dial / teleStart * tele.nativeZoom : dial
    }

    /// The back lens whose segment of the dial contains `zoom` (0.5×–0.99× ultra-wide, 1×–4.16× wide …).
    private static func segment(for zoom: CGFloat) -> LensOption? {
        let back = availableLenses().sorted { $0.nativeZoom < $1.nativeZoom }
        return ZoomScale.nativeIndex(for: zoom, nativeFactors: back.map(\.nativeZoom)).map { back[$0] }
    }

    /// Routes for one lens at one zoom, best first. The camera shows `displayZoom` itself (streamZoom).
    /// A segment keeps its physical camera's native magnification on the wide = 1× scale.
    /// Hardware routes are admitted only at a zoom explicitly supported by their depth format.
    static func plans(for lens: LensKind, displayZoom: CGFloat? = nil, nativeZoom: CGFloat? = nil) -> [CameraPlan] {
        let native = nativeZoom ?? availableLenses().first(where: { $0.kind == lens })?.nativeZoom ?? 1
        let target = displayZoom ?? native
        let relativeZoom = target / native
        let plans: [CameraPlan?]
        switch lens {
        case .wide:
            plans = [depthPlan(.builtInLiDARDepthCamera, .back, .lidar) { _ in relativeZoom },
                     depthPlan(.builtInDualWideCamera, .back, .dualCamera) { device in
                         firstSwitchOver(device).map { $0 * relativeZoom }
                     },
                     // From the switch-over on this camera streams the telephoto, whose view is not `relativeZoom`.
                     depthPlan(.builtInDualCamera, .back, .dualCamera) { device in
                         relativeZoom < (lastSwitchOver(device) ?? .infinity) - 0.0001 ? relativeZoom : nil
                     },
                     plainPlan(.builtInWideAngleCamera, .back, .monocular, zoom: relativeZoom)]
        case .ultraWide:
            plans = [depthPlan(.builtInDualWideCamera, .back, .dualCamera) { _ in relativeZoom },
                     plainPlan(.builtInUltraWideCamera, .back, .monocular, zoom: relativeZoom)]
        case .telephoto:
            plans = [depthPlan(.builtInDualCamera, .back, .dualCamera) { device in
                         lastSwitchOver(device).map { $0 * relativeZoom }
                     },
                     plainPlan(.builtInTelephotoCamera, .back, .monocular, zoom: relativeZoom)]
        }
        let streamZoom = target
        return plans.compactMap { $0.map { var plan = $0; plan.streamZoom = streamZoom; return plan } }
    }

    /// Longest focal length on the dial (35mm equivalent; 1× = 24mm). 17 Pro Max: its 100mm telephoto.
    static let maxFocalLength: CGFloat = 100
    static let maxDialZoom: CGFloat = maxFocalLength / 24

    /// Limit the dial to `maxFocalLength`, intersected with real format limits.
    static func zoomRange(for lenses: [LensOption]) -> ClosedRange<CGFloat> {
        let back = lenses.sorted { $0.nativeZoom < $1.nativeZoom }
        guard let first = back.first else { return 1...1 }
        var maximum = first.nativeZoom
        for lens in back {
            let type: AVCaptureDevice.DeviceType
            switch lens.kind {
            case .ultraWide: type = .builtInUltraWideCamera
            case .wide: type = .builtInWideAngleCamera
            case .telephoto: type = .builtInTelephotoCamera
            }
            if let device = device(type, position: .back),
               let choice = pickFormat(for: device, requireDepthAtZoom: nil) {
                maximum = lens.nativeZoom * choice.format.videoMaxZoomFactor
            }
        }
        // A lens sitting at the limit is the limit, so rounding in its magnification cannot drop its stop.
        let cap = back.map(\.nativeZoom).first { abs($0 / maxDialZoom - 1) < 0.01 } ?? maxDialZoom
        return first.nativeZoom...max(first.nativeZoom, min(cap, maximum))
    }

    private static func firstSwitchOver(_ device: AVCaptureDevice) -> CGFloat? {
        device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) }
    }

    private static func lastSwitchOver(_ device: AVCaptureDevice) -> CGFloat? {
        device.virtualDeviceSwitchOverVideoZoomFactors.last.map { CGFloat(truncating: $0) }
    }

    /// A depth-capable device opened at the zoom factor that selects the wanted lens —
    /// only if some format can deliver depth at exactly that zoom.
    private static func depthPlan(_ type: AVCaptureDevice.DeviceType, _ position: AVCaptureDevice.Position,
                                  _ source: DepthSource, zoom: (AVCaptureDevice) -> CGFloat?) -> CameraPlan? {
        guard let device = device(type, position: position),
              let z = zoom(device),
              let format = pickFormat(for: device, requireDepthAtZoom: z) else { return nil }
        return CameraPlan(device: device, format: format, zoom: z, source: source)
    }

    private static func plainPlan(_ type: AVCaptureDevice.DeviceType, _ position: AVCaptureDevice.Position,
                                  _ source: DepthSource, zoom: CGFloat) -> CameraPlan? {
        guard let device = device(type, position: position) else { return nil }
        guard let format = pickFormat(for: device, requireDepthAtZoom: nil, requireZoom: zoom) else { return nil }
        return CameraPlan(device: device, format: format, zoom: zoom, source: source)
    }

    private static let depthPixelTypes: [OSType] = [kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DisparityFloat32,
                                                    kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DepthFloat32]

    /// Highest-resolution companion depth format, preferring ones that keep up with 30 fps video:
    /// a depth stream slower than the video leaves frames without fresh depth (moving things then
    /// drag a stale depth outline behind them).
    private static func largestDepthFormat(of format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        let usable = format.supportedDepthDataFormats.filter {
            depthPixelTypes.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription))
        }
        let fast = usable.filter { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 } }
        return (fast.isEmpty ? usable : fast).max {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }
    }

    // MARK: Formats

    /// Picks a ≤1920-wide, 30 fps, preferably 4:3 format (same aspect as photos). When
    /// `requireDepthAtZoom` is set, only formats that deliver depth at that zoom factor qualify,
    /// and the largest depth format is chosen.
    static func pickFormat(for device: AVCaptureDevice, requireDepthAtZoom zoom: CGFloat?,
                           requireZoom: CGFloat? = nil) -> FormatChoice? {
        guard let profile = formatProfiles[device.uniqueID] else { return nil }
        if let zoom { return profile.depth.choice(at: zoom) }
        return profile.plain.choice(at: requireZoom ?? 1)
    }

    private struct FormatProfile {
        let plain: FormatLookup
        let depth: FormatLookup

        init(device: AVCaptureDevice) {
            var ranked: [(score: Int, plain: FormatChoice, depth: FormatChoice?, ranges: [ClosedRange<CGFloat>])] = []
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width >= 640, dims.width <= 1920, dims.height > 0,
                      format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 })
                else { continue }
                var score = Int(dims.width)
                if abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.02 { score += 10_000 }
                if (format.supportedMaxPhotoDimensions.map { Int($0.width) }.max() ?? 0) >= 4000 { score += 5_000 }
                if CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                    score += 50
                }
                let depthFormat = LensCatalog.largestDepthFormat(of: format)
                let reported = LensCatalog.depthZoomRanges(for: format)
                let ranges = !device.isVirtualDevice && reported.isEmpty
                    ? [CGFloat(1)...format.videoMaxZoomFactor] : reported
                ranked.append((score, FormatChoice(format: format, depthFormat: nil),
                               depthFormat.map { FormatChoice(format: format, depthFormat: $0) }, ranges))
            }
            ranked.sort { $0.score > $1.score }
            plain = FormatLookup(ranked.map { ($0.plain, [CGFloat(1)...$0.plain.format.videoMaxZoomFactor]) })
            depth = FormatLookup(ranked.compactMap { entry in
                guard let choice = entry.depth else { return nil }
                let bounds = CGFloat(1)...choice.format.videoMaxZoomFactor
                let clipped = entry.ranges.compactMap { range -> ClosedRange<CGFloat>? in
                    let lower = max(bounds.lowerBound, range.lowerBound)
                    let upper = min(bounds.upperBound, range.upperBound)
                    return lower <= upper ? lower...upper : nil
                }
                return (choice, clipped)
            })
        }
    }

    /// Store exact boundary choices separately from open intervals. This preserves isolated depth
    /// points and holes between supported ranges without rescanning capture formats during a drag.
    private struct FormatLookup {
        let boundaries: [CGFloat]
        let atBoundary: [FormatChoice?]
        let betweenBoundaries: [FormatChoice?]

        init(_ candidates: [(FormatChoice, [ClosedRange<CGFloat>])]) {
            let points = Array(Set(candidates.flatMap { $0.1.flatMap { [$0.lowerBound, $0.upperBound] } })).sorted()
            func choose(_ value: CGFloat) -> FormatChoice? {
                candidates.first { ZoomScale.supportsDepth(at: value, ranges: $0.1) }?.0
            }
            boundaries = points
            atBoundary = points.map(choose)
            betweenBoundaries = zip(points, points.dropFirst()).map { choose($0 + ($1 - $0) / 2) }
        }

        func choice(at zoom: CGFloat) -> FormatChoice? {
            guard zoom.isFinite, let first = boundaries.first, let last = boundaries.last,
                  zoom >= first, zoom <= last else { return nil }
            var lower = 0
            var upper = boundaries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if boundaries[middle] < zoom { lower = middle + 1 } else { upper = middle }
            }
            if lower < boundaries.count, boundaries[lower] == zoom { return atBoundary[lower] }
            return lower > 0 ? betweenBoundaries[lower - 1] : nil
        }
    }

    /// Zoom factors at which this format can deliver depth; virtual empty ranges admit no zoom.
    static func depthZoomRanges(for format: AVCaptureDevice.Format) -> [ClosedRange<CGFloat>] {
        if #available(iOS 17.2, *) {
            return format.supportedVideoZoomRangesForDepthDataDelivery
        } else {
            return format.supportedVideoZoomFactorsForDepthDataDelivery.map { $0...$0 }
        }
    }

    /// Largest photo size up to ~12 MP (depth delivery is not available for 24/48 MP).
    static func photoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        let all = format.supportedMaxPhotoDimensions
        let capped = all.filter { Int($0.width) * Int($0.height) <= 4032 * 3024 }
        let pool = capped.isEmpty ? all : capped
        return pool.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
    }
}
#endif
