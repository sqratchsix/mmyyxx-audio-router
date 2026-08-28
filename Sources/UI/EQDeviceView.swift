import SwiftUI

/// EQ5: a five-band parametric EQ in the rack.
///
/// Presets set the bands; the bands are then free to be moved by hand, at which
/// point the preset reads Custom. Folded to 1U it keeps the preset and the trim
/// with the curve drawn on the panel; open, the lower panel is the response and
/// the band controls.
struct EQDeviceView: View {
    @Binding var device: FXDeviceSettings
    let index: Int

    @EnvironmentObject private var model: AppModel

    private var eq: EQParameters { device.eq }
    private var sampleRate: Float {
        model.sampleRate > 0 ? Float(model.sampleRate) : 48_000
    }

    var body: some View {
        RackEars(index: index,
                 units: FXDeviceKind.eq.rackUnits(expanded: device.expanded),
                 title: "EQ5", enabled: $device.enabled) {
            VStack(spacing: 0) {
                mainPanel
                    .frame(height: Rack.unit)
                if device.expanded {
                    Rectangle().fill(Color.black.opacity(0.8)).frame(height: 2)
                    lowerPanel
                        .frame(height: Rack.unit * 2 - 2)
                }
            }
            .opacity(device.enabled ? 1 : 0.45)
            .background(Rack.chassis)
        }
        .animation(.easeOut(duration: 0.16), value: device.expanded)
    }

    // MARK: - Main panel (1U)

