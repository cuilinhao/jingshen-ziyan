import SwiftUI
import UIKit
import BokehCamera

/// 拍完之后（或从相册导入以后）调景深：点照片换清晰的主体，拨下面的光圈刻度改 ƒ 值，和系统相册的「景深」编辑一样。
///
/// 布局按窗口的安全区自己留边（`screenInsets`）：从相册导入后弹出的这一页，SwiftUI 报的安全区是 0，
/// 「关闭 / 保存」压在状态栏上，ƒ 滑块落进底部横条的手势区——左右拖就是系统的「切换 App」手势，整个界面被缩小。
/// 现在控件都在底部横条上方，底边的系统手势也推迟（`defersSystemGestures`：要再划一次才生效）。
struct PhotoEditorView: View {
    @StateObject private var editor: PhotoBokehEditor
    @State private var fNumber: Float
    @State private var stopIndex: Int
    /// 对焦点（原图归一化坐标，交给编辑器）
    @State private var focus: CGPoint
    /// 对焦框（显示出来的图片里的归一化坐标）：一直停在当前的对焦点上；nil = 还没有图
    @State private var marker: CGPoint?
    /// 每点一次加 1：对焦框重新「弹」一下
    @State private var markerID = 0
    /// 点完 1.5 秒后对焦框变淡（不消失），不挡着看虚化效果
    @State private var markerDimmed = false
    @State private var hasTapped = false
    /// 光圈拨到「关闭」以前的那一档（关闭时点照片，回到这一档）
    @State private var lastOnIndex: Int
    @State private var saved = false
    @State private var savedToast = false
    @State private var noticeShown = false
    @Environment(\.dismiss) private var dismiss

    init(photo: CapturedDepthPhoto) {
        _editor = StateObject(wrappedValue: PhotoBokehEditor(photo: photo))
        _fNumber = State(initialValue: photo.fNumber)
        _stopIndex = State(initialValue: ApertureDial.nearestIndex(to: Double(photo.fNumber)))
        _lastOnIndex = State(initialValue: ApertureDial.nearestIndex(to: Double(photo.fNumber)))
        _focus = State(initialValue: photo.focusPoint)
    }

