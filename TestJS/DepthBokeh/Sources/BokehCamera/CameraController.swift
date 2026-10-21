#if os(iOS)
@preconcurrency import AVFoundation
import Combine
import UIKit
import BokehCore

/// 拍下来的一张带深度的照片（已降采样、深度已对齐），可以反复改光圈、改对焦点
public struct CapturedDepthPhoto: Identifiable {
    public let id = UUID()
    /// 线性光图像（传感器方向，未旋转；已按拍照时的倍率裁好）
    public let image: PlanarImage
    /// 原始视差图（已补洞，分辨率低于 image；渲染时再和图像对齐）
    public let disparity: FloatMap
    /// 显示方向
    public let orientation: UIImage.Orientation
    /// 拍照时的对焦点（原图归一化坐标）
    public let focusPoint: CGPoint
    /// 拍照时的光圈
    public let fNumber: Float
    /// 视差只有相对值（双摄视差 / AI 单目深度），不能换算成米
    public let isRelativeDepth: Bool
}

/// 实时景深相机。
///
/// 变焦和 DepthBokehCamera 2 一样（0.5×–4×，点数字或拖刻度）：
///  - 拖动时只裁切当前相机的画面（往大拖不换相机，往小拖超过当前相机 5% 才马上换）
///  - 松手或点数字约 0.3 秒后，换到这个倍率最合适的相机（LensCatalog）：
///      0.5×–0.99× 超广角 + AI 深度，1×–1.99× LiDAR，2×–3.99× 双摄 2×，4× 双摄长焦
///  - 两个深度倍率点之间，画面和深度图都从中间裁（相机本身的倍率一旦打开就不再改）
///  - 换相机期间保留最后一帧（继续跟着倍率放大），新相机出了 3 帧并且有深度（最多 0.8 秒）后，
///    0.2 秒淡入
///  - 点数字时预览在 0.3 秒内平滑变焦过去
///
/// 每帧在后台线程用纯 Swift 的 BokehRenderer 渲染虚化预览；拍照时连同深度一起拿到，交给 PhotoBokehEditor
public final class DepthCameraController: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - 给 UI 的状态（只在主线程修改）
    @Published public private(set) var previewImage: UIImage?
    /// previewImage 的视场倍率（1× = 主摄）。界面用 `previewZoom / previewFrameZoom` 补上它和当前倍率之间的差
    @Published public private(set) var previewFrameZoom: CGFloat = 1
    /// 换相机时的上一帧（淡出用）；`routeTransitionID` 每换一次相机加一
    @Published public private(set) var transitionImage: UIImage?
    @Published public private(set) var transitionImageZoom: CGFloat = 1
    @Published public private(set) var routeTransitionID = 0
    /// transitionImage 开始淡出的时间（CACurrentMediaTime）
    public private(set) var transitionStart: CFTimeInterval = 0
    @Published public private(set) var statusText = "正在启动相机…"
    @Published public private(set) var lastPhoto: CapturedDepthPhoto?
    @Published public private(set) var isCapturing = false
    /// 主体太近，景深已自动关闭
    @Published public private(set) var isTooClose = false
    /// 当前深度来源（LiDAR / 双摄视差 / AI 深度）
    @Published public private(set) var depthSourceLabel = ""
    /// 点数字后的 0.3 秒平滑变焦进行中（界面在这段时间按显示刷新率更新）
    @Published public private(set) var isZoomGliding = false

    // MARK: - 变焦（界面和交互复用 DepthBokehCamera 2 的 ContinuousZoomControl / ZoomScale）
    /// 刻度盘上的倍率（1× = 主摄 24mm）
    @Published public private(set) var zoomFactor: CGFloat = 1
    /// 可调范围（iPhone 17 Pro Max：0.5×–4×）
    @Published public private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// 快捷焦段（0.5×、1×、2×、4×）
    @Published public private(set) var zoomStops: [ZoomStop] = []
    /// 换相机还没出第一帧：快门暂时不可用（刻度盘照常可以拖）
    @Published public private(set) var isZoomSettling = true

    /// 实时预览输出的长边（像素）。清晰部分按这个分辨率显示
    public var previewLongSide = 1440
    /// 模糊部分在几分之一的分辨率上计算（3 = 1440 → 480），越大越快
    public var blurDownscale = 3
    /// 对焦面前后的全清晰区（相对对焦距离，0.06 = ±6%，和系统相机一致）
    public var focusTolerance: Float = 0.06
    /// 只在 `lensModel = .thinLens` 时使用：模拟镜头的 35mm 等效焦距
    public var virtualFocalLength: Float = 52
    /// 虚化模型。默认 `.system`：按系统相机实测标定，虚化量只和 ƒ、相对距离有关
    public var lensModel: LensParameters.Model = .system
    /// 让对焦的主体整个保持清晰（深度 + 颜色做主体遮罩，修正主体边缘深度不准）
    public var keepSubjectSharp = true
    /// 景深效果允许的最近对焦距离（米）。主体比这更近时，和系统相机一样自动关掉景深并提示离远一点。
    /// 只对 LiDAR 这种绝对深度生效（双摄视差、AI 深度换算不出米）
    public var minSubjectDistance: Float = 0.30
    /// 拍照后给编辑器的图像长边
    public var photoLongSide = 3024

    // MARK: - 渲染参数（UI 线程写、数据线程读，用锁保护）
    private let paramLock = NSLock()
    private var _fNumber: Float = 2.8
    /// 对焦点：当前相机画面（未裁切）里的归一化坐标，传感器方向
    private var _focusPoint = CGPoint(x: 0.5, y: 0.5)
    private var focusResetPending = false
    // 预览平滑变焦（点数字时 0.3 秒、对数空间匀速）
    private var glideFrom: CGFloat = 1
    private var glideTo: CGFloat = 1
    private var glideStart: CFTimeInterval = 0
    private static let glideDuration: CFTimeInterval = 0.3

    /// 模拟光圈值
    public var fNumber: Float {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _fNumber }
        set { paramLock.lock(); _fNumber = newValue; paramLock.unlock() }
    }

    /// 预览此刻应该显示的倍率（点数字后的平滑变焦过程中介于新旧倍率之间）。任意线程
    public var previewZoom: CGFloat {
        paramLock.lock(); defer { paramLock.unlock() }
        return glideValueLocked(at: CACurrentMediaTime())
    }

    private func glideValueLocked(at now: CFTimeInterval) -> CGFloat {
        let t = (now - glideStart) / Self.glideDuration
        guard t >= 0, t < 1, glideFrom > 0, glideTo > 0 else { return glideTo }
        let eased = CGFloat(t * t * (3 - 2 * t))
        return glideFrom * pow(glideTo / glideFrom, eased)
    }

    /// 预览帧的显示方向：后置摄像头竖屏时原始帧需要顺时针转 90°
    public let previewOrientation: UIImage.Orientation = .right

    // MARK: - 变焦调度（主线程）：同一时间只做一次相机操作，只保留最新的目标
    private var lenses: [LensOption] = []
    private var backZoomRange: ClosedRange<CGFloat> = 1...1
    private var pendingZoom: CGFloat?
    /// 待处理的倍率要换到它最合适的相机（手指已松开），而不只是继续裁切
    private var pendingSettle = false
    private var settleWork: DispatchWorkItem?
    /// 当前相机画面的视场倍率（主线程的副本）
    private var activeStreamZoom: CGFloat?
    private var activeDisplayZoom: CGFloat = 1
    private var zoomOperationInFlight = false
    private var zoomRevision = 0
    private var latestFrameRevision = -1
    private var glideToken = 0
    private var transitionToken = 0
    /// 屏幕上那一帧相对它的相机画面裁了多少（点按对焦换算坐标用）
    private var displayedCrop: CGFloat = 1

    // MARK: - AVFoundation
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "depthbokeh.session")
    private let dataQueue = DispatchQueue(label: "depthbokeh.data", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "depthbokeh.photo", qos: .userInitiated)
    // 每次重建会话都换新的，旧的同步器不会再拿着它们
    private var videoOutput = AVCaptureVideoDataOutput()
    private var depthOutput = AVCaptureDepthDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    // sessionQueue
    private var device: AVCaptureDevice?
    private var activePlan: CameraPlan?
    private var isConfigured = false

    // MARK: - 每帧状态（只在 dataQueue 上访问）
    private let renderer = BokehRenderer()
    private var acceptedVideoOutput: AVCaptureVideoDataOutput?
    private var acceptedSynchronizer: AVCaptureDataOutputSynchronizer?
    private var focusStabilizer = FocusStabilizer()
    /// 跨帧稳定深度边缘和焦外光斑（静止时不闪，运动时不拖影）
    private let temporal = TemporalState()
    private var effectAmount: Float = 1
    private var tooCloseState = false
    private var lastFrameTime: CFTimeInterval?
    private var frameTimes: [Double] = []
    /// 当前相机的视场倍率（每帧都按它和 previewZoom 算裁切）
    private var streamZoom: CGFloat = 1
    private var depthEnabled = false
    /// 这条线路本来就有硬件深度：深度晚到时沿用上一张，不切到 AI 深度
    private var depthExpected = false
    private var hardwareSource: DepthSource = .monocular
    private var cachedDepth: FloatMap?
    private var cachedDepthRelative = false
    private var cachedDepthTime = CMTime.invalid
    private var lastFrameUsedHardwareDepth: Bool?
    private var lastMonoMap: FloatMap?
    private var monoRange: DepthRange?
    private var monoCounter = 0
    private var smoothedNear: Float?
    private var smoothedFar: Float?
    private var frameZoomRevision = 0
    private var minimumFrameTimestamp = CMTime.invalid
    private var notifyZoomFrame = false
    /// 换相机后，新画面可以替换屏幕上的最后一帧之前为 false
    private var routeReady = true
    private var routeFrames = 0
    private var routeStart: CFTimeInterval = 0
    private var lastPublishedZoom: CGFloat = 1
    private var reportedSource: DepthSource = .starting
    // 拍照时用：最近一帧的裁切
    private var lastFrameCrop: CGFloat = 1

    public override init() { super.init() }

    // MARK: - 启停

    public func start() {
        // 0.5× 超广角的 AI 深度模型：App 里打包了（或之前下载过）就马上加载
        if DepthModelStore.shared.isAvailableOffline {
            DepthModelStore.shared.prepare()
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureIfNeededAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureIfNeededAndRun() }
                } else {
                    self.setStatus("没有相机权限")
                }
            }
        default:
            setStatus("没有相机权限，请到「设置」里打开")
        }
    }

    public func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - 对焦

    /// 点按对焦。point 是屏幕上那一帧（传感器方向）里的归一化坐标（用 ImageBridge.rawPoint 从屏幕坐标换算）
    public func focus(atRawPoint point: CGPoint) {
        // 屏幕上的帧是从相机画面中间裁出来的：换算回整个相机画面
        let c = max(displayedCrop, 1)
        let p = CGPoint(x: min(max(0.5 + (point.x - 0.5) / c, 0), 1),
                        y: min(max(0.5 + (point.y - 0.5) / c, 0), 1))
        paramLock.lock(); _focusPoint = p; focusResetPending = true; paramLock.unlock()
        sessionQueue.async { self.focusDevice(at: p) }
    }

    /// sessionQueue：让真实镜头也对到这里，否则「清晰区域」本身可能是光学失焦的
    private func focusDevice(at p: CGPoint) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        // iOS 15.4 起相机会优先对人脸，连续对焦时会一直把镜头拉回脸上：点按时关掉
        Self.setFaceDrivenFocus(false, on: d)
        if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.autoFocus) {
            d.focusPointOfInterest = p
            d.focusMode = .autoFocus
        }
        if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.autoExpose) {
            d.exposurePointOfInterest = p
            d.exposureMode = .autoExpose
        }
        d.unlockForConfiguration()
    }

    /// sessionQueue：回到连续自动对焦（画面中心）
    private func focusDeviceAtCenter() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        Self.setFaceDrivenFocus(true, on: d)
        if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = center }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = center }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        d.unlockForConfiguration()
    }

    /// 人脸优先对焦 / 测光（iOS 15.4 起默认打开）。调用时设备必须已经 lockForConfiguration
    private static func setFaceDrivenFocus(_ enabled: Bool, on device: AVCaptureDevice) {
        if device.isFocusModeSupported(.autoFocus) || device.isFocusModeSupported(.continuousAutoFocus) {
            device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = enabled
            if !enabled { device.isFaceDrivenAutoFocusEnabled = false }
        }
        if device.isExposureModeSupported(.autoExpose) || device.isExposureModeSupported(.continuousAutoExposure) {
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = enabled
            if !enabled { device.isFaceDrivenAutoExposureEnabled = false }
        }
    }

    // MARK: - 变焦（主线程）

    /// 手指拖动刻度时连续调用。只要当前相机的画面裁得出来（往大拖），相机就不动、深度一直有；
    /// 只有要比当前相机更广（往小拖超过 5%）才马上换相机。松手后由 `commitZoom` 换到最合适的相机
    public func setZoomFactor(_ factor: CGFloat) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCapturing, factor.isFinite else { return }
        let target = ZoomScale(range: backZoomRange).clamped(factor)
        guard abs(target - zoomFactor) > 0.00001 else { return }
        // 跳变（点数字）平滑过去；拖动的步子小，直接跟手
        showZoom(target, glide: abs(log(target / previewZoom)) > 0.15)
        isZoomSettling = true
        settleWork?.cancel()
        if zoomOperationInFlight {
            pendingZoom = target   // 正在换的相机换好后再处理
        } else if !canCrop(to: target) {
            requestRoute(for: target, settle: false)
        }
    }

    /// 手指离开刻度盘（或点了数字）：`delay` 秒内没有新操作，就换到这个倍率最合适的相机 ——
    /// 它下面最近的深度倍率点，剩下的靠裁切。点数字（正在平滑变焦）时马上换，让相机在变焦动画期间启动
    public func commitZoom(after delay: TimeInterval? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let delay = delay ?? (isGliding ? 0 : 0.3)
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCapturing else { return }
            self.requestRoute(for: self.zoomFactor, settle: true)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var isGliding: Bool {
        paramLock.lock(); defer { paramLock.unlock() }
        return CACurrentMediaTime() - glideStart < Self.glideDuration
    }

    /// 设置刻度盘倍率；glide = 从现在显示的倍率平滑过去
    private func showZoom(_ zoom: CGFloat, glide: Bool) {
        let now = CACurrentMediaTime()
        paramLock.lock()
        glideFrom = glide ? glideValueLocked(at: now) : zoom
        glideStart = glide ? now : 0
        glideTo = zoom
        paramLock.unlock()
        zoomFactor = zoom
        if glide { markGliding() }
    }

    private func markGliding() {
        glideToken &+= 1
        let token = glideToken
        isZoomGliding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glideDuration + 0.05) {
            if self.glideToken == token { self.isZoomGliding = false }
        }
    }

    /// 拖动时最多把当前相机的画面裁到几倍。刻度最大 4×，所以从 1×（LiDAR）往大拖，松手前不会换相机
    private static let maxDragCrop: CGFloat = 4

    /// 拖动时也可以比当前相机广 5%（画面停在相机的视场）：在 2× 这种数字下面一点徘徊时，
    /// 不会先换到 1× 的相机、松手吸附到 2× 又换回来
    private func canCrop(to zoom: CGFloat) -> Bool {
        guard let stream = activeStreamZoom else { return false }
        return zoom >= stream * 0.95 && zoom / stream <= Self.maxDragCrop
    }

    private func requestRoute(for zoom: CGFloat, settle: Bool) {
        pendingZoom = zoom
        pendingSettle = pendingSettle || settle
        applyPendingZoom()
    }

    private func applyPendingZoom() {
        guard !zoomOperationInFlight, let target = pendingZoom else { return }
        zoomRevision &+= 1
        let revision = zoomRevision
        pendingZoom = nil
        pendingSettle = false
        zoomOperationInFlight = true
        let previousZoom = activeDisplayZoom
        sessionQueue.async {
            let applied = self.configureSession(displayZoom: target, revision: revision)
            let restored = applied == nil ? self.configureSession(displayZoom: previousZoom, revision: revision) : nil
            DispatchQueue.main.async {
                self.zoomOperationInFlight = false
                if let plan = applied ?? restored { self.activeStreamZoom = plan.streamZoom }
                if applied != nil {
                    self.activeDisplayZoom = target
                } else {
                    self.showStatusMessage("这个倍率现在无法使用")
                    if self.pendingZoom == nil { self.showZoom(previousZoom, glide: false) }
                }
                // 期间又来了新目标：要换相机（松手了，或裁不出来）就继续，否则直接从新画面裁
                if let next = self.pendingZoom, !self.pendingSettle, self.canCrop(to: next) {
                    self.pendingZoom = nil
                }
                if self.pendingZoom != nil {
                    self.applyPendingZoom()
                } else {
                    self.finishZoomIfReady()
                }
            }
        }
    }

    private func finishZoomIfReady() {
        if !zoomOperationInFlight, pendingZoom == nil, latestFrameRevision == zoomRevision {
            isZoomSettling = false
        }
    }

    private func updateZoomStops() {
        var factors = lenses.filter { zoomRange.contains($0.nativeZoom) }.map(\.nativeZoom)
        if zoomRange.contains(2), !factors.contains(where: { abs($0 - 2) < 0.0001 }) {
            factors.append(2)   // 48mm：主摄原生 2× 裁切
        }
        zoomStops = factors.sorted().map { ZoomStop(factor: $0, focalLength: ZoomScale.focalLength(for: $0)) }
    }

    // MARK: - 拍照

    public func capturePhoto() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCapturing, !isZoomSettling else { return }
        isCapturing = true
        sessionQueue.async {
            guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            let dims = self.photoOutput.maxPhotoDimensions
            if dims.width > 0 && dims.height > 0 { settings.maxPhotoDimensions = dims }
            if self.photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.isDepthDataFiltered = true   // 让系统先补洞、平滑
            }
            if let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90          // 竖屏拍摄：只写进 EXIF 方向，像素本身不旋转
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - 会话配置（sessionQueue）

    private func configureIfNeededAndRun() {
        if !isConfigured {
            isConfigured = true
            let lenses = LensCatalog.availableLenses()
            let range = LensCatalog.zoomRange(for: lenses)
            let initialZoom = ZoomScale(range: range).clamped(1)
            DispatchQueue.main.async {
                self.lenses = lenses
                self.backZoomRange = range
                self.zoomRange = range
                self.showZoom(initialZoom, glide: false)
                self.activeDisplayZoom = initialZoom
                self.updateZoomStops()
            }
            let plan = configureSession(displayZoom: initialZoom)
            DispatchQueue.main.async { self.activeStreamZoom = plan?.streamZoom }
            if plan == nil { setStatus("没有可用的后置摄像头") }
        }
        if !session.isRunning { session.startRunning() }
    }

    /// 按 LensCatalog 给的顺序逐个尝试，打开这个倍率最合适的相机。返回打开的那条线路，都失败返回 nil
    @discardableResult
    private func configureSession(displayZoom: CGFloat, revision: Int = 0) -> CameraPlan? {
        for plan in LensCatalog.settledPlans(displayZoom: displayZoom) where apply(plan, revision: revision) {
            return plan
        }
        return nil
    }

    /// 打开一条线路。大多数倍率变化不换设备也不换格式，只改倍率；否则整个会话重建
    private func apply(_ plan: CameraPlan, revision: Int) -> Bool {
        let device = plan.device

        if let previous = activePlan, previous.device.uniqueID == device.uniqueID,
           previous.format?.format == plan.format?.format,
           previous.format?.depthFormat == plan.format?.depthFormat {
            // 同一个相机、同一个倍率（松手后继续裁当前画面）：保留深度历史，只等下一帧让快门恢复
            if let zoom = plan.zoom, abs(device.videoZoomFactor - zoom) <= 0.0001 {
                activePlan = plan
                dataQueue.sync {
                    self.streamZoom = plan.streamZoom
                    self.frameZoomRevision = revision
                    self.notifyZoomFrame = true
                }
                return true
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.cancelVideoZoomRamp()
                if let zoom = plan.zoom {
                    guard zoom >= device.minAvailableVideoZoomFactor,
                          zoom <= device.maxAvailableVideoZoomFactor else { return false }
                    device.videoZoomFactor = zoom
                }
            } catch { return false }
            if let zoom = plan.zoom, abs(device.videoZoomFactor - zoom) > 0.0001 { return false }
            activePlan = plan
            let timestamp = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
            let focus = dataQueue.sync { () -> CGPoint? in
                let p = self.resetForRoute(revision: revision, newStreamZoom: plan.streamZoom, minimumTimestamp: timestamp)
                self.streamZoom = plan.streamZoom
                return p
            }
            if let focus { focusDevice(at: focus) }
            return true
        }

        // 1) 先单独拆掉旧的。同一个虚拟相机可能服务两颗镜头（比如双摄的 1× 和长焦），
        //    改倍率之前旧的深度设置必须先去掉：开着深度时倍率有限制
        session.beginConfiguration()
        synchronizer?.setDelegate(nil, queue: nil)
        synchronizer = nil
        activePlan = nil
        photoOutput.isDepthDataDeliveryEnabled = false
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        // 2) 建新的
        session.beginConfiguration()
        videoOutput = AVCaptureVideoDataOutput()
        depthOutput = AVCaptureDepthDataOutput()
        // 全程 sRGB：预览、渲染和照片的颜色一致（ImageBridge 按 sRGB 解码）
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        self.device = device

        let pick = plan.format
        do {
            try device.lockForConfiguration()
            if let pick {
                device.activeFormat = pick.format
                if pick.format.supportedColorSpaces.contains(.sRGB) {
                    device.activeColorSpace = .sRGB
                }
                // 虚拟相机靠倍率选镜头，必须在打开深度之前设置：开着深度时不支持的倍率会抛异常
                let zoom = plan.zoom ?? 1
                guard zoom >= device.minAvailableVideoZoomFactor,
                      zoom <= device.maxAvailableVideoZoomFactor else {
                    device.unlockForConfiguration()
                    session.commitConfiguration()
                    return false
                }
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = zoom
                // 主体比这颗镜头的最近对焦距离还近时（比如 4× 长焦拍 30–60 cm），允许虚拟相机临时换到旁边的镜头，
                // 和系统相机一样；锁死在长焦上近处的主体会光学失焦
                if device.isVirtualDevice, device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
                    device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                }
                if let depthFormat = pick.depthFormat {
                    device.activeDepthDataFormat = depthFormat
                }
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            Self.setFaceDrivenFocus(true, on: device)
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch {
            session.commitConfiguration()
            return false
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(videoOutput)

        var useDepth = false
        if let depthFormat = pick?.depthFormat, session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true            // 系统做补洞 + 时域平滑
            depthOutput.alwaysDiscardsLateDepthData = true
            depthOutput.connection(with: .depthData)?.isEnabled = true
            if device.activeDepthDataFormat != depthFormat, (try? device.lockForConfiguration()) != nil {
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
            }
            useDepth = device.activeDepthDataFormat != nil
        }

        var photoReady = false
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoReady = true
        }
        // 所有输出都保持传感器方向、不镜像：画面和深度图逐像素对得上
        for output in [videoOutput, depthOutput] as [AVCaptureOutput] {
            for connection in output.connections {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            }
        }
        if photoReady {
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let dims = LensCatalog.photoDimensions(for: device.activeFormat) {
                photoOutput.maxPhotoDimensions = dims
            }
            photoOutput.isDepthDataDeliveryEnabled = useDepth && photoOutput.isDepthDataDeliverySupported
        }

        if useDepth {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            sync.setDelegate(self, queue: dataQueue)
            synchronizer = sync
        } else {
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }

        // 新的输出开始送帧之前，先登记它们并清掉上一条线路的状态
        let depthOn = useDepth
        let newVideoOutput = videoOutput
        let newSynchronizer = synchronizer
        let focus = dataQueue.sync { () -> CGPoint? in
            self.acceptedVideoOutput = newVideoOutput
            self.acceptedSynchronizer = newSynchronizer
            self.depthEnabled = depthOn
            self.depthExpected = depthOn
            self.hardwareSource = depthOn ? plan.source : .monocular
            let p = self.resetForRoute(revision: revision, newStreamZoom: plan.streamZoom)
            self.streamZoom = plan.streamZoom
            return p
        }

        session.commitConfiguration()
        guard pick == nil || device.activeFormat == pick?.format else { return false }
        if useDepth, let zoom = plan.zoom {
            let ranges = LensCatalog.depthZoomRanges(for: device.activeFormat)
            guard (!device.isVirtualDevice && ranges.isEmpty)
                || ZoomScale.supportsDepth(at: zoom, ranges: ranges) else { return false }
        }
        // commit 可能让设备重新协商：只恢复已经验证过的倍率，还是不对就放弃这条线路
        if let zoom = plan.zoom, abs(device.videoZoomFactor - zoom) > 0.0001 {
            guard zoom >= device.minAvailableVideoZoomFactor,
                  zoom <= device.maxAvailableVideoZoomFactor,
                  (try? device.lockForConfiguration()) != nil else { return false }
            device.videoZoomFactor = zoom
            device.unlockForConfiguration()
            guard abs(device.videoZoomFactor - zoom) <= 0.0001 else { return false }
            let timestamp = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
            dataQueue.sync { self.minimumFrameTimestamp = timestamp }
        }
        activePlan = plan
        if useDepth { capDepthFrameRate(device) }
        if let focus { focusDevice(at: focus) }
        // 没有深度硬件的镜头用 AI 深度：现在加载（或下载）模型
        if !depthOn { DepthModelStore.shared.prepare() }
        return true
    }

    /// 深度帧率默认可能比视频低（甚至是 0）：明确设成 30 fps（限制在深度格式支持的范围内）。
    /// 视频或深度格式一变它就会被重置，所以每次重建后都要设
    private func capDepthFrameRate(_ device: AVCaptureDevice) {
        guard let depthFormat = device.activeDepthDataFormat,
              let range = depthFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }),
              range.maxFrameRate > 0, (try? device.lockForConfiguration()) != nil else { return }
        device.activeDepthDataMinFrameDuration = CMTimeMinimum(
            CMTimeMaximum(CMTime(value: 1, timescale: 30), range.minFrameDuration), range.maxFrameDuration)
        device.unlockForConfiguration()
    }

    /// dataQueue：换了相机或相机倍率。清掉跟旧画面绑定的所有状态，新画面准备好之前保留屏幕上的最后一帧。
    /// 对焦点换算到新相机的画面里；还在画面内就返回它（让新相机的镜头也对过去），否则回到中心
    private func resetForRoute(revision: Int, newStreamZoom: CGFloat, minimumTimestamp: CMTime = .invalid) -> CGPoint? {
        resetDepthHistory()
        lastFrameUsedHardwareDepth = nil
        cachedDepth = nil
        cachedDepthTime = .invalid
        frameZoomRevision = revision
        minimumFrameTimestamp = minimumTimestamp
        notifyZoomFrame = true
        routeReady = false
        routeFrames = 0
        reportedSource = .starting

        let ratio = newStreamZoom / max(streamZoom, 0.01)
        paramLock.lock()
        let old = _focusPoint
        var p = CGPoint(x: 0.5 + (old.x - 0.5) * ratio, y: 0.5 + (old.y - 0.5) * ratio)
        let isCenter = abs(old.x - 0.5) < 0.001 && abs(old.y - 0.5) < 0.001
        let inside = p.x > 0.03 && p.x < 0.97 && p.y > 0.03 && p.y < 0.97
        if !inside { p = CGPoint(x: 0.5, y: 0.5) }
        _focusPoint = p
        focusResetPending = false
        paramLock.unlock()
        return inside && !isCenter ? p : nil
    }

    /// dataQueue：深度、对焦、时间平滑的历史都和具体的相机画面绑定
    private func resetDepthHistory() {
        temporal.reset()
        focusStabilizer = FocusStabilizer()
        lastMonoMap = nil
        monoRange = nil
        monoCounter = 0
        smoothedNear = nil
        smoothedFar = nil
        lastFrameTime = nil
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    /// 临时提示（2 秒后恢复正常的状态行）
    private func showStatusMessage(_ text: String) {
        statusText = text
        statusHoldUntil = CACurrentMediaTime() + 2
    }
    private var statusHoldUntil: CFTimeInterval = 0

    // MARK: - 每一帧（dataQueue）

    private func processFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !minimumFrameTimestamp.isValid || CMTimeCompare(timestamp, minimumFrameTimestamp) >= 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t0 = CACurrentMediaTime()

        // 1. 硬件深度。有的相机深度帧比视频少：只在同一条线路里短暂沿用上一张
        var hardware: FloatMap?
        var relative = false
        if let depthData {
            hardware = ImageBridge.disparityMap(from: depthData)
            relative = depthData.depthDataAccuracy == .relative
            cachedDepth = hardware
            cachedDepthRelative = relative
            cachedDepthTime = timestamp
        } else if depthEnabled, let cached = cachedDepth, cachedDepthTime.isValid {
            // 这条线路本来就有深度：晚到时用上一张撑过去，而不是切到 AI 深度再切回来（每次切换都会清空历史）
            let maxAge = depthExpected ? 0.5 : 0.1
            let age = CMTimeGetSeconds(CMTimeSubtract(timestamp, cachedDepthTime))
            if age.isFinite && age >= 0 && age <= maxAge {
                hardware = cached
                relative = cachedDepthRelative
            }
        }
        let hardwareFrame = hardware != nil
        if let previous = lastFrameUsedHardwareDepth, previous != hardwareFrame { resetDepthHistory() }
        lastFrameUsedHardwareDepth = hardwareFrame

        // 2. 这颗镜头没有深度硬件（0.5× 超广角）：AI 单目深度，每两帧估计一次（约 30 ms）
        var disparity = hardware
        if disparity == nil, !depthExpected, let estimator = DepthModelStore.shared.estimator {
            monoCounter &+= 1
            if lastMonoMap == nil || monoCounter % 2 == 0,
               let result = estimator.estimate(pixelBuffer, previous: monoRange) {
                lastMonoMap = result.map
                monoRange = result.range
            }
            if let map = lastMonoMap {
                disparity = map
                relative = true
            }
        }
        let source: DepthSource = hardwareFrame ? hardwareSource : (disparity != nil ? .monocular : .unavailable)

        // 3. 换相机后：新画面值得显示之前（曝光、白平衡稳定几帧，深度到了，最多 0.8 秒）保留屏幕上的最后一帧
        let now = CACurrentMediaTime()
        var firstRouteFrame = false
        if !routeReady {
            routeFrames += 1
            if routeFrames == 1 { routeStart = now }
            routeReady = (routeFrames >= 3 && disparity != nil) || now - routeStart > 0.8
            guard routeReady else { return }
            firstRouteFrame = true
        }

        // 4. 数码变焦：从相机画面中间裁到刻度盘的倍率
        var zoomNow = previewZoom
        if firstRouteFrame, lastPublishedZoom > zoomNow * 1.01 {
            // 屏幕上那一帧只能继续放大、不能变广：往小变焦时，从那一帧的倍率在新画面上平滑过去
            paramLock.lock()
            glideFrom = lastPublishedZoom
            glideStart = now
            zoomNow = glideValueLocked(at: now)
            paramLock.unlock()
            DispatchQueue.main.async { self.markGliding() }
        }
        let crop = max(1, zoomNow / max(streamZoom, 0.01))
        let frameZoom = streamZoom * crop
        let image = ImageBridge.planarImage(from: pixelBuffer, longSide: previewLongSide, crop: crop)
        lastFrameCrop = crop

        guard let fullDisparity = disparity else {
            // 没有深度（AI 模型还没准备好）：直接显示原图
            publish(ImageBridge.uiImage(from: image, orientation: previewOrientation), zoom: frameZoom, crop: crop,
                    firstRouteFrame: firstRouteFrame, source: source, text: noDepthText())
            return
        }
        let map = fullDisparity.centerCropped(by: Float(crop))

        // 5. 对焦点（相机画面坐标）换到裁出来的画面里；已经裁到画面外了就回到中心
        paramLock.lock()
        var p = _focusPoint
        var resetFocus = focusResetPending
        focusResetPending = false
        let c = CGFloat(crop)
        var leftFrame = false
        if abs(p.x - 0.5) * c > 0.5 || abs(p.y - 0.5) * c > 0.5 {
            p = CGPoint(x: 0.5, y: 0.5)
            _focusPoint = p
            resetFocus = true
            leftFrame = true
        }
        paramLock.unlock()
        if leftFrame { sessionQueue.async { self.focusDeviceAtCenter() } }
        let fx = Float(0.5 + (p.x - 0.5) * c), fy = Float(0.5 + (p.y - 0.5) * c)
        if resetFocus { focusStabilizer.reset() }
        let dt = lastFrameTime.map { min(0.2, t0 - $0) } ?? (1.0 / 30)
        lastFrameTime = t0
        // 对焦稳定器：主体晃出那个点时不会立刻跳焦；换焦是平滑拉焦
        let focusD = focusStabilizer.update(map: map, nx: fx, ny: fy, dt: dt)

        // 6. 主体太近：和系统相机一样关掉景深（0.15 秒淡出 / 淡入，进出留 12% 回差）。只有绝对深度能换算成米
        let distance = relative ? Float.nan : 1 / max(focusD, 1e-3)
        let wasTooClose = tooCloseState
        if relative {
            tooCloseState = false
        } else if tooCloseState {
            if distance > minSubjectDistance * 1.12 { tooCloseState = false }
        } else if distance < minSubjectDistance {
            tooCloseState = true
        }
        if tooCloseState != wasTooClose {
            let v = tooCloseState
            DispatchQueue.main.async { self.isTooClose = v }
        }
        effectAmount += ((tooCloseState ? 0 : 1) - effectAmount) * Float(1 - exp(-dt / 0.15))

        // 7. 相对深度（双摄视差 / AI 深度）：相对距离的分母用 max(d_f, 0.25 × (近端 − 远端))
        var relativeScale: Float?
        if relative, let range = map.percentiles(0.05, 0.95) {
            let near = smoothedNear.map { $0 + (range.high - $0) * 0.15 } ?? range.high
            let far = smoothedFar.map { $0 + (range.low - $0) * 0.15 } ?? range.low
            smoothedNear = near
            smoothedFar = far
            relativeScale = max(focusD, 0.25 * (near - far))
        }

        // 8. 双分辨率渲染：模糊在 1/blurDownscale 分辨率上算（含深度对齐），清晰部分用全分辨率原图
        var lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, model: lensModel,
                                  focalLength35mm: virtualFocalLength, focusTolerance: focusTolerance,
                                  relativeScale: relativeScale)
        lens.blurK *= effectAmount
        lens.maxBlurFraction *= effectAmount
        let lowSide = max(160, image.longSide / max(1, blurDownscale))
        let out: PlanarImage
        if effectAmount < 0.02 {
            out = image
        } else {
            let hint = keepSubjectSharp ? SubjectHint(point: (fx, fy)) : nil
            out = renderer.renderDetailPreserving(full: image, disparity: map, lens: lens,
                                                  lowLongSide: lowSide, quality: .preview, refinePasses: 1,
                                                  temporal: temporal, subject: hint)
        }
        let ui = ImageBridge.uiImage(from: out, orientation: previewOrientation)

        // 统计帧耗时
        let ms = (CACurrentMediaTime() - t0) * 1000
        frameTimes.append(ms)
        if frameTimes.count > 20 { frameTimes.removeFirst() }
        let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let focusText = relative ? source.label : String(format: "对焦 %.2f m", distance)
        let text = String(format: "%@× · %d×%d · %.0f ms/帧 · ", Self.zoomText(frameZoom), image.width, image.height, avg)
            + focusText
        publish(ui, zoom: frameZoom, crop: crop, firstRouteFrame: firstRouteFrame, source: source, text: text)
    }

    private func noDepthText() -> String {
        switch DepthModelStore.shared.status {
        case .downloading(let p): return String(format: "正在下载 AI 深度模型 %.0f%%…", p * 100)
        case .compiling: return "AI 深度模型准备中…"
        case .failed(let message): return message
        default: return depthEnabled ? "等待深度数据…" : "没有深度数据"
        }
    }

    static func zoomText(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        return abs(r - r.rounded()) < 0.01 ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// dataQueue → 主线程：把这一帧放到屏幕上
    private func publish(_ ui: UIImage?, zoom: CGFloat, crop: CGFloat, firstRouteFrame: Bool,
                         source: DepthSource, text: String) {
        lastPublishedZoom = zoom
        let sourceChanged = reportedSource != source
        reportedSource = source
        let notify = notifyZoomFrame
        notifyZoomFrame = false
        let revision = frameZoomRevision
        DispatchQueue.main.async {
            if firstRouteFrame, let old = self.previewImage {
                // 上一条线路的最后一帧淡出（0.2 秒）
                self.transitionStart = CACurrentMediaTime()
                self.transitionImage = old
                self.transitionImageZoom = self.previewFrameZoom
                self.routeTransitionID &+= 1
                self.transitionToken &+= 1
                let token = self.transitionToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.transitionToken == token { self.transitionImage = nil }
                }
            }
            self.previewImage = ui
            self.previewFrameZoom = zoom
            self.displayedCrop = crop
            if sourceChanged, self.zoomRevision == revision { self.depthSourceLabel = source.label }
            if CACurrentMediaTime() >= self.statusHoldUntil { self.statusText = text }
            if notify {
                self.latestFrameRevision = revision
                self.finishZoomIfReady()
            }
        }
    }
}

