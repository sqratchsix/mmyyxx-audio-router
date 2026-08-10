import Foundation

/// One row in the remote programmer's display: a name, a formatted value, and
/// the mapping between the knob's 0...1 travel and the underlying parameter.
///
/// Describing the pages as data means the panel renders any of them without
/// knowing what a gate or an EQ is.
struct FXParameterSpec: Identifiable {
    let id: String
    let name: String
    let format: (FXParameters) -> String
    let normalized: (FXParameters) -> Double
    let apply: (inout FXParameters, Double) -> Void
    var resetValue: Double?
    var isActive: (FXParameters) -> Bool = { _ in true }
}

private func linear(_ n: Double, _ low: Float, _ high: Float) -> Float {
    low + Float(min(max(n, 0), 1)) * (high - low)
}

private func linearNorm(_ value: Float, _ low: Float, _ high: Float) -> Double {
    Double(min(max((value - low) / (high - low), 0), 1))
}

/// Frequencies and times need a log mapping, otherwise the whole useful range
/// bunches into the last few degrees of the knob.
private func logarithmic(_ n: Double, _ low: Float, _ high: Float) -> Float {
    low * pow(high / low, Float(min(max(n, 0), 1)))
}

private func logarithmicNorm(_ value: Float, _ low: Float, _ high: Float) -> Double {
    let clamped = min(max(value, low), high)
    return Double(log(clamped / low) / log(high / low))
}

private func formatFrequency(_ hz: Float) -> String {
    hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
}

private func formatTime(_ ms: Float) -> String {
    ms >= 1000 ? String(format: "%.2f s", ms / 1000) : String(format: "%.0f ms", ms)
}

enum FXPages {

    // MARK: Shared controls, reused across pages

    private static let dryWet = FXParameterSpec(
        id: "drywet", name: "Dry - Wet",
        format: { "\(Int($0.dryWet * 127))" },
        normalized: { Double($0.dryWet) },
        apply: { $0.dryWet = linear($1, 0, 1) },
        resetValue: 1
    )

    private static let decay = FXParameterSpec(
        id: "decay", name: "Decay",
        format: { formatTime($0.decaySeconds * 1000) },
        normalized: { logarithmicNorm($0.decaySeconds, 0.1, 60) },
        apply: { $0.decaySeconds = logarithmic($1, 0.1, 60) }
    )

    private static let hfDamp = FXParameterSpec(
        id: "hfdamp", name: "HF Damp",
        format: { "\(Int($0.hfDamp * 127))" },
        normalized: { Double($0.hfDamp) },
        apply: { $0.hfDamp = linear($1, 0, 1) }
    )

    private static let predelay = FXParameterSpec(
        id: "predelay", name: "Pre Delay",
        format: { formatTime($0.predelayMs) },
        normalized: { linearNorm($0.predelayMs, 0, 250) },
        apply: { $0.predelayMs = linear($1, 0, 250) }
    )

    private static let diffusion = FXParameterSpec(
        id: "diffusion", name: "Diffusion",
        format: { "\(Int($0.diffusion * 127))" },
        normalized: { Double($0.diffusion) },
        apply: { $0.diffusion = linear($1, 0, 1) },
        isActive: { $0.algorithm.usesNetwork }
    )

    // MARK: Pages

