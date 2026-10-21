// 从 DepthBokehCamera 2 迁移（最新版：松手 ±5% 吸附到 0.5× / 1× / 2× / 4×，松手或点按后通知相机换到最合适的镜头）。
// 只加了 public 和 init，指针图片改从本包的资源里取
#if os(iOS)
import SwiftUI
import UIKit

/// A focal-length strip that opens into a continuous, centre-pointer zoom dial.
/// Values use the camera's global UI scale (1x = 24mm), not device zoom factors.
public struct ContinuousZoomControl: View {
    let zoomFactor: CGFloat
    let range: ClosedRange<CGFloat>
    let stops: [ZoomStop]
    var isEnabled: Bool = true
    /// Every change while the finger moves (the camera may only crop the running stream).
    var onZoomChange: (CGFloat) -> Void
    /// The zoom is final for now (finger lifted, stop tapped): the camera may move to its best route.
    var onZoomCommit: () -> Void = {}

    public init(zoomFactor: CGFloat, range: ClosedRange<CGFloat>, stops: [ZoomStop], isEnabled: Bool = true,
                onZoomChange: @escaping (CGFloat) -> Void, onZoomCommit: @escaping () -> Void = {}) {
        self.zoomFactor = zoomFactor
        self.range = range
        self.stops = stops
        self.isEnabled = isEnabled
        self.onZoomChange = onZoomChange
        self.onZoomCommit = onZoomCommit
    }

    @State private var progress: CGFloat = 0
    @State private var isExpanded = false
    @State private var isDragging = false
    @State private var dragStartProgress: CGFloat?
    @State private var collapseTask: Task<Void, Never>?
    @State private var hapticTrigger = 0

    private let accent = Color(.displayP3, red: 235 / 255, green: 1, blue: 105 / 255)
    private let dialInset: CGFloat = 20
    private var scale: ZoomScale { ZoomScale(range: range) }
    private var displayedFactor: CGFloat { scale.factor(at: progress) }
    private var isInteractive: Bool { isEnabled && range.upperBound > range.lowerBound }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if isExpanded {
                    expandedDial
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    focalLengthStops
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(dialGesture(width: max(proxy.size.width - dialInset * 2, 1)))
        }
        .frame(height: 80)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .sensoryFeedback(.selection, trigger: hapticTrigger)
        .onAppear { synchronizeProgress() }
        .onChange(of: zoomFactor) { _, _ in
            // An in-flight camera update must not pull the dial away from the finger.
            guard !isDragging else { return }
            synchronizeProgress()
        }
        .onChange(of: range) { _, _ in
            resetInteraction()
            synchronizeProgress()
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { resetInteraction() }
        }
        .onDisappear { resetInteraction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("变焦")
        .accessibilityValue("\(factorText(displayedFactor))，\(ZoomScale.focalLength(for: displayedFactor))毫米")
        .accessibilityAdjustableAction { direction in
            guard isInteractive else { return }
            let offset: CGFloat
            switch direction {
            case .increment: offset = 0.025
            case .decrement: offset = -0.025
            @unknown default: return
            }
            applyProgress(progress + offset)
            onZoomCommit()
            expand()
            scheduleCollapse()
        }
    }

