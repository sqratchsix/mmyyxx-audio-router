import SwiftUI

/// SA1: the spectrum analyser as a rack device.
///
/// An insert on the FX bus like anything else in the chain, reading the signal
/// where it is mounted rather than routed to it separately: ahead of the RV4
/// it shows the dry send, behind it the tail. Every control is on the 1U panel,
/// so folding the display away costs nothing but the display; open, the lower
/// panel is the trace and nothing else.
struct SpectrumDeviceView: View {
    @Binding var device: FXDeviceSettings
    let index: Int

    @EnvironmentObject private var model: AppModel

    private var settings: SpectrumSettings { model.spectrumSettings }
    private var analyzer: SpectrumAnalyzer { model.rackAnalyzer(index) }

    /// Stripped-down settings for the collapsed trace: no grid, no labels, no
    /// peak holds, and fewer bands, because at 26 points tall those are noise.
    /// Drawn as a bare line on the panel, so the style and the palette give way
    /// to a single engraved stroke.
    private var sparkSettings: SpectrumSettings {
        var copy = settings
        copy.showGrid = false
        copy.showLabels = false
        copy.showPeaks = false
        copy.style = .line
        copy.glow = 0
        copy.bandCount = min(settings.bandCount, 40)
        return copy
    }

    var body: some View {
        RackEars(index: index,
                 units: FXDeviceKind.analyzer.rackUnits(expanded: device.expanded),
                 title: "SA1", enabled: $device.enabled) {
            VStack(spacing: 0) {
                mainPanel
                    .frame(height: Rack.unit)
                if device.expanded {
                    Rectangle().fill(Color.black.opacity(0.8)).frame(height: 2)
                    display
                        .frame(height: Rack.unit * 2 - 2)
                }
            }
            .opacity(device.enabled ? 1 : 0.45)
            .background(Rack.chassis)
        }
        .animation(.easeOut(duration: 0.16), value: device.expanded)
    }

    // MARK: - Main panel (1U, always shown)

    private var mainPanel: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SA1")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Rack.engraved)
                Text("Spectrum Analyser")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.8))
                panelToggle
            }
            .frame(width: 104, alignment: .leading)

            divider

            VStack(alignment: .leading, spacing: 4) {
                pickerRow("STYLE") {
                    Picker("", selection: $model.spectrumSettings.style) {
                        ForEach(SpectrumStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                pickerRow("COLOUR") {
                    Picker("", selection: $model.spectrumSettings.palette) {
                        ForEach(SpectrumPalette.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            }

            divider

            HStack(spacing: 4) {
                miniKnob("Floor", value: Binding(
                    get: { Double((settings.floorDB + 120) / 120) },
                    set: { model.spectrumSettings.floorDB = Float($0) * 120 - 120 }))
                miniKnob("Slope", value: Binding(
                    get: { Double(settings.slopeDBPerOctave / 6) },
                    set: { model.spectrumSettings.slopeDBPerOctave = Float($0) * 6 }))
                miniKnob("Attack", value: Binding(
                    get: { Double(settings.attackMS / 200) },
                    set: { model.spectrumSettings.attackMS = max(1, Float($0) * 200) }))
                miniKnob("Release", value: Binding(
                    get: { Double(settings.releaseMS / 2000) },
                    set: { model.spectrumSettings.releaseMS = max(20, Float($0) * 2000) }))
                miniKnob("Bands", value: Binding(
                    get: { Double(settings.bandCount - 12) / 108 },
                    set: { model.spectrumSettings.bandCount = Int($0 * 108) + 12 }))
            }

            divider

            VStack(alignment: .leading, spacing: 2) {
                toggleChip("GRID", isOn: settings.showGrid) {
                    model.spectrumSettings.showGrid.toggle()
                }
                toggleChip("LABELS", isOn: settings.showLabels) {
                    model.spectrumSettings.showLabels.toggle()
                }
                toggleChip("PEAKS", isOn: settings.showPeaks) {
                    model.spectrumSettings.showPeaks.toggle()
                }
            }
            .frame(width: 52, alignment: .leading)

            divider

            // Folded away, this trace is the only one on screen, so it takes
            // whatever width is left on the panel, with the reading underneath
            // it rather than beside it.
            VStack(alignment: .leading, spacing: 1) {
                if !device.expanded {
                    SpectrumCanvas(analyzer: analyzer, settings: sparkSettings,
                                   tint: Rack.engraved)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                }
                SpectrumPeakReadout(analyzer: analyzer, floorDB: settings.floorDB)
            }
            .frame(minWidth: 92, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Rack.panel, Rack.panelDark],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var panelToggle: some View {
        Button { device.expanded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: device.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 6, weight: .black))
                Text(device.expanded ? "Close" : "Open")
                    .font(Rack.caption(7))
            }
            .foregroundStyle(Rack.engraved)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.black.opacity(device.expanded ? 0.22 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(device.expanded ? "Fold the analyser to 1U" : "Open the analyser")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.28))
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    // MARK: - Lower panel (2U): the trace, full width

    private var display: some View {
        SpectrumCanvas(analyzer: analyzer, settings: settings)
            .padding(6)
            .background(Rack.screen)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
            )
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Rack.panelDark, Rack.panel],
                               startPoint: .top, endPoint: .bottom)
            )
    }

    private func pickerRow<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Rack.caption(7))
                .foregroundStyle(Rack.engraved.opacity(0.85))
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(width: 104)
        }
    }

    private func miniKnob(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            Knob(value: value, diameter: 20)
            Text(title)
                .font(Rack.caption(6))
                .foregroundStyle(Rack.engraved)
        }
        .frame(width: 38)
    }

    private func toggleChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Rack.caption(6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
        .buttonStyle(RackChipStyle(isOn: isOn))
    }
}

/// Peak frequency and level, engraved on the panel. Its own view so the panel
/// around it is not rebuilt at the analyser's frame rate.
///
/// The units are fixed labels and the digits are monospaced in fixed-width
/// columns, so the readout never reflows and never blanks: with nothing on the
/// bus it reads the floor rather than flicking between a value and a dash.
struct SpectrumPeakReadout: View {
    @ObservedObject var analyzer: SpectrumAnalyzer
    var floorDB: Float = -120

    var body: some View {
        HStack(spacing: 2) {
            Text(String(format: "%.2f", max(analyzer.peakFrequency, 0) / 1000))
                .frame(width: 30, alignment: .trailing)
            Text("k")
                .foregroundStyle(Rack.engraved.opacity(0.7))
            Text(String(format: "%.0f", max(analyzer.peakLevelDB, floorDB)))
                .frame(width: 26, alignment: .trailing)
                .padding(.leading, 2)
            Text("dB")
                .foregroundStyle(Rack.engraved.opacity(0.7))
        }
        .font(Rack.mono(9, weight: .bold))
        .foregroundStyle(Rack.engraved)
        .lineLimit(1)
        .frame(width: 92, alignment: .leading)
    }
}

/// A rack-panel toggle chip: the engraved-metal cousin of `ToggleChipStyle`.
struct RackChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.black.opacity(0.85) : Rack.engraved.opacity(0.9))
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? Rack.sendTint : Color.black.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: isOn ? Rack.sendTint.opacity(0.5) : .clear, radius: 3)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