    static func left(_ page: FXEditPage) -> [FXParameterSpec] {
        switch page {
        case .reverb:
            return [
                FXParameterSpec(
                    id: "algorithm", name: "Algorithm",
                    format: { $0.algorithm.displayName },
                    normalized: {
                        Double($0.algorithm.rawValue) / Double(ReverbAlgorithm.allCases.count - 1)
                    },
                    apply: { parameters, n in
                        let count = ReverbAlgorithm.allCases.count
                        let index = min(max(Int((n * Double(count - 1)).rounded()), 0), count - 1)
                        parameters.algorithm = ReverbAlgorithm(rawValue: index) ?? .hall
                    }
                ),
                predelay,
                diffusion,
                FXParameterSpec(
                    id: "lfdamp", name: "LF Damp",
                    format: { formatFrequency($0.lfDampHz) },
                    normalized: { logarithmicNorm($0.lfDampHz, 20, 1000) },
                    apply: { $0.lfDampHz = logarithmic($1, 20, 1000) },
                    isActive: { $0.algorithm.usesNetwork }
                ),
            ]

        case .eq:
            return [
                FXParameterSpec(
                    id: "eqenable", name: "EQ Enable",
                    format: { $0.eqEnabled ? "On" : "Off" },
                    normalized: { $0.eqEnabled ? 1 : 0 },
                    apply: { $0.eqEnabled = $1 >= 0.5 }
                ),
                FXParameterSpec(
                    id: "lowfreq", name: "Low Freq",
                    format: { formatFrequency($0.eqLowFrequency) },
                    normalized: { logarithmicNorm($0.eqLowFrequency, 20, 2000) },
                    apply: { $0.eqLowFrequency = logarithmic($1, 20, 2000) },
                    isActive: { $0.eqEnabled }
                ),
                FXParameterSpec(
                    id: "lowgain", name: "Low Gain",
                    format: { String(format: "%+.1f dB", $0.eqLowGainDB) },
                    normalized: { linearNorm($0.eqLowGainDB, -18, 18) },
                    apply: { $0.eqLowGainDB = linear($1, -18, 18) },
                    resetValue: 0.5,
                    isActive: { $0.eqEnabled }
                ),
                FXParameterSpec(
                    id: "hieq", name: "Hi EQ",
                    format: { String(format: "%+.1f dB", $0.hiEQDB) },
                    normalized: { linearNorm($0.hiEQDB, -18, 18) },
                    apply: { $0.hiEQDB = linear($1, -18, 18) },
                    resetValue: 0.5
                ),
            ]

        case .gate:
            return [
                FXParameterSpec(
                    id: "gateenable", name: "Gate Enable",
                    format: { $0.gateEnabled ? "On" : "Off" },
                    normalized: { $0.gateEnabled ? 1 : 0 },
                    apply: { $0.gateEnabled = $1 >= 0.5 }
                ),
                FXParameterSpec(
                    id: "threshold", name: "Threshold",
                    format: { String(format: "%.0f dB", $0.gateThresholdDB) },
                    normalized: { linearNorm($0.gateThresholdDB, -60, 0) },
                    apply: { $0.gateThresholdDB = linear($1, -60, 0) },
                    isActive: { $0.gateEnabled }
                ),
                FXParameterSpec(
                    id: "hold", name: "Hold",
                    format: { formatTime($0.gateHoldMs) },
                    normalized: { linearNorm($0.gateHoldMs, 0, 2000) },
                    apply: { $0.gateHoldMs = linear($1, 0, 2000) },
                    isActive: { $0.gateEnabled }
                ),
                FXParameterSpec(
                    id: "gatedecay", name: "Gate Decay",
                    format: { formatTime($0.gateDecayMs) },
                    normalized: { logarithmicNorm($0.gateDecayMs, 5, 4000) },
                    apply: { $0.gateDecayMs = logarithmic($1, 5, 4000) },
                    isActive: { $0.gateEnabled }
                ),
            ]
        }
    }

    static func right(_ page: FXEditPage) -> [FXParameterSpec] {
        switch page {
        case .reverb:
            return [
                FXParameterSpec(
                    id: "echotime", name: "Tap Delay",
                    format: { formatTime($0.echoTimeMs) },
                    normalized: { logarithmicNorm($0.echoTimeMs, 10, 2000) },
                    apply: { $0.echoTimeMs = logarithmic($1, 10, 2000) },
                    isActive: { !$0.algorithm.usesNetwork || $0.algorithm == .reverse }
                ),
                FXParameterSpec(
                    id: "feedback", name: "Tap Level",
                    format: { String(format: "%.0f%%", $0.echoFeedback * 100) },
                    normalized: { Double($0.echoFeedback / 0.95) },
                    apply: { $0.echoFeedback = linear($1, 0, 0.95) },
                    isActive: { !$0.algorithm.usesNetwork }
                ),
                FXParameterSpec(
                    id: "taps", name: "Tap Count",
                    format: { "\($0.tapCount)" },
                    normalized: { Double($0.tapCount - 1) / 7 },
                    apply: { $0.tapCount = Int(($1 * 7).rounded()) + 1 },
                    isActive: { $0.algorithm == .multiTap }
                ),
                dryWet,
            ]

        case .eq:
            return [
                FXParameterSpec(
                    id: "hifreq", name: "Hi Freq",
                    format: { formatFrequency($0.eqHighFrequency) },
                    normalized: { logarithmicNorm($0.eqHighFrequency, 200, 18000) },
                    apply: { $0.eqHighFrequency = logarithmic($1, 200, 18000) },
                    isActive: { $0.eqEnabled }
                ),
                FXParameterSpec(
                    id: "higain", name: "Hi Gain",
                    format: { String(format: "%+.1f dB", $0.eqHighGainDB) },
                    normalized: { linearNorm($0.eqHighGainDB, -18, 18) },
                    apply: { $0.eqHighGainDB = linear($1, -18, 18) },
                    resetValue: 0.5,
                    isActive: { $0.eqEnabled }
                ),
                decay,
                dryWet,
            ]

        case .gate:
            return [hfDamp, predelay, decay, dryWet]
        }
    }
}
