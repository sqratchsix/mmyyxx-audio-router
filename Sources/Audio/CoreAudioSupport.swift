import CoreAudio
import Foundation

/// Thin wrappers over the AudioObject property API, which is otherwise four
/// lines of ceremony per read.
enum CA {

    static func addr(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func dataSize(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return nil }
        return size
    }

    /// Read a fixed-layout value (UInt32, Float64, AudioObjectID, ...).
    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type) -> T? {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, out) == noErr else { return nil }
        return out.pointee
    }

    static func setValue<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type) -> [T] {
        guard let size = dataSize(object, address), size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        var a = address
        var byteCount = size
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &byteCount, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Total channel count on a scope, summed across every stream in the
    /// device's buffer list.
    static func channelCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let address = addr(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let size = dataSize(object, address), size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        var a = address
        var byteCount = size
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &byteCount, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// A physical or virtual audio device as the app cares about it.
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var isBlackHole: Bool { name.localizedCaseInsensitiveContains("blackhole") }

    /// Aggregates and multi-output devices make poor routing targets: they are
    /// usually built *from* the device we actually want.
    var isAggregate: Bool {
        name.localizedCaseInsensitiveContains("aggregate")
            || name.localizedCaseInsensitiveContains("multi-output")
    }
}

enum AudioDevices {

    static func all() -> [AudioDeviceInfo] {
        let ids = CA.array(AudioObjectID(kAudioObjectSystemObject),
                           CA.addr(kAudioHardwarePropertyDevices),
                           of: AudioObjectID.self)
        return ids.compactMap { info(for: $0) }
    }

    static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CA.string(id, CA.addr(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = CA.string(id, CA.addr(kAudioObjectPropertyName)) ?? uid
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: name,
            inputChannels: CA.channelCount(id, scope: kAudioDevicePropertyScopeInput),
            outputChannels: CA.channelCount(id, scope: kAudioDevicePropertyScopeOutput)
        )
    }

    static func device(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    /// Candidates for the output side: real devices with at least four outputs.
    static func multiOutputCandidates() -> [AudioDeviceInfo] {
        all().filter { $0.outputChannels >= 4 && !$0.isAggregate }
    }

    /// The loopback device carrying system audio into the app.
    static func loopbackDevice() -> AudioDeviceInfo? {
        all().first { $0.isBlackHole && $0.inputChannels >= 2 }
    }

    static func systemDefaultOutput() -> AudioDeviceInfo? {
        guard let id = CA.value(AudioObjectID(kAudioObjectSystemObject),
                                CA.addr(kAudioHardwarePropertyDefaultOutputDevice),
                                as: AudioObjectID.self) else { return nil }
        return info(for: id)
    }

    @discardableResult
    static func setSystemDefaultOutput(_ device: AudioDeviceInfo) -> Bool {
        CA.setValue(AudioObjectID(kAudioObjectSystemObject),
                    CA.addr(kAudioHardwarePropertyDefaultOutputDevice),
                    device.id) == noErr
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        CA.value(id, CA.addr(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
        CA.setValue(id, CA.addr(kAudioDevicePropertyNominalSampleRate), Float64(rate)) == noErr
    }

    /// The driver's own name for a channel, one-based. Interfaces that bother to
    /// set this give far better labels than "Input 3" ("In 3", "Loopback Mix 1").
    static func channelName(_ id: AudioObjectID, scope: AudioObjectPropertyScope, channel: Int) -> String? {
        var address = CA.addr(kAudioObjectPropertyElementName, scope: scope, element: UInt32(channel))
        guard AudioObjectHasProperty(id, &address) else { return nil }
        guard let name = CA.string(id, address), !name.isEmpty else { return nil }
        return name
    }

    /// Per-channel software volume, where the device offers one.
    ///
    /// Interfaces typically expose this only on their "preferred stereo pair",
    /// since that is the pair the macOS volume slider drives. The remaining
    /// outputs run at unity with no control at all, so an interface can sit at
    /// two very different levels across its output pairs.
    static func outputVolume(_ id: AudioObjectID, channel: UInt32) -> Float? {
        var address = CA.addr(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        return CA.value(id, address, as: Float32.self)
    }

    @discardableResult
    static func setOutputVolume(_ id: AudioObjectID, channel: UInt32, _ value: Float) -> Bool {
        var address = CA.addr(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        return CA.setValue(id, address, Float32(value)) == noErr
    }

    /// The driver's own idea of the current volume in dB. Worth reading rather
    /// than deriving from the scalar: BlackHole maps its slider linearly across
    /// a -64...0 dB range, so 20*log10(scalar) is nowhere near what it applies.
    static func outputVolumeDecibels(_ id: AudioObjectID, channel: UInt32 = 0) -> Float? {
        var address = CA.addr(kAudioDevicePropertyVolumeDecibels,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        return CA.value(id, address, as: Float32.self)
    }

    static func hasSettableOutputVolume(_ id: AudioObjectID, channel: UInt32 = 0) -> Bool {
        var address = CA.addr(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    /// Watch a device's master output volume. Fires on the main queue whenever
    /// anything changes it, including the keyboard volume keys.
    static func observeOutputVolume(_ id: AudioObjectID,
                                    channel: UInt32 = 0,
                                    handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var address = CA.addr(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        return block
    }

    static func stopObservingOutputVolume(_ id: AudioObjectID,
                                          channel: UInt32 = 0,
                                          block: @escaping AudioObjectPropertyListenerBlock) {
        var address = CA.addr(kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: channel)
        AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
    }

    static func supportedSampleRates(_ id: AudioObjectID) -> [ClosedRange<Double>] {
        CA.array(id, CA.addr(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
            .map { $0.mMinimum...$0.mMaximum }
    }
}
