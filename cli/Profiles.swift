/// Profiles: named bundles of settings ({ANC mode, noise level, EQ, multipoint,
/// volume}) saved and applied as a unit. Foundation-only (no IOBluetooth): the
/// pure frame-building + JSON load/save live here and unit-test without hardware;
/// the live-session apply is `Transport.applyProfile` in Composites.swift.
///
/// Storage is JSON (not TOML like the wire spec) because the binary reads AND
/// writes it at runtime — `profile save` — and Swift has no zero-dep TOML writer.
/// The file is git-tracked in the repo (versioned), default `~/code/personal/bose/
/// profiles.json`, overridable via `$BOSE_PROFILES`.

import Foundation

struct EqValues: Codable, Equatable {
    var bass: Int
    var mid: Int
    var treble: Int
}

/// A settings preset. Every field is optional — a profile only touches what it sets.
struct Profile: Codable, Equatable {
    var name: String
    var ancMode: String? = nil      // quiet / aware / custom1 / custom2
    var noiseLevel: Int? = nil      // 0 = max cancel … 10 = transparency; applied via the
                                    // 1F,06 RMW, only takes effect on adjustable custom modes (4/5)
    var ancDepth: Int? = nil        // DEPRECATED (inert): retained only so old profiles.json
                                    // files with the removed 1F,0A depth still decode (#83)
    var eq: EqValues? = nil
    var multipoint: Bool? = nil
    var volume: Int? = nil          // 0-31
    var pair: [String]? = nil       // optional multipoint pair [primary, secondary] (device
                                    // names) — applied FIRST via the `pair` composite (evict
                                    // others → secondary held → primary active), then any
                                    // settings. e.g. tv = {pair: [audikast, phone]}

    enum CodingKeys: String, CodingKey { case name, ancMode, noiseLevel, ancDepth, eq, multipoint, volume, pair }

    // Custom encode so unset fields are omitted (clean, human-editable JSON) rather
    // than written as nulls.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(ancMode, forKey: .ancMode)
        try c.encodeIfPresent(noiseLevel, forKey: .noiseLevel)
        try c.encodeIfPresent(ancDepth, forKey: .ancDepth)
        try c.encodeIfPresent(eq, forKey: .eq)
        try c.encodeIfPresent(multipoint, forKey: .multipoint)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encodeIfPresent(pair, forKey: .pair)
    }

    /// True when the profile sets any on-device SETTING (vs a pair-only profile like
    /// `tv`). Gates the `applyProfile` session so a pair-only profile isn't a failure.
    var hasDeviceSettings: Bool {
        ancMode != nil || noiseLevel != nil || eq != nil || multipoint != nil || volume != nil
    }

    /// One-line summary of the fields this profile sets (for `profile` listing).
    var summary: String {
        var parts: [String] = []
        if let m = ancMode { parts.append("anc \(m)") }
        if let n = noiseLevel { parts.append("noise \(n)") }
        if let e = eq { parts.append("eq \(e.bass)/\(e.mid)/\(e.treble)") }
        if let mp = multipoint { parts.append("mp \(mp ? "on" : "off")") }
        if let v = volume { parts.append("vol \(v)") }
        if let pr = pair, pr.count == 2 { parts.append("pair \(pr[0])+\(pr[1])") }
        return parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
    }

    /// Capture the current device state as a fully-populated profile.
    init(capturing s: HeadphoneState, name: String) {
        self.name = name
        self.ancMode = AncMode(rawValue: UInt8(truncatingIfNeeded: s.ancMode)).map { "\($0)" }
        // Capture the live noise level into the active `noiseLevel` field (not the inert
        // `ancDepth`). On replay it applies via the 1F,06 RMW where the mode is custom;
        // on a named/spatial mode `applyProfile` treats it as a no-op.
        self.noiseLevel = s.cncLevel
        self.eq = EqValues(bass: s.eq.bass, mid: s.eq.mid, treble: s.eq.treble)
        self.multipoint = s.multipointEnabled
        self.volume = s.volume
    }

    init(name: String, ancMode: String? = nil, noiseLevel: Int? = nil, ancDepth: Int? = nil,
         eq: EqValues? = nil, multipoint: Bool? = nil, volume: Int? = nil, pair: [String]? = nil) {
        self.name = name; self.ancMode = ancMode; self.noiseLevel = noiseLevel; self.ancDepth = ancDepth
        self.eq = eq; self.multipoint = multipoint; self.volume = volume; self.pair = pair
    }
}

