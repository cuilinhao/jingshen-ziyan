#if os(iOS)
import AVFoundation
import Combine
import UIKit
import BokehCore

/// 拍下来的一张带深度的照片（已降采样、深度已对齐），可以反复改光圈、改对焦点
public struct CapturedDepthPhoto: Identifiable {
    public let id = UUID()
    /// 线性光图像（传感器方向，未旋转）
    public let image: PlanarImage
    /// 原始视差图（已补洞，分辨率低于 image；渲染时再和图像对齐）
    public let disparity: FloatMap
    /// 显示方向
    public let orientation: UIImage.Orientation
    /// 拍照时的对焦点（原图归一化坐标）
    public let focusPoint: CGPoint
    /// 拍照时的光圈
    public let fNumber: Float
}

/// 实时景深相机：
///  - 用 AVCaptureDataOutputSynchronizer 同步拿到「视频帧 + 深度图」
///  - 每帧在后台线程用纯 Swift 的 BokehRenderer 渲染虚化预览
///  - 拍照时连同深度一起拿到，交给 PhotoBokehEditor 做全分辨率渲染
public final class DepthCameraController: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - 给 UI 的状态（只在主线程修改）
    @Published public private(set) var previewImage: UIImage?
    @Published public private(set) var statusText = "正在启动相机…"
    @Published public private(set) var lastPhoto: CapturedDepthPhoto?
    @Published public private(set) var isCapturing = false

    /// 实时预览输出的长边（像素）。清晰部分按这个分辨率显示
    public var previewLongSide = 1440
    /// 模糊部分在几分之一的分辨率上计算（3 = 1440 → 480），越大越快
    public var blurDownscale = 3
    /// 对焦面前后的全清晰区（对焦距离的比例）
    public var focusTolerance: Float = 0.08
    /// 模拟镜头的 35mm 等效焦距，决定同样 ƒ 值下的虚化强度
    public var virtualFocalLength: Float = 52
    /// 拍照后给编辑器的图像长边
    public var photoLongSide = 3024

    // MARK: - 渲染参数（UI 线程写、数据线程读，用锁保护）
    private let paramLock = NSLock()
    private var _fNumber: Float = 2.8
    private var _focusPoint = CGPoint(x: 0.5, y: 0.5)

    /// 模拟光圈值
    public var fNumber: Float {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _fNumber }
        set { paramLock.lock(); _fNumber = newValue; paramLock.unlock() }
    }

    /// 对焦点（原始传感器方向的归一化坐标）
    public var focusPoint: CGPoint {
        get { paramLock.lock(); defer { paramLock.unlock() }; return _focusPoint }
        set { paramLock.lock(); _focusPoint = newValue; paramLock.unlock() }
    }

    /// 预览帧的显示方向：后置摄像头竖屏时原始帧需要顺时针转 90°
    public let previewOrientation: UIImage.Orientation = .right

    // MARK: - AVFoundation
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "depthbokeh.session")
    private let dataQueue = DispatchQueue(label: "depthbokeh.data", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "depthbokeh.photo", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?

    // 只在 dataQueue 上访问
    private let renderer = BokehRenderer()
    private var lastDisparity: FloatMap?
    private var focusStabilizer = FocusStabilizer()
    /// 跨帧稳定深度边缘和焦外光斑（静止时不闪，运动时不拖影）
    private let temporal = TemporalState()
    private var focusResetPending = false
    private var lastFrameTime: CFTimeInterval?
    private var frameTimes: [Double] = []

    public override init() { super.init() }

    // MARK: - 启停

    public func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureAndRun() }
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

    /// 点按对焦。point 是原始传感器方向的归一化坐标（用 ImageBridge.rawPoint 从屏幕坐标换算）
    public func focus(atRawPoint point: CGPoint) {
        paramLock.lock(); _focusPoint = point; focusResetPending = true; paramLock.unlock()
        // 让真实镜头也对到这里，否则「清晰区域」本身可能是光学失焦的
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = point
                    d.focusMode = .autoFocus
                }
                if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = point
                    d.exposureMode = .autoExpose
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - 拍照

    public func capturePhoto() {
        DispatchQueue.main.async { self.isCapturing = true }
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
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

    // MARK: - 会话配置

    /// 优先 LiDAR，其次双摄（广角+超广角 / 广角+长焦），它们都能输出深度
    private static func findDepthCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let d = discovery.devices.first(where: { $0.deviceType == type }) { return d }
        }
        return nil
    }

    private func configureAndRun() {
        if !session.inputs.isEmpty {
            if !session.isRunning { session.startRunning() }
            return
        }
        guard let device = Self.findDepthCamera() else {
            setStatus("这台设备没有可输出深度的后置摄像头（需要双摄或 LiDAR）")
            return
        }
        self.device = device

        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            setStatus("无法打开摄像头：\(error.localizedDescription)")
            return
        }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

        // 当前格式不支持深度时，手动挑一个支持深度的格式
        if device.activeFormat.supportedDepthDataFormats.isEmpty,
           let format = device.formats.last(where: {
               !$0.supportedDepthDataFormats.isEmpty
                   && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 2016
           }) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {}
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        depthOutput.isFilteringEnabled = true            // 系统做补洞 + 时域平滑
        depthOutput.alwaysDiscardsLateDepthData = true
        if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
        depthOutput.connection(with: .depthData)?.isEnabled = true

        // 选分辨率最高的深度格式
        let depthFormats = device.activeFormat.supportedDepthDataFormats
        let wanted: Set<FourCharCode> = [
            kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DisparityFloat32,
            kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DepthFloat32,
        ]
        if let best = depthFormats
            .filter({ wanted.contains(CMFormatDescriptionGetMediaSubType($0.formatDescription)) })
            .max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                    < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) {
            do {
                try device.lockForConfiguration()
                device.activeDepthDataFormat = best
                device.unlockForConfiguration()
            } catch {}
        }
        session.commitConfiguration()

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: dataQueue)
        synchronizer = sync

        session.startRunning()
        setStatus(depthFormats.isEmpty ? "当前格式没有深度数据" : "")
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    // MARK: - 每一帧

    private func processFrame(_ pixelBuffer: CVPixelBuffer, disparity raw: FloatMap?) {
        let t0 = CACurrentMediaTime()
        let image = ImageBridge.planarImage(from: pixelBuffer, longSide: previewLongSide)

        guard let raw else {
            // 还没有深度数据：直接显示原图
            let ui = ImageBridge.uiImage(from: image, orientation: previewOrientation)
            DispatchQueue.main.async { self.previewImage = ui }
            return
        }

        // 1. 对焦视差：点按位置的中位数 + 对焦稳定器（主体晃出那个点时不会立刻跳焦）+ 平滑拉焦
        paramLock.lock()
        let p = _focusPoint
        let resetFocus = focusResetPending
        focusResetPending = false
        paramLock.unlock()
        if resetFocus { focusStabilizer.reset() }
        let dt = lastFrameTime.map { min(0.2, t0 - $0) } ?? (1.0 / 30)
        lastFrameTime = t0
        let focusD = focusStabilizer.update(map: raw, nx: Float(p.x), ny: Float(p.y), dt: dt)

        // 2. 双分辨率渲染：模糊在 1/blurDownscale 分辨率上算（含深度对齐），清晰部分用全分辨率原图
        let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD,
                                  focalLength35mm: virtualFocalLength, focusTolerance: focusTolerance)
        let lowSide = max(160, image.longSide / max(1, blurDownscale))
        let out = renderer.renderDetailPreserving(full: image, disparity: raw, lens: lens,
                                                  lowLongSide: lowSide, quality: .preview, refinePasses: 1,
                                                  temporal: temporal)
        let ui = ImageBridge.uiImage(from: out, orientation: previewOrientation)

        // 统计帧耗时
        let ms = (CACurrentMediaTime() - t0) * 1000
        frameTimes.append(ms)
        if frameTimes.count > 20 { frameTimes.removeFirst() }
        let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let text = String(format: "%d×%d（模糊 %d）· %.0f ms/帧 · 对焦 %.2f m",
                          image.width, image.height, lowSide, avg, 1 / focusD)
        DispatchQueue.main.async {
            self.previewImage = ui
            self.statusText = text
        }
    }
}

