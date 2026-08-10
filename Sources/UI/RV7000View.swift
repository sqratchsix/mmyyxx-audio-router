import SwiftUI

enum Rack {
    static let panel = Color(red: 0.404, green: 0.416, blue: 0.545)     // blue-grey face
    static let panelDark = Color(red: 0.310, green: 0.322, blue: 0.443)
    static let chassis = Color(red: 0.153, green: 0.157, blue: 0.196)
    static let screen = Color(red: 0.086, green: 0.031, blue: 0.031)
    static let screenInk = Color(red: 1.0, green: 0.298, blue: 0.208)
    static let screenDim = Color(red: 0.60, green: 0.16, blue: 0.11)
    static let led = Color(red: 1.0, green: 0.184, blue: 0.153)
    static let ledOff = Color(red: 0.31, green: 0.10, blue: 0.10)
    static let engraved = Color(red: 0.86, green: 0.87, blue: 0.92)
    /// Send controls pick up the rack's accent so the mixer and the effect read
    /// as one signal path rather than two unrelated panels.
    static let sendTint = Color(red: 1.0, green: 0.44, blue: 0.32)

    /// One rack unit. Devices are a whole number of these and never stretch:
    /// a 1U panel has to look like a 1U panel at any window size.
    static let unit: CGFloat = 80
    static let railWidth: CGFloat = 15
    static let deviceGap: CGFloat = 3

    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func caption(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// A homage to Reason's RV7000: a 1U main panel with the headline controls, and
/// a Remote Programmer below carrying everything else on a red LCD.
struct RV7000View: View {
    @Binding var device: FXDeviceSettings
    let index: Int
    let meters: MeterModel

    /// Convenience so the body reads the same as before the rack existed.
    private var fx: FXParameters { device.reverb }

    var body: some View {
        RackEars(index: index, units: FXDeviceKind.reverb.rackUnits,
                 title: "RV7000", enabled: $device.enabled) {
            VStack(spacing: 0) {
                mainPanel
                    .frame(height: Rack.unit)
                Rectangle().fill(Color.black.opacity(0.8)).frame(height: 2)
                remoteProgrammer
                    .frame(height: Rack.unit * 2 - 2)
            }
            .opacity(device.enabled ? 1 : 0.45)
            .background(Rack.chassis)
        }
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        HStack(spacing: 0) {
            RackScrewColumn()

            HStack(spacing: 14) {
                powerSection
                divider
                patchSection
                divider
                enableSection
                divider
                mainKnobs
                divider
                dryWetSection
                outputMeter
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            RackScrewColumn()
        }
        .background(
            LinearGradient(colors: [Rack.panel, Rack.panelDark],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.28))
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    /// Three-position Bypass / On / Off switch, plus the input ladder.
    private var powerSection: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(["Bypass", "On", "Off"], id: \.self) { label in
                    let isOn = (label == "On" && device.reverb.enabled) || (label == "Off" && !device.reverb.enabled)
                    Button {
                        device.reverb.enabled = (label == "On")
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isOn ? Rack.led : Rack.ledOff)
                                .frame(width: 5, height: 5)
                                .shadow(color: isOn ? Rack.led.opacity(0.8) : .clear, radius: 3)
                            Text(label)
                                .font(Rack.caption(8))
                                .foregroundStyle(Rack.engraved)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Send-level ladder, so you can see the bus is receiving something.
            FXLadder(meters: meters, channels: [0], segments: 8, segmentWidth: 8)
        }
    }

    private var patchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("mmyyxx FX")
                .font(Rack.mono(8))
                .foregroundStyle(Color(white: 0.15))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(width: 132, alignment: .leading)
                .background(Color(red: 0.93, green: 0.91, blue: 0.80))
                .clipShape(RoundedRectangle(cornerRadius: 2))

            HStack(spacing: 5) {
                Text(device.reverb.algorithm.displayName.uppercased())
                    .font(Rack.mono(10, weight: .bold))
                    .foregroundStyle(Rack.screenInk)
                    .shadow(color: Rack.screenInk.opacity(0.6), radius: 3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(width: 132, alignment: .leading)
                    .background(Rack.screen)
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                VStack(spacing: 2) {
                    stepButton(up: true)
                    stepButton(up: false)
                }
            }

            Text("◀ Remote Programmer")
                .font(Rack.caption(7))
                .foregroundStyle(Rack.engraved.opacity(0.85))
        }
    }

    private func stepButton(up: Bool) -> some View {
        Button {
            let all = ReverbAlgorithm.allCases
            let index = device.reverb.algorithm.rawValue + (up ? 1 : -1)
            device.reverb.algorithm = all[min(max(index, 0), all.count - 1)]
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 6, weight: .black))
                .foregroundStyle(Rack.engraved)
                .frame(width: 16, height: 9)
                .background(Rack.panelDark)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            enableRow(title: "EQ Enable", isOn: device.reverb.eqEnabled) {
                device.reverb.eqEnabled.toggle()
            }
            enableRow(title: "Gate Enable", isOn: device.reverb.gateEnabled) {
                device.reverb.gateEnabled.toggle()
            }
        }
    }