    private var mainPanel: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("EQ5")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Rack.engraved)
                Text("Parametric EQ")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.8))
                panelToggle
            }
            .frame(width: 104, alignment: .leading)

            divider

            VStack(alignment: .leading, spacing: 2) {
                Text("PRESET")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.85))
                Picker("", selection: presetBinding) {
                    ForEach(EQPreset.selectable) { Text($0.displayName).tag($0) }
                    if eq.preset == .custom {
                        Divider()
                        Text(EQPreset.custom.displayName).tag(EQPreset.custom)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(width: 112)
                Button("Reset bands") { device.eq = EQPreset.flat.applied(to: eq) }
                    .buttonStyle(.plain)
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.75))
            }

            divider

            knob("OUT", value: Binding(
                get: { Double((eq.outputDB + 12) / 24) },
                set: { device.eq.outputDB = Float($0) * 24 - 12 }),
                 readout: gainText(eq.outputDB))

            divider

            // Folded away, the curve still says what the unit is doing, so it
            // takes the width the open panel's display would have had.
            EQCurve(parameters: eq, sampleRate: sampleRate,
                    tint: Rack.engraved, showsGrid: false, showsHandles: false,
                    autoScale: true)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .opacity(device.expanded ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Rack.panel, Rack.panelDark],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Lower panel (2U): response and bands

    private var lowerPanel: some View {
        HStack(spacing: 0) {
            EQCurve(parameters: eq, sampleRate: sampleRate,
                    tint: Rack.screenInk, showsGrid: true, showsHandles: true)
                .padding(6)
                .background(Rack.screen)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                )
                .padding(8)
                .frame(maxWidth: .infinity)

            Rectangle().fill(Color.black.opacity(0.3)).frame(width: 1)

            HStack(spacing: 0) {
                ForEach(0..<EQParameters.bandCount, id: \.self) { band in
                    bandColumn(band)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .background(
            LinearGradient(colors: [Rack.panelDark, Rack.panel],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func bandColumn(_ band: Int) -> some View {
        let settings = eq[band]
        let isShelf = EQParameters.kind(band) != .peak
        return VStack(spacing: 3) {
            Button {
                device.eq[band].enabled.toggle()
                device.eq.preset = .custom
            } label: {
                Text(EQParameters.labels[band])
                    .font(Rack.caption(6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(RackChipStyle(isOn: settings.enabled))

            knob("FREQ", value: bandBinding(band, keyPath: \.frequency,
                                            from: Self.frequencyPosition,
                                            to: Self.frequencyValue),
                 readout: frequencyText(settings.frequency),
                 isActive: settings.enabled)

            knob("GAIN", value: bandBinding(band, keyPath: \.gainDB,
                                            from: { Double(($0 + 18) / 36) },
                                            to: { Float($0) * 36 - 18 }),
                 readout: gainText(settings.gainDB),
                 isActive: settings.enabled,
                 reset: 0.5)

            knob("Q", value: bandBinding(band, keyPath: \.q,
                                         from: Self.qPosition,
                                         to: Self.qValue),
                 readout: isShelf ? "—" : String(format: "%.2f", settings.q),
                 isActive: settings.enabled && !isShelf)
        }
        .frame(width: 46)
    }

    // MARK: - Pieces

    private var presetBinding: Binding<EQPreset> {
        Binding(get: { eq.preset },
                set: { preset in
                    guard preset != .custom else { return }
                    device.eq = preset.applied(to: eq)
                })
    }

    /// A band value as knob travel. Every setter marks the curve as custom,
    /// since the preset it came from no longer describes it.
    private func bandBinding(_ band: Int,
                             keyPath: WritableKeyPath<EQBand, Float>,
                             from position: @escaping (Float) -> Double,
                             to value: @escaping (Double) -> Float) -> Binding<Double> {
        Binding(
            get: { position(self.eq[band][keyPath: keyPath]) },
            set: { travel in
                self.device.eq[band][keyPath: keyPath] = value(travel)
                self.device.eq.preset = .custom
            }
        )
    }

    private static func frequencyPosition(_ hz: Float) -> Double {
        Double(log(min(max(hz, 20), 20_000) / 20) / log(1_000))
    }

    private static func frequencyValue(_ travel: Double) -> Float {
        20 * Float(pow(1_000, min(max(travel, 0), 1)))
    }

    private static func qPosition(_ q: Float) -> Double {
        Double(log(min(max(q, 0.2), 8) / 0.2) / log(40))
    }

    private static func qValue(_ travel: Double) -> Float {
        0.2 * Float(pow(40, min(max(travel, 0), 1)))
    }

    private func frequencyText(_ hz: Float) -> String {
        hz < 1_000 ? "\(Int(hz.rounded()))" : String(format: "%.1fk", hz / 1_000)
    }

    private func gainText(_ dB: Float) -> String {
        String(format: dB > 0.05 ? "+%.1f" : "%.1f", dB)
    }

    private func knob(_ title: String, value: Binding<Double>, readout: String,
                      isActive: Bool = true, reset: Double? = nil) -> some View {
        VStack(spacing: 1) {
            Knob(value: value, diameter: 20, resetValue: reset, isActive: isActive)
            Text(readout)
                .font(Rack.mono(6, weight: .bold))
                .foregroundStyle(Rack.engraved.opacity(isActive ? 1 : 0.5))
            Text(title)
                .font(Rack.caption(6))
                .foregroundStyle(Rack.engraved.opacity(0.8))
        }
        .frame(width: 44)
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
        .help(device.expanded ? "Fold the EQ to 1U" : "Open the EQ")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.28))
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

/// The EQ's response, drawn from the same coefficients the audio runs through.
struct EQCurve: View {
    let parameters: EQParameters
    let sampleRate: Float
    let tint: Color
    var showsGrid = true
    var showsHandles = true
    /// Fit the vertical scale to the curve instead of holding a fixed ±18 dB.
    /// On the folded panel that is the difference between a legible shape and a
    /// nearly straight line, since a working EQ move is a few dB on a scale
    /// built for the extremes.
    var autoScale = false

    private static let minHz: Float = 20
    private static let maxHz: Float = 20_000
    private static let fixedRangeDB: Float = 18
    /// Never zoom in past this, or the noise in a flat curve becomes mountains.
    private static let minimumRangeDB: Float = 3
    private static let points = 160

    var body: some View {
        Canvas { context, size in
            let response = EQUnit.response(parameters, sampleRate: sampleRate,
                                           points: Self.points,
                                           minHz: Self.minHz, maxHz: Self.maxHz)
            let range = verticalRange(for: response)
            func y(_ dB: Float) -> CGFloat {
                let clamped = min(max(dB, -range), range)
                return size.height * CGFloat((range - clamped) / (range * 2))
            }

            if showsGrid { drawGrid(&context, size: size, range: range) }

            // Zero line, always: without it a flat curve is just a line
            // somewhere rather than a line at unity.
            context.fill(Path(CGRect(x: 0, y: y(0) - 0.5, width: size.width, height: 1)),
                         with: .color(tint.opacity(showsGrid ? 0.35 : 0.22)))

            var path = Path()
            for (step, dB) in response.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(step) / CGFloat(response.count - 1),
                                    y: y(dB))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            if showsHandles {
                for index in 0..<EQParameters.bandCount {
                    let band = parameters[index]
                    guard band.enabled else { continue }
                    let centre = CGPoint(x: x(for: band.frequency, width: size.width),
                                         y: y(band.gainDB))
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 2.5, y: centre.y - 2.5,
                                                        width: 5, height: 5)),
                                 with: .color(tint.opacity(band.gainDB == 0 ? 0.35 : 0.9)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("EQ response")
    }

    /// Half the height of the plot in dB.
    private func verticalRange(for response: [Float]) -> Float {
        guard autoScale else { return Self.fixedRangeDB }
        let peak = response.reduce(Float(0)) { max($0, abs($1)) }
        return min(max(peak * 1.15, Self.minimumRangeDB), Self.fixedRangeDB)
    }

    private func x(for hz: Float, width: CGFloat) -> CGFloat {
        let ratio = Double(Self.maxHz / Self.minHz)
        let value = log(Double(max(hz, Self.minHz) / Self.minHz)) / log(ratio)
        return width * CGFloat(min(max(value, 0), 1))
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize, range: Float) {
        let line = GraphicsContext.Shading.color(tint.opacity(0.16))
        for hz: Float in [100, 1_000, 10_000] {
            let position = x(for: hz, width: size.width)
            context.fill(Path(CGRect(x: position, y: 0, width: 1, height: size.height)), with: line)
            context.draw(
                Text(hz < 1_000 ? "\(Int(hz))" : "\(Int(hz / 1_000))k")
                    .font(Rack.mono(6, weight: .bold))
                    .foregroundStyle(tint.opacity(0.55)),
                at: CGPoint(x: position + 3, y: size.height - 5), anchor: .bottomLeading)
        }
        for dB: Float in [-12, -6, 6, 12] where abs(dB) < range {
            let position = size.height * CGFloat((range - dB) / (range * 2))
            context.fill(Path(CGRect(x: 0, y: position, width: size.width, height: 1)), with: line)
        }
        context.draw(
            Text("+\(Int(range.rounded()))")
                .font(Rack.mono(6, weight: .bold))
                .foregroundStyle(tint.opacity(0.55)),
            at: CGPoint(x: size.width - 3, y: 2), anchor: .topTrailing)
    }
}