// MARK: - 视频 + 深度同步回调

extension DepthCameraController: AVCaptureDataOutputSynchronizerDelegate {
    public func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                       didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer) else { return }

        if let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepth.depthDataWasDropped {
            lastDisparity = ImageBridge.disparityMap(from: syncedDepth.depthData)
        }
        // 深度帧率可能比视频低，缺的那帧沿用上一张深度图
        processFrame(pixelBuffer, disparity: lastDisparity)
    }
}

// MARK: - 拍照回调

extension DepthCameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                            error: Error?) {
        let fNumber = self.fNumber, focus = self.focusPoint, longSide = photoLongSide
        guard error == nil, let cg = photo.cgImageRepresentation() else {
            setStatus("拍照失败：\(error?.localizedDescription ?? "没有图像数据")")
            DispatchQueue.main.async { self.isCapturing = false }
            return
        }
        let depth = photo.depthData
        let orientationRaw = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = ImageBridge.uiOrientation(CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up)

        photoQueue.async {
            let image = ImageBridge.planarImage(from: cg, maxLongSide: longSide)
            let disparity: FloatMap
            if let depth {
                // 只补洞；和图像的对齐在编辑器里按渲染分辨率做
                disparity = DepthRefiner.fillInvalid(ImageBridge.disparityMap(from: depth))
            } else {
                // 没有深度（比如光线太暗、距离太近）：整张图当作在对焦面上
                disparity = FloatMap(width: image.width, height: image.height, repeating: 1)
            }
            let captured = CapturedDepthPhoto(image: image, disparity: disparity, orientation: orientation,
                                              focusPoint: focus, fNumber: fNumber)
            DispatchQueue.main.async {
                self.lastPhoto = captured
                self.isCapturing = false
                if depth == nil { self.statusText = "这张照片没有深度数据" }
            }
        }
    }
}
#endif