    private func enableRow(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 26, height: 13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Circle()
                .fill(isOn ? Rack.led : Rack.ledOff)
                .frame(width: 6, height: 6)
                .shadow(color: isOn ? Rack.led.opacity(0.9) : .clear, radius: 3)

            Text(title)
                .font(Rack.caption(8))
                .foregroundStyle(Rack.engraved)
        }
    }

    private var mainKnobs: some View {
        HStack(spacing: 14) {
            labelledKnob("Decay", spec: FXPages.right(.eq)[2], diameter: 28)
            labelledKnob("HF Damp", spec: FXPages.right(.gate)[0], diameter: 28)
            labelledKnob("Hi EQ", spec: FXPages.left(.eq)[3], diameter: 28)
        }
    }

    private var dryWetSection: some View {
        labelledKnob("Dry - Wet", spec: FXPages.right(.reverb)[3], diameter: 28)
    }

    private func labelledKnob(_ title: String, spec: FXParameterSpec, diameter: CGFloat) -> some View {
        VStack(spacing: 3) {
            Knob(
                value: Binding(
                    get: { spec.normalized(fx) },
                    set: { spec.apply(&device.reverb, $0) }
                ),
                diameter: diameter,
                resetValue: spec.resetValue,
                isActive: spec.isActive(fx)
            )
            Text(title)
                .font(Rack.caption(8))
                .foregroundStyle(Rack.engraved)
            Text(spec.format(fx))
                .font(Rack.mono(7))
                .foregroundStyle(Rack.engraved.opacity(0.7))
        }
        .frame(width: 58)
    }

    private var outputMeter: some View {
        HStack(spacing: 8) {
            FXLadder(meters: meters, channels: [0, 1])

            VStack(alignment: .leading, spacing: 0) {
                Text("RV7000")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Rack.engraved)
                Text("Advanced")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.8))
                Text("Reverb")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved.opacity(0.8))
            }
        }
    }

    // MARK: - Remote programmer

    private var remoteProgrammer: some View {
        HStack(spacing: 10) {
            programmerBranding

            HStack(spacing: 8) {
                knobColumn(FXPages.left(device.editPage))
                display
                knobColumn(FXPages.right(device.editPage))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Rack.chassis, Color.black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var programmerBranding: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("RV7000")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(Rack.engraved)
                Text("Remote Programmer")
                    .font(Rack.caption(6))
                    .foregroundStyle(Rack.engraved.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(FXEditPage.allCases) { page in
                    Button { device.editPage = page } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(device.editPage == page ? Rack.led : Rack.ledOff)
                                .frame(width: 5, height: 5)
                                .shadow(color: device.editPage == page ? Rack.led.opacity(0.8) : .clear,
                                        radius: 3)
                            Text(page.rawValue.capitalized)
                                .font(Rack.caption(8))
                                .foregroundStyle(Rack.engraved)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                let all = FXEditPage.allCases
                let index = (all.firstIndex(of: device.editPage) ?? 0) + 1
                device.editPage = all[index % all.count]
            } label: {
                Text("Edit Mode")
                    .font(Rack.caption(7))
                    .foregroundStyle(Rack.engraved)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Rack.panelDark)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 122, alignment: .leading)
        .background(
            LinearGradient(colors: [Rack.panel, Rack.panelDark],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func knobColumn(_ specs: [FXParameterSpec]) -> some View {
        VStack(spacing: 7) {
            ForEach(specs) { spec in
                Knob(
                    value: Binding(
                        get: { spec.normalized(fx) },
                        set: { spec.apply(&device.reverb, $0) }
                    ),
                    diameter: 20,
                    resetValue: spec.resetValue,
                    isActive: spec.isActive(fx)
                )
            }
        }
    }

    private var display: some View {
        HStack(spacing: 0) {
            parameterColumn(FXPages.left(device.editPage), alignment: .leading)
            FXGraph(parameters: fx)
                .frame(maxWidth: .infinity)
            parameterColumn(FXPages.right(device.editPage), alignment: .trailing)
        }
        .padding(7)
        .frame(maxHeight: .infinity)
        .background(Rack.screen)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.black.opacity(0.9), lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func parameterColumn(_ specs: [FXParameterSpec],
                                 alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            ForEach(specs) { spec in
                let active = spec.isActive(fx)
                VStack(alignment: alignment, spacing: 0) {
                    Text(spec.name)
                        .font(Rack.mono(8))
                        .foregroundStyle(active ? Rack.screenInk : Rack.screenDim)
                    Text(spec.format(fx))
                        .font(Rack.mono(8, weight: .bold))
                        .foregroundStyle(active ? Rack.screenInk : Rack.screenDim)
                        .shadow(color: active ? Rack.screenInk.opacity(0.5) : .clear, radius: 2)
                }
                .frame(width: 84, alignment: alignment == .leading ? .leading : .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }
}

/// The centre of the display. Draws whatever shape actually describes the
/// current algorithm: a decay envelope for the network reverbs, discrete taps
/// for the delay-based ones, a swell for reverse.
struct FXGraph: View {
    let parameters: FXParameters

    private static let spanSeconds: Float = 5

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 2
            let plot = CGRect(x: inset, y: inset,
                              width: size.width - inset * 2,
                              height: size.height - inset * 2 - 10)

            // Frame and second markers, as on the hardware.
            var frame = Path()
            frame.addRect(plot)
            context.stroke(frame, with: .color(Rack.screenInk.opacity(0.8)), lineWidth: 1)

            for second in 1...4 {
                let x = plot.minX + plot.width * CGFloat(Float(second) / Self.spanSeconds)
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(Rack.screenInk.opacity(0.45)), lineWidth: 1)
            }
            for second in 0...5 {
                let x = plot.minX + plot.width * CGFloat(Float(second) / Self.spanSeconds)
                context.draw(
                    Text("\(second)s").font(Rack.mono(7)).foregroundStyle(Rack.screenInk.opacity(0.85)),
                    at: CGPoint(x: x + 7, y: plot.maxY + 6)
                )
            }

            switch parameters.algorithm {
            case .echo, .multiTap:
                drawTaps(context: context, plot: plot)
            case .reverse:
                drawReverse(context: context, plot: plot)
            default:
                drawDecay(context: context, plot: plot)
            }
        }
    }

    private func drawDecay(context: GraphicsContext, plot: CGRect) {
        // Envelope of the tail: e^(-3t/RT60), the same curve the feedback gains
        // are derived from, so the picture matches what you hear.
        var path = Path()
        let steps = 120
        for step in 0...steps {
            let t = Float(step) / Float(steps) * Self.spanSeconds
            let amplitude = exp(-3 * t / max(parameters.decaySeconds, 0.05))
            let x = plot.minX + plot.width * CGFloat(t / Self.spanSeconds)
            let y = plot.maxY - plot.height * CGFloat(amplitude)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(Rack.screenInk), lineWidth: 1.4)

        if parameters.predelayMs > 1 {
            let x = plot.minX + plot.width * CGFloat(parameters.predelayMs / 1000 / Self.spanSeconds)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: plot.minY))
            marker.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(marker, with: .color(Rack.screenInk.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }

    private func drawTaps(context: GraphicsContext, plot: CGRect) {
        let spacing = parameters.echoTimeMs / 1000
        let count = parameters.algorithm == .multiTap ? parameters.tapCount : FXParameters.maxTaps * 2
        for tap in 0..<count {
            let t = spacing * Float(tap + 1)
            guard t <= Self.spanSeconds else { break }
            let amplitude = pow(parameters.echoFeedback, Float(tap))
            guard amplitude > 0.01 else { break }
            let x = plot.minX + plot.width * CGFloat(t / Self.spanSeconds)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.maxY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY - plot.height * CGFloat(amplitude)))
            context.stroke(line, with: .color(Rack.screenInk), lineWidth: 1.4)
        }
    }

    private func drawReverse(context: GraphicsContext, plot: CGRect) {
        var path = Path()
        let window = parameters.echoTimeMs / 1000
        let steps = 120
        for step in 0...steps {
            let t = Float(step) / Float(steps) * Self.spanSeconds
            let phase = window > 0 ? fmod(t, window) / window : 0
            let amplitude = phase * exp(-1.2 * t / max(parameters.decaySeconds, 0.05))
            let x = plot.minX + plot.width * CGFloat(t / Self.spanSeconds)
            let y = plot.maxY - plot.height * CGFloat(amplitude)
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(Rack.screenInk), lineWidth: 1.4)
    }
}
