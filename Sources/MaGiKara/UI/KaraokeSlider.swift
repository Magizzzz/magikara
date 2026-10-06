import SwiftUI

/// 四区视觉统一的自定义滑杆。
///
/// 用它替换系统 `Slider`，原因是 macOS 上的系统滑杆在获得焦点/拖动时会画出
/// 蓝色环形焦点环与拖拽圆环，和浅紫蓝的四区面板完全不搭。
///
/// 行为与系统滑杆一致：
/// - 支持拖动改变值，范围自动夹取；
/// - 父视图 `.disabled(true)`（环境 `isEnabled == false`）或 `isDisabled` 时不可交互并变灰；
/// - 不参与键盘焦点，因此不会再出现蓝色焦点环。
struct KaraokeSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let accent: Color
    private let trackHeight: CGFloat
    private let thumbDiameter: CGFloat
    private let explicitlyDisabled: Bool

    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>,
         in range: ClosedRange<Double>,
         accent: Color = Theme.violet,
         trackHeight: CGFloat = 4,
         thumbDiameter: CGFloat = 12,
         disabled: Bool = false) {
        self._value = value
        self.range = range
        self.accent = accent
        self.trackHeight = trackHeight
        self.thumbDiameter = thumbDiameter
        self.explicitlyDisabled = disabled
    }

    private var usable: Bool { isEnabled && !explicitlyDisabled }
    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: Double {
        guard span > 1e-12 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let travel = max(0, width - thumbDiameter)
            let fillWidth = max(thumbDiameter * 0.5, CGFloat(fraction) * travel + thumbDiameter * 0.5)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.controlFill)
                    .frame(width: width, height: trackHeight)
                    .frame(maxHeight: .infinity, alignment: .center)

                Capsule()
                    .fill(usable ? accent : Theme.textTertiary.opacity(0.35))
                    .frame(width: fillWidth, height: trackHeight)
                    .frame(maxHeight: .infinity, alignment: .center)

                // 用无描边的小胶囊作为拖拽柄。系统 Slider 的蓝色焦点环和
                // 彩色圆环都不再出现，避免浅色工作区里出现第二个视觉焦点。
                Capsule()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: max(8, thumbDiameter * 0.72))
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                    .offset(x: CGFloat(fraction) * travel)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: max(trackHeight, thumbDiameter))
            .contentShape(Rectangle())
            .gesture(dragGesture(travel: travel))
            .allowsHitTesting(usable)
        }
        .frame(height: max(trackHeight, thumbDiameter))
        .opacity(usable ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard usable, span > 1e-12 else { return }
                let t: Double
                if travel > 0.5 {
                    t = (Double(gesture.location.x) - Double(thumbDiameter) / 2) / Double(travel)
                } else {
                    t = 0
                }
                let clamped = min(max(t, 0), 1)
                let newValue = range.lowerBound + clamped * span
                if abs(newValue - value) > 1e-9 { value = newValue }
            }
    }
}