    private var focalLengthStops: some View {
        let selectedID = ZoomScale.selectedStop(for: displayedFactor, stops: stops)?.id
        return HStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                let selected = selectedID == stop.id
                Button {
                    guard isEnabled else { return }
                    progress = scale.progress(for: stop.factor)
                    onZoomChange(scale.clamped(stop.factor))
                    onZoomCommit()
                } label: {
                    Text("\(selected ? ZoomScale.focalLength(for: displayedFactor) : stop.focalLength)")
                        .font(.system(size: 20, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? accent : .white)
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)

                if index < stops.count - 1 {
                    HStack(spacing: 2) {
                        ForEach(0..<3) { _ in
                            Capsule()
                                .fill(Color.gray)
                                .frame(width: 1, height: 2)
                        }
                    }
                    .padding(.horizontal, 5)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var expandedDial: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                drawDial(in: &context, size: size)
            }
            .frame(height: 30)
            .padding(.horizontal, dialInset)
            .offset(y: 18)

            Image(uiImage: UIImage(named: "ZoomPointer", in: .module, with: nil) ?? UIImage())
                .offset(y: 18)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Text(factorText(displayedFactor))
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .monospacedDigit()
                    .frame(height: 16)

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(ZoomScale.focalLength(for: displayedFactor))")
                        .font(.system(size: 20, weight: .medium))
                    Text("mm")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(accent)
                .monospacedDigit()
                .padding(.top, 39)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func dialGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard isInteractive else { return }
                if !isDragging {
                    collapseTask?.cancel()
                    collapseTask = nil
                    isDragging = true
                    dragStartProgress = progress
                    expand()
                }
                let start = dragStartProgress ?? progress
                applyProgress(start - value.translation.width / (width * 1.5))
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                dragStartProgress = nil
                if !snapToStop() {
                    // A failed camera change may have restored its value while dragging.
                    synchronizeProgress()
                }
                onZoomCommit()
                scheduleCollapse()
            }
            .exclusively(before: LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard isInteractive else { return }
                    expand()
                    scheduleCollapse()
                })
    }

    private func drawDial(in context: inout GraphicsContext, size: CGSize) {
        let midX = size.width / 2
        let travelWidth = size.width * 1.5
        for tick in dialTicks {
            let x = midX + (scale.progress(for: tick) - progress) * travelWidth
            guard x >= -24, x <= size.width + 24 else { continue }
            let major = isMajorTick(tick)
            let length: CGFloat = major ? 14 : 10
            let trackY = (size.height + length) / 2
            let distance = min(abs(x - midX) / max(midX, 1), 1)
            let opacity = 1 - max(distance - 0.2, 0) / 0.8
            var path = Path()
            path.move(to: CGPoint(x: x, y: trackY - length))
            path.addLine(to: CGPoint(x: x, y: trackY))
            let gray = major ? 224.0 / 255 : 126.0 / 255
            context.stroke(path, with: .color(Color(white: gray).opacity(opacity)), lineWidth: 0.5)
        }
    }

    /// Keep fine 0.1x ticks for ordinary camera ranges and cap work for large ranges.
    private var dialTicks: [CGFloat] {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0 else { return [range.lowerBound] }
        let minimumStep = max(0.1, span / 400)
        let magnitude = pow(10.0, floor(log10(Double(minimumStep))))
        let step = CGFloat(([1.0, 2.0, 5.0, 10.0].first {
            $0 * magnitude >= Double(minimumStep)
        } ?? 10) * magnitude)
        let first = ceil(range.lowerBound / step) * step
        let count = max(0, min(400, Int(floor((range.upperBound - first) / step + 0.0001))))
        var ticks = (0...count).map { first + CGFloat($0) * step }
            .filter { range.contains($0) }
        if range.contains(0.5), !ticks.contains(where: { abs($0 - 0.5) < 0.0001 }) {
            ticks.append(0.5)
        }
        return ticks
    }

    private func isMajorTick(_ factor: CGFloat) -> Bool {
        abs(factor - 0.5) < 0.0001 || (factor >= 1 && abs(factor.rounded() - factor) < 0.0001)
    }

    private func applyProgress(_ value: CGFloat) {
        let next = min(max(value, 0), 1)
        let previous = progress
        if dialTicks.contains(where: { tick in
            guard isMajorTick(tick) else { return false }
            let position = scale.progress(for: tick)
            return next > previous
                ? position > previous && position <= next
                : position < previous && position >= next
        }) {
            hapticTrigger += 1
        }
        progress = next
        onZoomChange(displayedFactor)
    }

    /// Releasing the dial within ±5% of a stop lands exactly on it. The stops (1×, 2×, 4×) are where
    /// the camera itself delivers depth, uncropped — 1× is the LiDAR route.
    private func snapToStop() -> Bool {
        let factor = displayedFactor
        guard let stop = stops.map(\.factor).first(where: { range.contains($0) && abs(factor / $0 - 1) <= 0.05 }),
              abs(factor - stop) > 0.000001 else { return false }
        progress = scale.progress(for: stop)
        hapticTrigger += 1
        onZoomChange(stop)
        return true
    }

    private func factorText(_ factor: CGFloat) -> String {
        let truncated = floor(factor * 10 + 0.000001) / 10
        return String(format: factor >= 10 && truncated.rounded() == truncated ? "%.0fx" : "%.1fx", Double(truncated))
    }

    private func synchronizeProgress() {
        progress = scale.progress(for: zoomFactor)
    }

    private func expand() {
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard !Task.isCancelled, !isDragging else { return }
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
            collapseTask = nil
        }
    }

    private func resetInteraction() {
        collapseTask?.cancel()
        collapseTask = nil
        isDragging = false
        dragStartProgress = nil
        isExpanded = false
    }
}

#Preview {
    ContinuousZoomControl(
        zoomFactor: 3,
        range: 0.5...4,
        stops: [
            ZoomStop(factor: 0.5, focalLength: 13),
            ZoomStop(factor: 1, focalLength: 24),
            ZoomStop(factor: 2, focalLength: 48),
            ZoomStop(factor: 4, focalLength: 96)
        ],
        onZoomChange: { _ in }
    )
    .padding()
    .background(.black)
}
#endif
