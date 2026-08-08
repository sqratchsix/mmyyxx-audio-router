import CoreAudio
import Foundation

/// A private aggregate device combining the loopback input and the multi-output
/// interface into a single clock domain.
///
/// This is the load-bearing trick of the whole app. BlackHole and the M4 are
/// separate devices with independent clocks, so servicing them from two IOProcs
/// would need a ring buffer and a resampler to absorb drift. Wrapping them in
/// one aggregate hands that problem to CoreAudio: the interface becomes clock
/// master, the loopback device gets drift compensation, and we get a single
/// callback with every input and output channel already sample-aligned.
///
/// `IsPrivate` keeps it out of Audio MIDI Setup and the Sound menu, so the
/// user's device list stays clean and nothing else can select it by accident.
final class AggregateDevice {

    let id: AudioObjectID
    /// First channel index of each sub-device within the aggregate's input scope.
    private(set) var inputOffsets: [String: Int] = [:]
    /// First channel index of each sub-device within the aggregate's output scope.
    private(set) var outputOffsets: [String: Int] = [:]

    private static let uid = "com.jaredsimon.mmyyxx.aggregate"

    enum Failure: LocalizedError {
        case creationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let status):
                return "Could not create the aggregate audio device (OSStatus \(status))."
            }
        }
    }

    /// - Parameters:
    ///   - output: the interface that owns the speaker outputs; also the clock master.
    ///   - input: the loopback device carrying system audio.
    init(output: AudioDeviceInfo, input: AudioDeviceInfo) throws {
        // Sub-device order defines channel order inside the aggregate. Output
        // device first means M4 outputs land at 0...3 and its own inputs at
        // 0...7, which is the layout the input-mixer mode will want later.
        let subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: output.uid,
             kAudioSubDeviceDriftCompensationKey as String: 0],
            [kAudioSubDeviceUIDKey as String: input.uid,
             kAudioSubDeviceDriftCompensationKey as String: 1],
        ]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MOTU mmyyxx Engine",
            kAudioAggregateDeviceUIDKey as String: Self.uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: output.uid,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw Failure.creationFailed(status)
        }
        self.id = deviceID

        computeOffsets(order: [output, input])
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(id)
    }

    /// Walk the sub-devices in list order, accumulating channel counts so we can
    /// translate "M4 output 3" into an index into the aggregate's buffer list.
    private func computeOffsets(order: [AudioDeviceInfo]) {
        var inputCursor = 0
        var outputCursor = 0
        for device in order {
            // Re-read live counts rather than trusting the cached info, since the
            // aggregate may have renegotiated the sub-device's stream format.
            let live = AudioDevices.device(uid: device.uid) ?? device
            inputOffsets[device.uid] = inputCursor
            outputOffsets[device.uid] = outputCursor
            inputCursor += live.inputChannels
            outputCursor += live.outputChannels
        }
    }

    /// Align both sub-devices before starting, so the aggregate does not have to
    /// resample. Returns the rate actually in force.
    @discardableResult
    func matchSampleRate(to rate: Double, devices: [AudioDeviceInfo]) -> Double {
        for device in devices where AudioDevices.nominalSampleRate(device.id) != rate {
            let supported = AudioDevices.supportedSampleRates(device.id)
            guard supported.contains(where: { $0.contains(rate) }) else { continue }
            AudioDevices.setNominalSampleRate(device.id, rate)
        }
        AudioDevices.setNominalSampleRate(id, rate)
        return AudioDevices.nominalSampleRate(id) ?? rate
    }

    var bufferFrameSize: Int {
        Int(CA.value(id, CA.addr(kAudioDevicePropertyBufferFrameSize), as: UInt32.self) ?? 0)
    }
}