    var body: some View {
        GeometryReader { _ in
            let insets = Self.screenInsets()
            VStack(spacing: 0) {
                topBar
                    .frame(height: 52)
                    .padding(.horizontal, 16)
                imageArea
                controls
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .defersSystemGestures(on: .bottom)
        .onAppear {
            // 先把自动挑的对焦点标出来，让人知道现在清晰的是哪儿
            showMarker(at: Self.displayedPoint(fromRaw: focus, orientation: editor.photo.orientation))
            if editor.photo.notice != nil {
                withAnimation { noticeShown = true }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { noticeShown = false }
                }
            }
        }
        .onChange(of: stopIndex) { _, index in
            saved = false
            if index == ApertureDial.offIndex {
                // 景深关闭：显示不虚化的原图（和系统相册一样）
                editor.prepareOriginal()
                return
            }
            lastOnIndex = index
            fNumber = Float(ApertureDial.stops[index])
            editor.request(fNumber: fNumber, focus: focus)
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        ZStack {
            if let info = infoText {
                Text(info)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("关闭")
                Spacer()
                Button(action: save) {
                    Label(saved ? "已保存" : "保存", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .foregroundStyle(saved ? Color.white.opacity(0.7) : Color.black)
                        .background(saved ? Color.white.opacity(0.12) : Color.yellow, in: Capsule())
                }
                .disabled(editor.image == nil || saved)
            }
        }
    }

    /// 深度来源 · 对焦距离（相对深度换算不出米，不显示距离）
    private var infoText: String? {
        var parts: [String] = []
        if let label = editor.photo.depthSourceLabel { parts.append(label) }
        if editor.focusDistanceMeters > 0 { parts.append(String(format: "对焦 %.2f m", editor.focusDistanceMeters)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 照片

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                if let img = shownImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                    if let marker, !depthOff,
                       let p = ImageGeometry.containerPoint(marker, imageSize: img.size, container: geo.size) {
                        // 先 transition 再 position：缩放以框自己为中心，不是以整个照片区为中心
                        FocusMarker()
                            .opacity(markerDimmed ? 0.5 : 1)
                            .transition(.asymmetric(insertion: .scale(scale: 1.4).combined(with: .opacity),
                                                    removal: .identity))
                            .id(markerID)
                            .position(p)
                            .allowsHitTesting(false)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                handleTap(at: value.location, in: geo.size)
            })
            .overlay(alignment: .top) {
                if noticeShown, let notice = editor.photo.notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 10).padding(.horizontal, 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if !hasTapped && editor.image != nil {
                    Text("点按照片，选择清晰的主体")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if savedToast {
                    Label("已存到相册", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// 景深关了显示原图，否则显示虚化结果
    private var shownImage: UIImage? {
        depthOff ? (editor.originalImage ?? editor.image) : editor.image
    }

    private var depthOff: Bool { stopIndex == ApertureDial.offIndex }

    private func handleTap(at location: CGPoint, in container: CGSize) {
        guard let img = shownImage,
              let p = ImageGeometry.normalizedPoint(location, imageSize: img.size, container: container) else { return }
        focus = ImageBridge.rawPoint(fromDisplayed: p, orientation: img.imageOrientation)
        withAnimation(.easeOut(duration: 0.2)) { hasTapped = true }
        saved = false
        showMarker(at: p)
        // 景深关着时点照片：打开景深（回到关闭前那一档），对焦在点的地方
        if depthOff { stopIndex = lastOnIndex }
        editor.request(fNumber: fNumber, focus: focus)
    }

    /// 对焦框跳到 p，从大一圈缩回来；1.5 秒后变淡，一直留在那儿标出现在清晰的是哪儿
    private func showMarker(at p: CGPoint) {
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
            markerID &+= 1
            marker = p
            markerDimmed = false
        }
        let id = markerID
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if markerID == id { withAnimation(.easeOut(duration: 0.4)) { markerDimmed = true } }
        }
    }

    // MARK: - 光圈

    private var controls: some View {
        VStack(spacing: 4) {
            Text("景深")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            Text(depthOff ? "关闭" : String(format: "ƒ%.1f", fNumber))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(depthOff ? Color.white.opacity(0.8) : Color.yellow)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: stopIndex)
            ApertureDial(index: $stopIndex)
                .frame(height: 58)
                .padding(.horizontal, 12)
        }
    }

    private func save() {
        guard let img = shownImage else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        saved = true
        withAnimation { savedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { savedToast = false }
        }
    }

    // MARK: - 坐标

    /// 窗口的安全区（状态栏、灵动岛、底部横条；横屏时左右）。直接问窗口，不信这一页 SwiftUI 报的值（见类型说明）
    private static func screenInsets() -> EdgeInsets {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        let i = window?.safeAreaInsets ?? .zero
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// 原图归一化坐标 → 显示出来的图片里的归一化坐标（ImageBridge.rawPoint 的逆变换）
    private static func displayedPoint(fromRaw p: CGPoint, orientation: UIImage.Orientation) -> CGPoint {
        switch orientation {
        case .right, .rightMirrored: return CGPoint(x: 1 - p.y, y: p.x)
        case .left, .leftMirrored: return CGPoint(x: p.y, y: 1 - p.x)
        case .down, .downMirrored: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: return p
        }
    }
}

/// 对焦框：和系统相机一样的黄色方框，四条边中间各有一个往里的小刻度。取景界面点按对焦也用它
struct FocusMarker: View {
    var size: CGFloat = 76

    var body: some View {
        let tick = size * 0.1
        ZStack {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 1.3)
            Path { p in
                let m = size / 2
                p.move(to: CGPoint(x: m, y: 0)); p.addLine(to: CGPoint(x: m, y: tick))
                p.move(to: CGPoint(x: m, y: size)); p.addLine(to: CGPoint(x: m, y: size - tick))
                p.move(to: CGPoint(x: 0, y: m)); p.addLine(to: CGPoint(x: tick, y: m))
                p.move(to: CGPoint(x: size, y: m)); p.addLine(to: CGPoint(x: size - tick, y: m))
            }
            .stroke(Color.yellow, lineWidth: 1.3)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 1.5)
    }
}

/// 光圈刻度盘（和系统相册的景深编辑一样）：按 1/3 档排开，中间的黄线是当前值，左右拖动刻度换档，每过一档轻震一下。
/// 整档（1.4、2、2.8、4、5.6、8、11、16）标数字；ƒ16 再往后一档是「关闭」（不虚化，显示原图）
struct ApertureDial: View {
    static let stops: [Double] = [1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6,
                                  6.3, 7.1, 8, 9, 10, 11, 13, 14, 16]
    /// 「关闭」那一档的编号（在 ƒ16 后面）
    static let offIndex = stops.count
    private static let positions = stops.count + 1

    static func nearestIndex(to f: Double) -> Int {
        let target = log(max(f, 0.1))
        return stops.indices.min(by: { abs(log(stops[$0]) - target) < abs(log(stops[$1]) - target) }) ?? 0
    }

    @Binding var index: Int
    /// 拖动时刻度的连续位置（档位编号，带小数）；松手回到整档
    @State private var dragPosition: Double?
    @State private var dragStart: Double?
    private let spacing: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            let position = dragPosition ?? Double(index)
            ZStack {
                ForEach(0..<Self.positions, id: \.self) { i in
                    let x = center + CGFloat(Double(i) - position) * spacing
                    let major = i % 3 == 0 || i == Self.offIndex
                    Capsule()
                        .fill(Color.white.opacity(major ? 0.9 : 0.45))
                        .frame(width: major ? 2 : 1.5, height: major ? 18 : 11)
                        .position(x: x, y: 16)
                    if major {
                        Text(i == Self.offIndex ? "关闭" : Self.label(Self.stops[i]))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(i == index ? Color.yellow : Color.white.opacity(0.7))
                            .position(x: x, y: 42)
                    }
                }
                Capsule()
                    .fill(Color.yellow)
                    .frame(width: 3, height: 28)
                    .position(x: center, y: 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                       .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? Double(index)
                        if dragStart == nil { dragStart = start }
                        let p = min(max(start - Double(value.translation.width / spacing), 0),
                                    Double(Self.positions - 1))
                        dragPosition = p
                        let nearest = Int(p.rounded())
                        if nearest != index { index = nearest }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        withAnimation(.easeOut(duration: 0.15)) { dragPosition = nil }
                    }
            )
        }
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityLabel("光圈")
        .accessibilityValue(index == Self.offIndex ? "关闭" : String(format: "f %.1f", Self.stops[index]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, Self.positions - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }

    private static func label(_ f: Double) -> String {
        f == f.rounded() ? String(format: "%.0f", f) : String(format: "%.1f", f)
    }
}

extension ImageGeometry {
    /// normalizedPoint 的逆变换：显示出来的图片里的归一化坐标 → 容器里的位置
    static func containerPoint(_ p: CGPoint, imageSize: CGSize, container: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        let x0 = (container.width - w) / 2, y0 = (container.height - h) / 2
        return CGPoint(x: x0 + p.x * w, y: y0 + p.y * h)
    }
}
