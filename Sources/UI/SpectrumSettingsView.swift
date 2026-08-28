import SwiftUI

/// The analyser's control panel. Everything the display does is adjustable
/// here, grouped by what it affects rather than by which struct field it is.
struct SpectrumSettingsView: View {
    @Binding var settings: SpectrumSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("LOOK") {
                    row("Style") {
                        Picker("", selection: $settings.style) {
                            ForEach(SpectrumStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    row("Colour") {
                        Picker("", selection: $settings.palette) {
                            ForEach(SpectrumPalette.allCases) { palette in
                                HStack {
                                    swatch(palette)
                                    Text(palette.displayName)
                                }
                                .tag(palette)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    slider("Glow", value: $settings.glow, in: 0...1, format: percent)
                    if settings.style != .area && settings.style != .line {
                        slider("Bar gap", value: $settings.barGap, in: 0...0.7, format: percent)
                    }
                    slider("Height", value: $settings.height, in: 70...320) {
                        "\(Int($0)) px"
                    }
                    toggle("Grid", isOn: $settings.showGrid)
                    toggle("Labels", isOn: $settings.showLabels)
                }

                section("ANALYSIS") {
                    row("Resolution") {
                        Picker("", selection: $settings.fftSize) {
                            ForEach(SpectrumSettings.fftSizes, id: \.self) { size in
                                Text("\(size)").tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                    slider("Bands", value: bandBinding, in: 8...160) { "\(Int($0))" }
                    slider("Band smoothing", value: smoothingBinding, in: 0...4) {
                        $0 < 0.5 ? "off" : "±\(Int($0))"
                    }
                    slider("Tilt", value: $settings.slopeDBPerOctave, in: 0...9) {
                        String(format: "%.1f dB/oct", $0)
                    }
                    slider("Top", value: $settings.maxHz, in: Float(2_000)...Float(24_000)) {
                        SpectrumCanvas.frequencyLabel(Float($0)) + " Hz"
                    }
                    slider("Bottom", value: $settings.minHz, in: 10...200) {
                        "\(Int($0)) Hz"
                    }
                }

                section("TIMING") {
                    slider("Attack", value: $settings.attackMS, in: 1...400) { "\(Int($0)) ms" }
                    slider("Release", value: $settings.releaseMS, in: 20...3_000) { "\(Int($0)) ms" }
                    row("Refresh") {
                        Picker("", selection: $settings.refreshHz) {
                            ForEach(SpectrumSettings.refreshRates, id: \.self) { rate in
                                Text("\(Int(rate)) Hz").tag(rate)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                    toggle("Peak hold", isOn: $settings.showPeaks)
                    if settings.showPeaks {
                        slider("Hold", value: $settings.peakHoldSeconds, in: 0...6) {
                            String(format: "%.1f s", $0)
                        }
                        slider("Peak fall", value: $settings.peakFallDBPerSecond, in: 2...120) {
                            "\(Int($0)) dB/s"
                        }
                    }
                }

                section("SCALE") {
                    slider("Floor", value: $settings.floorDB, in: -120 ... -30) { "\(Int($0)) dB" }
                    slider("Ceiling", value: $settings.ceilingDB, in: -12...12) { "\(Int($0)) dB" }
                }

                HStack {
                    Spacer()
                    Button("Reset analyser") {
                        let visible = settings.isVisible
                        settings = SpectrumSettings()
                        settings.isVisible = visible
                    }
                    .buttonStyle(.plain)
                    .font(Theme.label(10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
        }
        .frame(width: 288, height: 470)
        .background(Theme.panel)
    }

    // MARK: - Bindings that need a step

    private var bandBinding: Binding<Double> {
        Binding(get: { Double(settings.bandCount) },
                set: { settings.bandCount = Int(($0 / 4).rounded()) * 4 })
    }

    private var smoothingBinding: Binding<Double> {
        Binding(get: { Double(settings.neighbourSmoothing) },
                set: { settings.neighbourSmoothing = Int($0.rounded()) })
    }

    // MARK: - Pieces

    private func percent(_ value: Double) -> String { "\(Int(value * 100))%" }

    private func swatch(_ palette: SpectrumPalette) -> some View {
        LinearGradient(colors: palette.gradientStops, startPoint: .leading, endPoint: .trailing)
            .frame(width: 26, height: 8)
            .clipShape(Capsule())
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.label(8, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.label(10))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            content()
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(Theme.label(10))
                .foregroundStyle(Theme.textSecondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    /// Slider with its value read out beside the label, which is the only way
    /// these are legible without a text field per setting.
    private func slider(_ label: String, value: Binding<Float>,
                        in range: ClosedRange<Float>,
                        format: @escaping (Double) -> String) -> some View {
        let proxy = Binding(get: { Double(value.wrappedValue) },
                            set: { value.wrappedValue = Float($0) })
        return slider(label, value: proxy, in: Double(range.lowerBound)...Double(range.upperBound),
                      format: format)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.numeric(9))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
    }
}
