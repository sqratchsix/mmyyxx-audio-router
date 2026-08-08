import Foundation

/// Everything adjustable about one input strip. Keeping these together rather
/// than in parallel arrays is what makes it impossible for a source's gain to be
/// indexed out of step with its mute.
struct SourceSettings: Codable, Equatable {
    var gainDB: Float
    var pan: Float
    var muted: Bool
    var sends: [Bool]

    init(gainDB: Float, pan: Float, muted: Bool, sends: [Bool]) {
        self.gainDB = gainDB
        self.pan = pan
        self.muted = muted
        self.sends = sends
    }

    // Swift's synthesized decoder fails outright on a missing key, which would
    // turn "this file predates a new field" into "reset the user's whole mix".
    // Decoding every field optionally keeps old documents readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try container.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        pan = try container.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        sends = try container.decodeIfPresent([Bool].self, forKey: .sends)
            ?? Array(repeating: true, count: SharedState.pairCount)
    }

    /// Hardware inputs arrive silent and muted: plugging in a live microphone
    /// should never come up hot through the monitors. System audio is the one
    /// source the user is asking for by launching the app, so it starts open.
    static func standard(for source: MixerSource) -> SourceSettings {
        let isSystem = source.id == "system"
        return SourceSettings(
            gainDB: isSystem ? 0 : LevelMath.silenceDB,
            pan: 0,
            muted: !isSystem,
            sends: Array(repeating: true, count: SharedState.pairCount)
        )
    }

    /// Repair anything that arrived from disk with the wrong shape, so a stale
    /// or hand-edited file cannot crash the render path.
    func normalized() -> SourceSettings {
        var copy = self
        copy.gainDB = min(max(gainDB.isFinite ? gainDB : 0, LevelMath.silenceDB), 6)
        copy.pan = min(max(pan.isFinite ? pan : 0, -1), 1)
        if copy.sends.count != SharedState.pairCount {
            var fixed = Array(repeating: true, count: SharedState.pairCount)
            for index in 0..<min(copy.sends.count, SharedState.pairCount) {
                fixed[index] = copy.sends[index]
            }
            copy.sends = fixed
        }
        return copy
    }
}

/// Master settings for one output pair.
struct PairSettings: Codable, Equatable {
    var gainDB: Float = 0
    var muted: Bool = false

    init(gainDB: Float = 0, muted: Bool = false) {
        self.gainDB = gainDB
        self.muted = muted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try container.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

    func normalized() -> PairSettings {
        PairSettings(gainDB: min(max(gainDB.isFinite ? gainDB : 0, LevelMath.silenceDB), 6),
                     muted: muted)
    }
}

/// The on-disk document.
struct PersistedSettings: Codable {
    var version = 1
    var selectedOutputUID: String?
    var pairs: [PairSettings] = Array(repeating: PairSettings(), count: SharedState.pairCount)
    /// Keyed by `MixerSource.id`, which is stable across relaunches and across
    /// device rescans, so a strip keeps its level when the source list is rebuilt.
    var sources: [String: SourceSettings] = [:]
    init(selectedOutputUID: String? = nil,
         pairs: [PairSettings] = Array(repeating: PairSettings(), count: SharedState.pairCount),
         sources: [String: SourceSettings] = [:]) {
        self.selectedOutputUID = selectedOutputUID
        self.pairs = pairs
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selectedOutputUID = try container.decodeIfPresent(String.self, forKey: .selectedOutputUID)
        pairs = try container.decodeIfPresent([PairSettings].self, forKey: .pairs)
            ?? Array(repeating: PairSettings(), count: SharedState.pairCount)
        sources = try container.decodeIfPresent([String: SourceSettings].self, forKey: .sources) ?? [:]
    }

    func normalized() -> PersistedSettings {
        var copy = self
        var pairs = Array(repeating: PairSettings(), count: SharedState.pairCount)
        for index in 0..<min(copy.pairs.count, SharedState.pairCount) {
            pairs[index] = copy.pairs[index].normalized()
        }
        copy.pairs = pairs
        copy.sources = copy.sources.mapValues { $0.normalized() }
        return copy
    }
}

/// Reads and writes the settings document in Application Support.
///
/// Writes are atomic, so a crash mid-save leaves the previous file intact rather
/// than a truncated one that fails to parse on next launch.
struct SettingsStore {

    private let url: URL

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jaredsimon.mmyyxx") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("settings.json")
    }

    var location: URL { url }

    func load() -> PersistedSettings {
        guard let data = try? Data(contentsOf: url) else { return PersistedSettings() }
        guard let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) else {
            Diagnostics.log("settings file could not be decoded; falling back to defaults")
            return PersistedSettings()
        }
        return decoded.normalized()
    }

    func save(_ settings: PersistedSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Diagnostics.log("could not write settings: \(error.localizedDescription)")
        }
    }
}
