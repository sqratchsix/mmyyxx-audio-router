import Foundation

/// Which parameter page the RV4's remote programmer is displaying. Lives
/// with the device settings rather than the app model, because each device
/// remembers its own.
enum FXEditPage: String, CaseIterable, Identifiable, Codable {
    case reverb, eq, gate

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum FXDeviceKind: String, Codable, CaseIterable, Identifiable {
    case reverb, delay, eq, analyzer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reverb:   return "RV4 Advanced Reverb"
        case .delay:    return "DL1 Delay Line"
        case .eq:       return "EQ5 Parametric EQ"
        case .analyzer: return "SA1 Spectrum Analyser"
        }
    }

    var shortName: String {
        switch self {
        case .reverb:   return "RV4"
        case .delay:    return "DL1"
        case .eq:       return "EQ5"
        case .analyzer: return "SA1"
        }
    }

    /// Front-panel height with the lower panel open. A collapsible device folds
    /// back to 1U, which is what `rackUnits(expanded:)` returns.
    var expandedUnits: Int {
        switch self {
        case .reverb:   return 3
        case .delay:    return 1
        case .eq:       return 3
        case .analyzer: return 3
        }
    }

    /// Whether the device has a lower panel to fold away. The DL1 is 1U already,
    /// so its open and closed heights are the same.
    var isCollapsible: Bool { expandedUnits > 1 }

    /// Rack units of front-panel height for a given open state.
    func rackUnits(expanded: Bool) -> Int {
        expanded ? expandedUnits : 1
    }

    /// True for devices that only observe the bus. The chain skips them, so a
    /// disabled analyser costs nothing and an enabled one changes no samples.
    var isPassive: Bool { self == .analyzer }
}

/// One device mounted in the rack. Both parameter blocks are carried regardless
/// of kind, so switching a slot's device type keeps whatever the other one had.
struct FXDeviceSettings: Equatable, Codable, Identifiable {
    /// Stable across reorders and removals, so SwiftUI identifies a device by
    /// which device it is rather than by where it currently sits. `UUID` is a
    /// 16-byte value type, so the struct stays plain-old-data.
    var id = UUID()
    var kind: FXDeviceKind = .reverb
    var enabled = true
    var reverb = FXParameters()
    var delay = DelayParameters()
    var eq = EQParameters()
    /// Which programmer page this device is showing. UI state, but it lives here
    /// so each device remembers its own, and the enum stores only a tag so the
    /// struct stays plain-old-data for the render thread's snapshot.
    var editPage: FXEditPage = .reverb
    /// Whether the lower panel is open. Same reasoning as `editPage`: it belongs
    /// to the device, so folding one closed and reordering the rack keeps it
    /// closed, and it survives a relaunch.
    var expanded = true

    init() {}
    init(kind: FXDeviceKind) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(FXDeviceKind.self, forKey: .kind) ?? .reverb
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        reverb = try c.decodeIfPresent(FXParameters.self, forKey: .reverb) ?? FXParameters()
        delay = try c.decodeIfPresent(DelayParameters.self, forKey: .delay) ?? DelayParameters()
        eq = try c.decodeIfPresent(EQParameters.self, forKey: .eq) ?? EQParameters()
        editPage = try c.decodeIfPresent(FXEditPage.self, forKey: .editPage) ?? .reverb
        // Absent in settings written before the panel could fold, and open is
        // what those racks were showing.
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
    }

    func normalized() -> FXDeviceSettings {
        var copy = self
        copy.reverb = reverb.normalized()
        copy.delay = delay.normalized()
        copy.eq = eq.normalized()
        return copy
    }
}

/// Fixed-capacity, plain-old-data view of the chain for the render thread.
///
/// Deliberately not an `Array`. Copying this struct is a memcpy; copying one
/// containing an array would retain and release a heap buffer, and releasing the
/// last reference would call `free` on the audio thread.
struct FXChainSnapshot: Equatable {
    static let maxDevices = 4

    var count = 0
    private var slot0 = FXDeviceSettings()
    private var slot1 = FXDeviceSettings()
    private var slot2 = FXDeviceSettings()
    private var slot3 = FXDeviceSettings()

    subscript(index: Int) -> FXDeviceSettings {
        get {
            switch index {
            case 0: return slot0
            case 1: return slot1
            case 2: return slot2
            default: return slot3
            }
        }
        set {
            switch index {
            case 0: slot0 = newValue
            case 1: slot1 = newValue
            case 2: slot2 = newValue
            default: slot3 = newValue
            }
        }
    }

