import Foundation

/// Which parameter page the RV7000's remote programmer is displaying. Lives
/// with the device settings rather than the app model, because each device
/// remembers its own.
enum FXEditPage: String, CaseIterable, Identifiable, Codable {
    case reverb, eq, gate

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum FXDeviceKind: String, Codable, CaseIterable, Identifiable {
    case reverb, delay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reverb: return "RV7000 Advanced Reverb"
        case .delay:  return "DL1 Delay Line"
        }
    }

    var shortName: String {
        switch self {
        case .reverb: return "RV7000"
        case .delay:  return "DL1"
        }
    }

    /// Rack units of front-panel height.
    var rackUnits: Int {
        switch self {
        case .reverb: return 3
        case .delay:  return 1
        }
    }
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
    /// Which programmer page this device is showing. UI state, but it lives here
    /// so each device remembers its own, and the enum stores only a tag so the
    /// struct stays plain-old-data for the render thread's snapshot.
    var editPage: FXEditPage = .reverb

    init() {}
    init(kind: FXDeviceKind) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(FXDeviceKind.self, forKey: .kind) ?? .reverb
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        reverb = try c.decodeIfPresent(FXParameters.self, forKey: .reverb) ?? FXParameters()
        delay = try c.decodeIfPresent(DelayParameters.self, forKey: .delay) ?? DelayParameters()
        editPage = try c.decodeIfPresent(FXEditPage.self, forKey: .editPage) ?? .reverb
    }

    func normalized() -> FXDeviceSettings {
        var copy = self
        copy.reverb = reverb.normalized()
        copy.delay = delay.normalized()
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
    private var previousKinds = [FXDeviceKind?](repeating: nil, count: FXChainSnapshot.maxDevices)
    private var previousCount = 0

    init() {
        reverbs = (0..<FXChainSnapshot.maxDevices).map { _ in ReverbEngine() }
        delays = (0..<FXChainSnapshot.maxDevices).map { _ in DelayUnit() }
    }

    func prepare(sampleRate: Double) {
        for unit in reverbs { unit.prepare(sampleRate: sampleRate) }
        for unit in delays { unit.prepare(sampleRate: sampleRate) }
        previousKinds = [FXDeviceKind?](repeating: nil, count: FXChainSnapshot.maxDevices)
        previousCount = 0
    }

    func reset() {
        for unit in reverbs { unit.reset() }
        for unit in delays { unit.reset() }
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
                case .reverb: reverbs[index].reset()
                case .delay:  delays[index].reset()
                }
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
            }
        }

        // Slots that were removed keep their tails until they are used again.
        if chain.count < previousCount {
            for index in chain.count..<previousCount {
                reverbs[index].reset()
                delays[index].reset()
                previousKinds[index] = nil
            }
        }
        previousCount = chain.count
    }
}
