import SwiftUI
import UIKit
import BokehCamera

/// 取景界面：实时虚化预览 + 景深（ƒ）滑块 + 点按对焦 + 快门
struct ContentView: View {
    @StateObject private var camera = DepthCameraController()
    @State private var sliderValue: Double = ApertureScale.position(for: 2.8)
    @State private var focusMarker: CGPoint?
    @State private var editingPhoto: CapturedDepthPhoto?

    private var fNumber: Float { ApertureScale.fNumber(at: sliderValue) }

    var body: some View {
        VStack(spacing: 14) {
            Text(camera.statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 16)

            preview

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

            Button {
                camera.capturePhoto()
            } label: {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .background(Circle().fill(.white).padding(7))
                    .frame(width: 72, height: 72)
                    .opacity(camera.isCapturing ? 0.4 : 1)
            }
            .disabled(camera.isCapturing)
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
            if let photo { editingPhoto = photo }
        }
        .fullScreenCover(item: $editingPhoto) { photo in
            PhotoEditorView(photo: photo)
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if let img = camera.previewImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
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
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                handleTap(at: value.location, in: geo.size)
            })
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    /// 屏幕点击位置 -> 图片内归一化坐标 -> 传感器原始方向坐标
    private func handleTap(at location: CGPoint, in container: CGSize) {
        guard let img = camera.previewImage else { return }
        guard let p = ImageGeometry.normalizedPoint(location, imageSize: img.size, container: container) else { return }
        let raw = ImageBridge.rawPoint(fromDisplayed: p, orientation: img.imageOrientation)
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
