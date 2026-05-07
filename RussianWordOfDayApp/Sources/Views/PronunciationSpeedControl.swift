import SwiftUI

/// YouTube-style stepped speed control: large **0.65x** readout, dot-thumb track, ± steppers, preset chips.
struct PronunciationSpeedControl: View {
    @Binding var value: Double

    private static let step = 0.05
    private static let presets: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var body: some View {
        VStack(spacing: 18) {
            Text("\(Self.formatMultiplier(value))x")
                .font(.system(size: 32, weight: .bold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel("Pronunciation speed \(Self.formatMultiplier(value)) times")

            HStack(alignment: .center, spacing: 10) {
                roundStepButton(systemName: "minus") {
                    bump(-Self.step)
                }
                .disabled(value <= 0)
                .accessibilityLabel("Decrease pronunciation speed")

                SpeedDotSlider(
                    value: $value,
                    range: 0...1,
                    snap: { AppSettings.snapPronunciationRateScale($0) }
                )
                .frame(height: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pronunciation speed slider")
                .accessibilityValue("\(Self.formatMultiplier(value)) times")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        bump(Self.step)
                    case .decrement:
                        bump(-Self.step)
                    @unknown default:
                        break
                    }
                }

                roundStepButton(systemName: "plus") {
                    bump(Self.step)
                }
                .disabled(value >= 1)
                .accessibilityLabel("Increase pronunciation speed")
            }

            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { preset in
                    presetChip(preset)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }

    private func bump(_ delta: Double) {
        value = AppSettings.snapPronunciationRateScale(value + delta)
    }

    private func presetChip(_ preset: Double) -> some View {
        let selected = abs(value - preset) < 0.001
        return Button {
            value = AppSettings.snapPronunciationRateScale(preset)
        } label: {
            VStack(spacing: 4) {
                Text(Self.presetTitle(preset))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.22) : Color(uiColor: .secondarySystemFill))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                    }

                if let caption = Self.presetCaption(preset) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(height: 12)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityPresetLabel(preset))
    }

    private static func presetTitle(_ preset: Double) -> String {
        if preset == 0 { return "0" }
        if preset == 1 { return "1" }
        return String(format: "%.2f", preset)
    }

    private static func presetCaption(_ preset: Double) -> String? {
        switch preset {
        case 0: return "Mute"
        case 1: return "Normal"
        default: return nil
        }
    }

    private static func accessibilityPresetLabel(_ preset: Double) -> String {
        switch preset {
        case 0: return "Mute, speed zero"
        case 0.25: return "Speed 0.25"
        case 0.5: return "Speed 0.5"
        case 0.75: return "Speed 0.75"
        case 1: return "Normal speed"
        default: return "Speed \(preset)"
        }
    }

    private static func formatMultiplier(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    @ViewBuilder
    private func roundStepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dot thumb slider

private struct SpeedDotSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let snap: (Double) -> Double

    private let trackHeight: CGFloat = 3
    private let thumbSize: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let span = range.upperBound - range.lowerBound
            let t = span > 0 ? (value - range.lowerBound) / span : 0
            let clampedT = min(1, max(0, t))
            let inset = thumbSize / 2
            let usable = max(1, width - thumbSize)
            let thumbCenterX = inset + CGFloat(clampedT) * usable
            let fillWidth = max(trackHeight, thumbCenterX)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.primary)
                    .frame(width: fillWidth, height: trackHeight)
                Circle()
                    .fill(Color.primary)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .offset(x: thumbCenterX - thumbSize / 2, y: 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateFromX(gesture.location.x, width: width, span: span)
                    }
            )
        }
    }

    private func updateFromX(_ x: CGFloat, width: CGFloat, span: Double) {
        let inset = thumbSize / 2
        let usable = max(1, width - thumbSize)
        let xClamped = min(width, max(0, x))
        let pct = Double((xClamped - inset) / usable)
        let clampedPct = min(1, max(0, pct))
        let raw = range.lowerBound + clampedPct * span
        value = snap(raw)
    }
}