    init() {}

    init(_ devices: [FXDeviceSettings]) {
        count = min(devices.count, Self.maxDevices)
        for index in 0..<count { self[index] = devices[index].normalized() }
    }

    /// True when anything in the chain would actually contribute.
    var isActive: Bool {
        for index in 0..<count where self[index].enabled { return true }
        return false
    }
}

/// The rack's signal path: devices in series, each processing the FX bus in
/// place.
///
/// Units are pooled per slot and allocated up front. A device added at runtime
/// must not cause the audio thread to allocate a delay line, so every slot owns
/// both a reverb and a delay from the start and simply uses whichever the
/// slot's current kind calls for.
final class FXChain {

    private var reverbs: [ReverbEngine] = []
    private var delays: [DelayUnit] = []
    private var eqs: [EQUnit] = []
    /// One analyser window per slot, so an SA1 sees the bus as it is where it is
    /// mounted: ahead of a reverb it shows the dry send, behind it the tail.
    let taps: [SpectrumTap]
    private var previousKinds = [FXDeviceKind?](repeating: nil, count: FXChainSnapshot.maxDevices)
    private var previousCount = 0

    init() {
        reverbs = (0..<FXChainSnapshot.maxDevices).map { _ in ReverbEngine() }
        delays = (0..<FXChainSnapshot.maxDevices).map { _ in DelayUnit() }
        eqs = (0..<FXChainSnapshot.maxDevices).map { _ in EQUnit() }
        taps = (0..<FXChainSnapshot.maxDevices).map { _ in SpectrumTap() }
    }

    func prepare(sampleRate: Double) {
        for unit in reverbs { unit.prepare(sampleRate: sampleRate) }
        for unit in delays { unit.prepare(sampleRate: sampleRate) }
        for unit in eqs { unit.prepare(sampleRate: sampleRate) }
        previousKinds = [FXDeviceKind?](repeating: nil, count: FXChainSnapshot.maxDevices)
        previousCount = 0
    }

    func reset() {
        for unit in reverbs { unit.reset() }
        for unit in delays { unit.reset() }
        for unit in eqs { unit.reset() }
    }

    /// Keep the analyser windows moving when the bus is not being processed at
    /// all, so a display reads silence rather than looping the last thing it saw.
    func silenceTaps(frames: Int, chain: FXChainSnapshot) {
        for index in 0..<chain.count where chain[index].kind == .analyzer {
            taps[index].writeSilence(count: frames)
        }
    }

    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 frames: Int,
                 chain: FXChainSnapshot) {

        for index in 0..<chain.count {
            let device = chain[index]

            // A slot that changed device type is holding another effect's tail.
            // Clearing it here is a buffer memset, not an allocation.
            if previousKinds[index] != device.kind {
                previousKinds[index] = device.kind
                switch device.kind {
                case .reverb:   reverbs[index].reset()
                case .delay:    delays[index].reset()
                case .eq:       eqs[index].reset()
                case .analyzer: break          // holds no tail
                }
            }

            // The analyser is passive, so it runs before the enabled check
            // rather than being skipped by it: switched off it publishes
            // silence, which is what its display should then show.
            if device.kind == .analyzer {
                if device.enabled {
                    taps[index].writeMix(left: left, right: right, count: frames)
                } else {
                    taps[index].writeSilence(count: frames)
                }
                continue
            }

            guard device.enabled else { continue }

            switch device.kind {
            case .reverb:
                reverbs[index].process(inputLeft: left, inputRight: right,
                                       outputLeft: left, outputRight: right,
                                       frames: frames, parameters: device.reverb)
            case .delay:
                delays[index].process(left: left, right: right,
                                      frames: frames, parameters: device.delay)
            case .eq:
                eqs[index].process(left: left, right: right,
                                   frames: frames, parameters: device.eq)
            case .analyzer:
                break                          // handled above, before the enable check
            }
        }

        // Slots that were removed keep their tails until they are used again.
        if chain.count < previousCount {
            for index in chain.count..<previousCount {
                reverbs[index].reset()
                delays[index].reset()
                eqs[index].reset()
                previousKinds[index] = nil
            }
        }
        previousCount = chain.count
    }
}