// MARK: - 视频 + 深度同步回调

extension DepthCameraController: AVCaptureDataOutputSynchronizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    public func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                       didOutput collection: AVCaptureSynchronizedDataCollection) {
        // 已经被替换掉的会话排队送来的帧不要
        guard synchronizer === acceptedSynchronizer,
              let video = synchronizer.dataOutputs.first(where: { $0 is AVCaptureVideoDataOutput }),
              let syncedVideo = collection.synchronizedData(for: video) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped else { return }
        var depthData: AVDepthData?
        if let depth = synchronizer.dataOutputs.first(where: { $0 is AVCaptureDepthDataOutput }),
           let syncedDepth = collection.synchronizedData(for: depth) as? AVCaptureSynchronizedDepthData,
           !syncedDepth.depthDataWasDropped {
            depthData = syncedDepth.depthData
        }
        processFrame(syncedVideo.sampleBuffer, depthData: depthData)
    }

    /// 没有深度硬件的线路（0.5× 超广角）：只有视频
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard output === acceptedVideoOutput, acceptedSynchronizer == nil else { return }
        processFrame(sampleBuffer, depthData: nil)
    }
}

// MARK: - 拍照回调

extension DepthCameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        let fNumber = self.fNumber, longSide = photoLongSide
        paramLock.lock()
        let streamFocus = _focusPoint
        paramLock.unlock()
        guard error == nil, let cgFull = photo.cgImageRepresentation() else {
            DispatchQueue.main.async {
                self.showStatusMessage("拍照失败：\(error?.localizedDescription ?? "没有图像数据")")
                self.isCapturing = false
            }
            return
        }
        // 和预览一样的裁切（两个深度倍率点之间相机停在低的那个点）
        let (crop, monoRoute) = dataQueue.sync { (self.lastFrameCrop, !self.depthExpected) }
        let depth = photo.depthData
        let orientationRaw = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = ImageBridge.uiOrientation(CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up)
        let c = max(crop, 1)
        let focus = CGPoint(x: min(max(0.5 + (streamFocus.x - 0.5) * c, 0), 1),
                            y: min(max(0.5 + (streamFocus.y - 0.5) * c, 0), 1))

        photoQueue.async {
            let cg = ImageBridge.centerCrop(cgFull, by: c)
            let image = ImageBridge.planarImage(from: cg, maxLongSide: longSide)
            var disparity: FloatMap?
            var relative = false
            if let depth {
                // 只补洞；和图像的对齐在编辑器里按渲染分辨率做
                disparity = DepthRefiner.fillInvalid(ImageBridge.disparityMap(from: depth).centerCropped(by: Float(c)))
                relative = depth.depthDataAccuracy == .relative
            } else if monoRoute, let estimator = DepthModelStore.shared.estimator, let mono = estimator.estimate(cgImage: cg) {
                // 超广角：在裁好的照片上重新估计一次 AI 深度
                disparity = mono
                relative = true
            }
            // 没有深度（光线太暗、AI 模型没准备好）：整张图当作在对焦面上
            let hasDepth = disparity != nil
            let captured = CapturedDepthPhoto(image: image,
                                              disparity: disparity ?? FloatMap(width: 64, height: 48, repeating: 1),
                                              orientation: orientation, focusPoint: focus, fNumber: fNumber,
                                              isRelativeDepth: relative)
            DispatchQueue.main.async {
                self.lastPhoto = captured
                self.isCapturing = false
                if !hasDepth { self.showStatusMessage("这张照片没有深度数据") }
            }
        }
    }
}
#endif
