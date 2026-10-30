import SwiftUI
import UIKit
import QuartzCore
import BokehCamera

/// 取景界面：实时虚化预览 + 焦段调节 + 景深（ƒ）滑块 + 点按对焦 + 快门
/// 焦段调节的界面和交互直接复用 DepthBokehCamera 2 的 ContinuousZoomControl（13–100mm）：
/// 点数字跳到对应焦段，左右拖动或长按展开刻度，松手 ±5% 内吸附到数字，约 1 秒收起
struct ContentView: View {
    @StateObject private var camera = DepthCameraController()
    @State private var sliderValue: Double = ApertureScale.position(for: 2.8)
    @State private var focusMarker: CGPoint?
    @State private var editingPhoto: CapturedDepthPhoto?
    /// 分割开关（看效果用）：关掉以后只按深度虚化
    @State private var segmentationOn = true
    /// 锁定对焦：点一下对焦以后对焦距离固定住，不再跟着画面变
    @State private var focusLocked = false

    private var fNumber: Float { ApertureScale.fNumber(at: sliderValue) }

    var body: some View {
        VStack(spacing: 14) {
            Text(camera.statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 16)

            preview
                .overlay(alignment: .top) {
                    if camera.isTooClose {
                        Text("离远一点")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: camera.isTooClose)

            ContinuousZoomControl(zoomFactor: camera.zoomFactor, range: camera.zoomRange, stops: camera.zoomStops,
                                  isEnabled: !camera.isCapturing && !camera.isSwitchingCamera && !camera.isFrontCamera,
                                  onZoomChange: { camera.setZoomFactor($0) },
                                  onZoomCommit: { camera.commitZoom() })
            .padding(.horizontal, 16)

            VStack(spacing: 6) {
                Text("景深")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "ƒ%.1f", fNumber))
                    .font(.title3.monospacedDigit())
                Slider(value: $sliderValue, in: 0...1)
                    .tint(.yellow)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 28) {
                // 分割开关（看效果用，和右侧按钮等宽，让快门保持居中）：黄色 = 开，划掉 = 关（只按深度虚化）
                Button {
                    segmentationOn.toggle()
                    camera.useSegmentation = segmentationOn
                } label: {
                    Text("分割")
                        .font(.caption.weight(.semibold))
                        .strikethrough(!segmentationOn)
                        .foregroundStyle(segmentationOn ? Color.black : Color.white.opacity(0.7))
                        .frame(width: 48, height: 48)
                        .background(segmentationOn ? Color.yellow : Color.white.opacity(0.15), in: Circle())
                }
                .accessibilityLabel(segmentationOn ? "关闭分割，只按深度虚化" : "打开分割")

                Button {
                    camera.capturePhoto()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white).padding(7))
                        .frame(width: 72, height: 72)
                        .opacity(camera.isCapturing || camera.isZoomSettling ? 0.4 : 1)
                }
                .disabled(camera.isCapturing || camera.isZoomSettling)
                .accessibilityLabel("拍摄")

                Button {
                    focusMarker = nil
                    camera.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.15), in: Circle())
                        .opacity(canSwitchCamera ? 1 : 0.4)
                }
                .disabled(!canSwitchCamera)
                .accessibilityLabel(camera.isFrontCamera ? "切换到后置摄像头" : "切换到前置摄像头")
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            camera.fNumber = fNumber
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: sliderValue) { _, _ in camera.fNumber = fNumber }
        .onReceive(camera.$lastPhoto) { photo in
            guard let photo else { return }
            // 编辑器打开期间暂停预览处理（不和编辑器抢 CPU，也不让手机一直发热），照片交给编辑器后释放
            camera.setPreviewPaused(true)
            editingPhoto = photo
            DispatchQueue.main.async { camera.clearLastPhoto() }   // 不能在 lastPhoto 的发布回调里直接改它
        }
        .fullScreenCover(item: $editingPhoto, onDismiss: { camera.setPreviewPaused(false) }) { photo in
            PhotoEditorView(photo: photo)
        }
    }

    private var canSwitchCamera: Bool {
        camera.canSwitchCameras && !camera.isCapturing && !camera.isZoomSettling && !camera.isSwitchingCamera
    }

    /// 预览：GPU 渲染好的帧直接画在 Metal 视图上（MetalPreviewView）。每一帧按它渲染时的倍率出图，
    /// 显示时补上它和此刻倍率之间的差（拖动刻度时跟手、点数字时 0.3 秒平滑变焦、换相机期间最后一帧继续放大），
    /// 换相机时上一帧 0.2 秒淡出
    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if let display = camera.display {
                    MetalPreviewView(display: display)
                }
                if !camera.hasPreviewFrame {
                    ProgressView()
                }
                if let m = focusMarker {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 70, height: 70)
                        .position(m)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                handleTap(at: value.location, in: geo.size)
            })
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                // 锁定对焦：打开后点一下对焦，对焦距离就固定住（主体走开、手机移动、重新构图都不变）
                Button {
                    focusLocked.toggle()
                    camera.focusLocked = focusLocked
                } label: {
                    Label(focusLocked ? "对焦已锁定" : "锁定对焦", systemImage: focusLocked ? "lock.fill" : "lock.open")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(focusLocked ? Color.yellow : Color.black.opacity(0.45), in: Capsule())
                        .foregroundStyle(focusLocked ? Color.black : Color.white.opacity(0.9))
                }
                .accessibilityLabel(focusLocked ? "解除对焦锁定" : "锁定对焦")
                // 录调试数据：出问题时按一下，录 5 秒原始数据（相机画面、深度、参数），录好可以 AirDrop 到 Mac
                Button {
                    camera.startDebugRecording()
                } label: {
                    Label(camera.isDebugRecording ? "录制中" : "录调试数据", systemImage: "record.circle")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(camera.isDebugRecording ? Color.red : Color.black.opacity(0.45), in: Capsule())
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .disabled(camera.isDebugRecording)
                if !camera.debugRecordingStatus.isEmpty {
                    Text(camera.debugRecordingStatus)
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(Color.white)
                }
                if let zip = camera.debugRecordingZip {
                    ShareLink(item: zip) {
                        Label("发送数据", systemImage: "square.and.arrow.up")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.yellow, in: Capsule())
                            .foregroundStyle(Color.black)
                    }
                }
            }
            .padding(10)
        }
        .overlay(alignment: .topLeading) {
            if !camera.depthSourceLabel.isEmpty {
                Text(camera.depthSourceLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 屏幕点击位置 -> 屏幕上那一帧（传感器原始方向）里的归一化坐标（和显示用同一个变换，含补上的放大）
    private func handleTap(at location: CGPoint, in container: CGSize) {
        guard let raw = camera.display?.framePoint(fromView: location, viewSize: container) else { return }
        camera.focus(atRawPoint: raw)
        withAnimation(.easeOut(duration: 0.15)) { focusMarker = location }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { if focusMarker == location { focusMarker = nil } }
        }
    }
}

/// ƒ 值滑块：用对数刻度，ƒ1.4 到 ƒ16
enum ApertureScale {
    static let minF: Double = 1.4, maxF: Double = 16
    static func fNumber(at t: Double) -> Float { Float(minF * pow(maxF / minF, t)) }
    static func position(for f: Double) -> Double { log(f / minF) / log(maxF / minF) }
}

/// scaledToFit 时图片在容器里的实际位置
enum ImageGeometry {
    static func normalizedPoint(_ location: CGPoint, imageSize: CGSize, container: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        let x0 = (container.width - w) / 2, y0 = (container.height - h) / 2
        let u = (location.x - x0) / w, v = (location.y - y0) / h
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}
