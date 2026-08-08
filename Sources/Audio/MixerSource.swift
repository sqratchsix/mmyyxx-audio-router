import CoreAudio
import Foundation

/// One input the mixer can route: the system audio pair, or a hardware input
/// channel on the interface.
struct MixerSource: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let deviceUID: String
    /// Zero-based channel index within that device's input scope.
    let firstChannel: Int
    let channelCount: Int

    var isStereo: Bool { channelCount == 2 }
}

enum MixerSourceDiscovery {

    /// Build the source list: system audio first, then the interface's own
    /// analog inputs.
    ///
    /// Loopback channels are deliberately excluded. On the M4 they return what
    /// the computer is sending to the interface, which is exactly what this app
    /// writes, so routing one back into the mix would close a feedback loop.
    static func sources(loopbackDevice: AudioDeviceInfo?,
                        interface: AudioDeviceInfo?) -> [MixerSource] {
        var sources: [MixerSource] = []

        if let loopbackDevice {
            sources.append(MixerSource(
                id: "system",
                name: "System",
                detail: loopbackDevice.name,
                deviceUID: loopbackDevice.uid,
                firstChannel: 0,
                channelCount: min(2, loopbackDevice.inputChannels)
            ))
        }

        if let interface {
            for channel in 0..<interface.inputChannels {
                let driverName = AudioDevices.channelName(interface.id,
                                                          scope: kAudioDevicePropertyScopeInput,
                                                          channel: channel + 1)
                if let driverName, driverName.localizedCaseInsensitiveContains("loopback") {
                    continue
                }
                sources.append(MixerSource(
                    id: "\(interface.uid)#\(channel)",
                    name: driverName ?? "In \(channel + 1)",
                    detail: interface.name,
                    deviceUID: interface.uid,
                    firstChannel: channel,
                    channelCount: 1
                ))
                if sources.count >= SharedState.maxSources { break }
            }
        }

        return Array(sources.prefix(SharedState.maxSources))
    }
}