struct ProfileStore: Codable {
    var profiles: [Profile]

    /// `$BOSE_PROFILES` → repo `profiles.json` (versioned) → `~/.config/bose/profiles.json`.
    static func defaultPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["BOSE_PROFILES"], !p.isEmpty { return p }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repo = "\(home)/code/personal/bose/profiles.json"
        if FileManager.default.fileExists(atPath: repo) { return repo }
        return "\(home)/.config/bose/profiles.json"
    }

    /// Load, returning an empty store for a missing/unreadable/invalid file.
    static func load(_ path: String) -> ProfileStore {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(ProfileStore.self, from: data) else {
            return ProfileStore(profiles: [])
        }
        return store
    }

    func save(_ path: String) throws {
        let enc = JSONEncoder()
        // .sortedKeys gives DETERMINISTIC output (stable across saves); the churn it
        // caused was only because the committed file wasn't in this form. We normalise
        // profiles.json to match + emit a trailing newline, so a `profile save`/`rm`
        // round-trip is now byte-stable (a no-op) against the committed file.
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(self)
        data.append(0x0A)  // trailing newline
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    func profile(named name: String) -> Profile? {
        profiles.first { $0.name.lowercased() == name.lowercased() }
    }

    mutating func upsert(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.name.lowercased() == p.name.lowercased() }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
    }
}

// MARK: - shared runtime state dir
//
// The dir for runtime state files (e.g. the pair picker's priority.json). Mirrors
// the profiles resolution: $BOSE_STATE_DIR override (for tests) → ~/.config/bose.
func boseStateDir() -> String {
    if let d = ProcessInfo.processInfo.environment["BOSE_STATE_DIR"], !d.isEmpty { return d }
    return FileManager.default.homeDirectoryForCurrentUser.path + "/.config/bose"
}

/// Map an ANC-mode name to its byte, single-sourced from the generated `AncMode` enum.
func ancModeByte(_ name: String) -> UInt8? {
    switch name.lowercased() {
    case "quiet": return AncMode.quiet.rawValue
    case "aware": return AncMode.aware.rawValue
    case "immersion": return AncMode.immersion.rawValue
    case "cinema": return AncMode.cinema.rawValue
    case "custom1": return AncMode.custom1.rawValue
    case "custom2": return AncMode.custom2.rawValue
    default: return nil
    }
}

/// Build the ordered SET frames a profile applies. ANC-depth is a read-modify-write,
/// so the live CNC config is passed in; if `currentCnc` is nil the depth frame is
/// skipped (the caller reads it within the session). Pure — unit-tested.
func profileFrames(_ p: Profile, currentCnc: CncConfig?) -> [[UInt8]] {
    var frames: [[UInt8]] = []
    if let m = p.ancMode, let b = ancModeByte(m) { frames.append(BMAP.setAncMode(mode: b)) }
    if let v = p.volume { frames.append(BMAP.setVolume(level: UInt8(max(0, min(31, v))))) }
    if let mp = p.multipoint { frames.append(BMAP.setMultipoint(state: mp ? 0x07 : 0x00)) }
    if let e = p.eq {
        let clamp: (Int) -> Int8 = { Int8(max(-10, min(10, $0))) }
        frames.append(BMAP.setEqBand(value: clamp(e.bass), band: EqBand.bass.rawValue))
        frames.append(BMAP.setEqBand(value: clamp(e.mid), band: EqBand.mid.rawValue))
        frames.append(BMAP.setEqBand(value: clamp(e.treble), band: EqBand.treble.rawValue))
    }
    // NB: profiles do NOT set a CNC noise level. The level is a per-mode property set
    // via the 1F,06 AudioModesModeConfig RMW (`bose anc-level`), only on adjustable
    // custom modes. The old 1F,0A `ancDepth` write disabled ANC entirely (#83) and is
    // gone. `Profile.ancDepth`/`currentCnc` are retained only so old profiles.json
    // files still decode; the level is never applied here.
    _ = currentCnc
    return frames
}
