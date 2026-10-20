import SwiftUI
import UIKit
import BokehCamera

/// 拍完之后调景深：拖滑块改 ƒ 值、点照片换对焦点，和系统相册的「景深」编辑一样
struct PhotoEditorView: View {
    @StateObject private var editor: PhotoBokehEditor
    @State private var sliderValue: Double
    @State private var focus: CGPoint
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(photo: CapturedDepthPhoto) {
        _editor = StateObject(wrappedValue: PhotoBokehEditor(photo: photo))
        _sliderValue = State(initialValue: ApertureScale.position(for: Double(photo.fNumber)))
        _focus = State(initialValue: photo.focusPoint)
    }

    private var fNumber: Float { ApertureScale.fNumber(at: sliderValue) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                if editor.isRendering { ProgressView().controlSize(.small) }
                Text(String(format: "%.0f ms · 对焦 %.2f m", editor.renderMilliseconds, editor.focusDistanceMeters))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(saved ? "已保存" : "保存") {
                    if let img = editor.image {
                        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                        saved = true
                    }
                }
                .disabled(editor.image == nil || saved)
            }
            .padding(.horizontal)

            GeometryReader { geo in
                ZStack {
                    if let img = editor.image {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard let img = editor.image,
                          let p = ImageGeometry.normalizedPoint(value.location, imageSize: img.size, container: geo.size)
                    else { return }
                    focus = ImageBridge.rawPoint(fromDisplayed: p, orientation: img.imageOrientation)
                    saved = false
                    editor.request(fNumber: fNumber, focus: focus)
                })
            }

            VStack(spacing: 6) {
                Text(String(format: "ƒ%.1f", fNumber)).font(.title3.monospacedDigit())
                Slider(value: $sliderValue, in: 0...1)
                    .tint(.yellow)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(Color.black.ignoresSafeArea())
        .onChange(of: sliderValue) { _, _ in
            saved = false
            editor.request(fNumber: fNumber, focus: focus)
        }
    }
}
