import SwiftUI

/// A 19-inch rack: two mounting rails with a column of devices between them.
///
/// Device heights are whole rack units and never stretch, so a 1U device looks
/// like a 1U device no matter how tall the window gets.
struct RackView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            rackHeader

            HStack(spacing: 0) {
                RackRail()
                VStack(spacing: Rack.deviceGap) {
                    ForEach(Array(model.fxChain.enumerated()), id: \.element.id) { index, device in
                        deviceView(index: index, kind: device.kind)
                    }
                    if !model.rackIsFull { emptyBay }
                }
                .padding(.vertical, Rack.deviceGap)
                .frame(minWidth: Rack.minimumDeviceWidth, maxWidth: .infinity)
                RackRail()
            }
            .background(Color.black.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.black.opacity(0.8), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }

    @ViewBuilder
    private func deviceView(index: Int, kind: FXDeviceKind) -> some View {
        switch kind {
        case .reverb:
            RV7000View(device: model.deviceBinding(index), index: index, meters: model.meterModel)
        case .delay:
            DelayDeviceView(device: model.deviceBinding(index), index: index)
        }
    }

    private var rackHeader: some View {
        HStack(spacing: 8) {
            Text("FX RACK")
                .font(Theme.label(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)

            Text("\(model.fxChain.count)/\(FXChainSnapshot.maxDevices) devices · in series")
                .font(Theme.numeric(8))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            FXLadder(meters: model.meterModel, channels: [0, 1], segments: 8, segmentWidth: 4)

            Text("RETURN")
                .font(Theme.label(7, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.75))
    }

    private var emptyBay: some View {
        Menu {
            ForEach(FXDeviceKind.allCases) { kind in
                Button("\(kind.displayName)  ·  \(kind.rackUnits)U") { model.addDevice(kind) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill").font(.system(size: 11))
                Text("Add device")
                    .font(Theme.label(10, weight: .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: Rack.unit)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.white.opacity(0.14))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

/// Mounting rail: a dark strip with the regular pattern of holes that gives a
/// rack its scale.
struct RackRail: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [Color(white: 0.20), Color(white: 0.09)]),
                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))

            // Three holes per rack unit, the real spacing.
            let spacing = Rack.unit / 3
            var y = spacing / 2
            while y < size.height {
                let hole = CGRect(x: size.width / 2 - 2.5, y: y - 3.5, width: 5, height: 7)
                context.fill(Path(roundedRect: hole, cornerRadius: 1.5), with: .color(.black.opacity(0.85)))
                context.stroke(Path(roundedRect: hole, cornerRadius: 1.5),
                               with: .color(.white.opacity(0.10)), lineWidth: 0.5)
                y += spacing
            }
        }
        .frame(width: Rack.railWidth)
    }
}

/// Shared chrome for a mounted device: the ears with their screws, plus the
/// controls for taking it out or moving it in the chain.
struct RackEars<Content: View>: View {
    let index: Int
    let units: Int
    let title: String
    @Binding var enabled: Bool
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            RackEar()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RackEar()
        }
        // Whole rack units, and never taller: a 1U device has to look 1U at any
        // window size.
        .frame(height: Rack.unit * CGFloat(units))
        .clipped()
        .overlay(alignment: .topTrailing) { controls.opacity(hovering ? 1 : 0) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var controls: some View {
        HStack(spacing: 3) {
            iconButton(enabled ? "power" : "power.circle") { enabled.toggle() }
            iconButton("chevron.up") { model.moveDevice(at: index, by: -1) }
            iconButton("chevron.down") { model.moveDevice(at: index, by: 1) }
            iconButton("xmark") { model.removeDevice(at: index) }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .padding(4)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Rack.engraved)
                .frame(width: 15, height: 13)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}

/// 1U stereo delay, in the spirit of Reason's DDL-1.
struct DelayDeviceView: View {
    @Binding var device: FXDeviceSettings
    let index: Int

    var body: some View {
        RackEars(index: index, units: FXDeviceKind.delay.rackUnits,
                 title: "DL1", enabled: $device.enabled) {
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DL1")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(Rack.engraved)
                        Text("Delay Line")
                            .font(Rack.caption(7))
                            .foregroundStyle(Rack.engraved.opacity(0.8))
                    }
                    .frame(width: 84, alignment: .leading)

                    Text(String(format: "%.0f ms", device.delay.timeMs))
                        .font(Rack.mono(11, weight: .bold))
                        .foregroundStyle(Rack.screenInk)
                        .shadow(color: Rack.screenInk.opacity(0.6), radius: 3)
                        .frame(width: 74)
                        .padding(.vertical, 4)
                        .background(Rack.screen)
                        .clipShape(RoundedRectangle(cornerRadius: 2))

                    knob("Time", value: Binding(
                        get: { logNorm(device.delay.timeMs, 5, 2000) },
                        set: { device.delay.timeMs = logValue($0, 5, 2000) }))

                    knob("Feedback", value: Binding(
                        get: { Double(device.delay.feedback / 0.95) },
                        set: { device.delay.feedback = Float($0) * 0.95 }))

                    knob("Damp", value: Binding(
                        get: { logNorm(device.delay.dampHz, 200, 18000) },
                        set: { device.delay.dampHz = logValue($0, 200, 18000) }))

                    knob("Pan", value: Binding(
                        get: { Double((device.delay.pan + 1) / 2) },
                        set: { device.delay.pan = Float($0) * 2 - 1 }), reset: 0.5)

                    knob("Level", value: Binding(
                        get: { Double(device.delay.level) },
                        set: { device.delay.level = Float($0) }))

                    Button { device.delay.pingPong.toggle() } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(device.delay.pingPong ? Rack.led : Rack.ledOff)
                                .frame(width: 6, height: 6)
                                .shadow(color: device.delay.pingPong ? Rack.led.opacity(0.9) : .clear,
                                        radius: 3)
                            Text("Ping Pong")
                                .font(Rack.caption(7))
                                .foregroundStyle(Rack.engraved)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .opacity(device.enabled ? 1 : 0.45)
            }
            .frame(maxHeight: .infinity)
            .background(
                LinearGradient(colors: [Rack.panel, Rack.panelDark],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func knob(_ title: String, value: Binding<Double>, reset: Double? = nil) -> some View {
        VStack(spacing: 2) {
            Knob(value: value, diameter: 26, resetValue: reset)
            Text(title)
                .font(Rack.caption(7))
                .foregroundStyle(Rack.engraved)
        }
        .frame(width: 50)
    }

    private func logNorm(_ value: Float, _ low: Float, _ high: Float) -> Double {
        Double(log(min(max(value, low), high) / low) / log(high / low))
    }

    private func logValue(_ n: Double, _ low: Float, _ high: Float) -> Float {
        low * pow(high / low, Float(min(max(n, 0), 1)))
    }
}

/// A device's mounting ear: runs the full height of the panel with a screw at
/// the top and bottom, the way a rack device is actually fastened to the rails.
struct RackEar: View {
    var body: some View {
        VStack(spacing: 0) {
            RackScrew()
            Spacer(minLength: 0)
            RackScrew()
        }
        .padding(.vertical, 7)
        .frame(width: Rack.earWidth)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Rack.panel, Rack.panelDark],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
        }
    }
}

struct RackScrew: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Color(white: 0.62), Color(white: 0.26)],
                               center: .topLeading, startRadius: 0, endRadius: 9)
            )
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 7, height: 1.4)
                    .rotationEffect(.degrees(38))
            )
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
    }
}
