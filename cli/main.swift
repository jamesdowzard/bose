/// bose: CLI for the Bose QC Ultra 2, rebuilt on the shared generated layer.
///
/// v2 rewrite (Phase 4): every command routes through the GENERATED builders
/// (`BMAP.*` from bmap.toml) + the SAME hand-written `Transport`/`Composites`/
/// `Parsers` the macOS menu-bar app compiles. There is NO inline byte parsing here —
/// the v1 sin (cmdStatus/cmdVolume hand-rolled frames and drifted from the library,
/// e.g. volume's operator) is gone. CLI and app cannot drift: they build the exact
/// same source files (see cli/build.sh + macos/build.sh).
///
/// Shared files compiled into this binary:
///   protocol/generated/BMAP.generated.swift   — wire builders + enums
///   protocol/generated/Devices.generated.swift — headphone MAC + device map
///   macos/BoseControl/Transport.swift          — IOBluetooth RFCOMM transport
///   macos/BoseControl/Parsers.swift            — pure response decoders
///   macos/BoseControl/Composites.swift         — connectedDevices / cncLevel / getAllState

import Foundation

let transport = Transport()

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

func macForName(_ name: String) -> [UInt8] {
    guard let mac = BoseDeviceMap.mac(name) else { fail("unknown device: \(name)") }
    return mac
}

func macString(_ mac: [UInt8]) -> String {
    mac.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func displayName(forMac mac: [UInt8]) -> String {
    BoseDeviceMap.name(forMac: mac) ?? macString(mac)
}

/// Display name for an audio-ACTIVE (05,01) device. `bose` only ever runs on
/// the Mac, and the Bose firmware reports the Mac's own audio link under a
/// non-resolvable private address (e.g. 0C:96:E6:05:3E:F2) that does NOT match the
/// static [devices.mac] controller address — while every OTHER device reports its
/// real, mappable address. So an active entry that maps to no known device is the
/// local Mac's own link; render it as "mac". (#81)
func activeName(forMac mac: [UInt8]) -> String {
    BoseDeviceMap.name(forMac: mac) ?? "mac"
}

// MARK: - Commands

/// status / s — full snapshot in ONE RFCOMM session via the getAllState composite.
func cmdStatus() {
    guard let s = transport.getAllState() else { fail("headphones not reachable") }

    let connectedNames = s.connectedDevices.map { displayName(forMac: $0) }
    let slot1 = connectedNames.count >= 1 ? connectedNames[0] : "—"
    let slot2 = connectedNames.count >= 2 ? connectedNames[1] : "—"

    if !connectedNames.isEmpty {
        print("Connected: \(connectedNames.joined(separator: ", "))")
    }
    print("Slots:    \(slot1) | \(slot2)")
    print("Battery:  \(s.batteryLevel)%\(s.batteryCharging ? " ⚡" : "")")
    print("ANC:      \(ancModeName(s.ancMode))")
    print("Volume:   \(s.volume)/\(s.volumeMax)")
    print("EQ:       bass \(s.eq.bass)  mid \(s.eq.mid)  treble \(s.eq.treble)")
    if !s.firmware.isEmpty { print("Firmware: \(s.firmware)") }
}

/// info — the COMPLETE HeadphoneState from getAllState (one RFCOMM session).
/// `status` is the quick subset; `info` dumps everything the bulk read returns
/// (identity, power, full audio config, and the audio-active device list).
/// No new protocol work — pure formatting over the existing composite.
func cmdInfo() {
    guard let s = transport.getAllState() else { fail("headphones not reachable") }

    // Left-pad a 12-char label so values line up in a column.
    func row(_ key: String, _ value: String) {
        print("\(key.padding(toLength: 12, withPad: " ", startingAt: 0))\(value)")
    }

    // Identity
    if !s.productName.isEmpty  { row("Product:", s.productName) }
    if !s.deviceName.isEmpty   { row("Name:", s.deviceName) }
    if !s.firmware.isEmpty     { row("Firmware:", s.firmware) }
    if !s.serialNumber.isEmpty { row("Serial:", s.serialNumber) }
    if !s.platform.isEmpty     { row("Platform:", s.platform) }
    if !s.codename.isEmpty     { row("Codename:", s.codename) }

    // Power
    row("Battery:", "\(s.batteryLevel)%\(s.batteryCharging ? " ⚡" : "")")
    if !s.autoOffTimer.isEmpty {
        // Encoding unverified over RFCOMM (read-only field) — show raw bytes.
        row("Auto-off:", s.autoOffTimer.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    // Audio
    row("ANC:", ancModeName(s.ancMode))
    row("Noise level:", "\(s.cncLevel)/10")
    row("Volume:", "\(s.volume)/\(s.volumeMax)")
    row("EQ:", "bass \(s.eq.bass)  mid \(s.eq.mid)  treble \(s.eq.treble)")
    if !s.audioCodec.isEmpty { row("Codec:", s.audioCodec) }
    row("Multipoint:", s.multipointEnabled ? "on" : "off")

    // Audio-active devices (05,01); first entry is the active sink. Unmapped == the
    // local Mac's own private link address (see activeName).
    let names = s.connectedDevices.map { activeName(forMac: $0) }
    if names.isEmpty {
        row("Devices:", "none")
    } else {
        row("Devices:", "\(names[0]) (active)")
        for n in names.dropFirst() { row("", n) }
    }
}

/// info --json — the same getAllState snapshot as `info`, plus the per-device 3-state
/// (active/connected/offline) from getDeviceStates, emitted as one JSON object. This
/// is the read seam the windowed macOS app consumes — the app shells `bose` and
/// never touches RFCOMM itself, so it can't reintroduce the polling/transport bugs.
/// Pure formatting over existing composites — no protocol/spec change.
///
/// Cached-first (#148): a live read requires RFCOMM, and RFCOMM to a Mac that holds
/// neither multipoint slot means a multi-second BT-Classic PAGE of the headphones —
/// the exact probe-from-a-non-sink the transport rules warn about (it can glitch
/// audio on the active sink; #69-era). So with no ACL link this emits the cached
/// last-good snapshot stamped `reachable:false` + `cachedAt`/`ageSeconds` instead of
/// paging — instant and radio-silent. `--page` forces the old live-read behaviour
/// (an EXPLICIT user action, e.g. the app's ⌘R). With ACL up the read is live as
/// ever and rewrites the cache. `connected` describes the headphone state a snapshot
/// captured; `reachable` describes THIS Mac's link right now — the app keys off
/// `reachable` for its staleness banner and never wipes known state over it.
func cmdInfoJSON(forcePage: Bool = false) {
    func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { print("{\"connected\":false}"); return }
        print(str)
    }

    /// No usable live path (no ACL and not forced, or the live read failed):
    /// cached snapshot if we have one, else the bare disconnected object.
    func emitFallback() {
        emit(StateCache.staleOutput() ?? ["connected": false, StateCache.reachableKey: false])
    }

    // The gate: ACL presence is a free, zero-radio local read (IOBluetooth device
    // state — no channel, no page). Only a live read past this point touches radio.
    if !forcePage && !transport.isHeadphoneConnected() {
        emitFallback()
        return
    }

    // Bulk state AND device grid from ONE warm RFCOMM session. The active sink comes from
    // parseAllState's warm 05,01 read; the idle (ACL-up-but-not-sink) devices from
    // per-device 04,05 probes in the SAME session. Reading both in one session is what
    // keeps either from being lost to the cold-second-session quirk that a separate
    // getDeviceStates call hit — it dropped every tile to offline despite `bose devices`
    // showing the mac active (#132). `bose devices` stays on getDeviceStates: as a
    // standalone session-1 read it's already warm, and it skips the bulk reads it doesn't need.
    guard let (s, idleDevices, modeInfo) = transport.getAllStateWithDevices(
        query: BoseDeviceMap.knownDevices.map { $0.mac }
    ) else {
        // Live read failed (page refused / link blip). Serve the cache rather than a
        // bare connected:false so one miss can't wipe a known-good dashboard.
        emitFallback()
        return
    }

    // Per-device 3-state, resolved by NAME (same logic as cmdDevices, #81). Active wins
    // over idle when a device resolves to both.
    var deviceStates: [String: String] = [:]
    let active = Set(s.connectedDevices.map { activeName(forMac: $0) })
    let idle = Set(idleDevices.map { displayName(forMac: $0) }).subtracting(active)
    for dev in BoseDeviceMap.knownDevices {
        deviceStates[dev.name] = active.contains(dev.name) ? "active"
                               : idle.contains(dev.name) ? "connected" : "offline"
    }

    // Active mode's noise config (1F,06) — drives the app's noise slider. Read in the SAME
    // warm session as the bulk state above (folded into getAllStateWithDevices), so it no
    // longer hits the cold-second-session quirk that blanked it. `noiseAdjustable` (cncMutable)
    // gates the slider so a level write can never disable ANC (#83). nil → slider disabled.
    var mode: [String: Any] = ["noiseAdjustable": false, "spatialAdjustable": false]
    if let cfg = modeInfo.active {
        mode = [
            "modeName": cfg.displayName,
            "modeIndex": Int(cfg.index),
            "noiseLevel": Int(cfg.cncLevel),
            "noiseAdjustable": cfg.cncMutable,
            "spatial": spatialName(Int(cfg.spatial)),
            "spatialAdjustable": cfg.spatialMutable,
        ]
    }
    // Stored names of the two custom slots → the app labels the C1/C2 buttons with them
    // (falling back to "C1"/"C2" when unset, i.e. "None"). Empty string = use the fallback.
    func customName(_ idx: Int) -> String {
        let n = modeInfo.customNames[idx] ?? ""
        return n == "None" ? "" : n
    }

    var out: [String: Any] = [
        "connected": true,
        StateCache.reachableKey: true,
        "deviceName": s.deviceName.isEmpty ? "verBosita" : s.deviceName,
        "firmware": s.firmware,
        "batteryLevel": s.batteryLevel,
        "batteryCharging": s.batteryCharging,
        "ancMode": s.ancMode,
        "volume": s.volume,
        "volumeMax": s.volumeMax,
        "eq": ["bass": s.eq.bass, "mid": s.eq.mid, "treble": s.eq.treble],
        "multipoint": s.multipointEnabled,
        "autoPlayPause": s.autoPlayPause,
        "autoAnswer": s.autoAnswer,
        "favorites": s.favorites,
        "devices": deviceStates,
        "custom1Name": customName(4),
        "custom2Name": customName(5),
    ]
    out.merge(mode) { _, new in new }
    StateCache.save(out)   // the shared last-good snapshot every front-end paints from
    emit(out)
}

func ancModeName(_ mode: Int) -> String {
    AncMode(rawValue: UInt8(truncatingIfNeeded: mode))
        .map { "\($0)" } ?? "unknown(\(mode))"
}

/// presence [--timeout s] [--json] — PASSIVE BLE advert scan (receive-only, zero
/// packets to the headphones — safe from a non-slot Mac, no audio-glitch risk).
/// Distinguishes "on & nearby" from "off/away" without RFCOMM. Fast when present
/// (~4 adverts/sec); the timeout only bounds the not-present case.
func cmdPresence(_ a: [String]) {
    var timeout = 4.0
    if let i = a.firstIndex(of: "--timeout"), i + 1 < a.count, let t = Double(a[i + 1]) {
        timeout = min(15, max(0.5, t))
    }
    let hit = PresenceScanner().scan(timeout: timeout)
    if a.contains("--json") {
        var obj: [String: Any] = ["present": hit != nil]
        if let h = hit { obj["rssi"] = h.rssi; obj["name"] = h.name }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { print(str) } else { print("{\"present\":false}") }
    } else if let h = hit {
        print("present (\(h.name.isEmpty ? "bose mfr advert" : h.name), rssi \(h.rssi))")
    } else {
        print("not seen")
    }
}

/// battery / b
func cmdBattery() {
    guard let r = transport.oneShot(BMAP.getBattery()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("headphones not reachable") }
    let level = min(100, max(0, Int(r[4])))
    let charging = r.count >= 8 ? r[7] != 0 : false
    print("\(level)%\(charging ? " ⚡" : "")")
}

/// anc [mode]
func cmdAnc(_ mode: String?) {
    if let mode = mode {
        let modeByte: UInt8
        switch mode.lowercased() {
        case "quiet": modeByte = AncMode.quiet.rawValue
        case "aware": modeByte = AncMode.aware.rawValue
        case "immersion": modeByte = AncMode.immersion.rawValue
        case "cinema": modeByte = AncMode.cinema.rawValue
        case "custom1": modeByte = AncMode.custom1.rawValue
        case "custom2": modeByte = AncMode.custom2.rawValue
        // Bare mode slot index (0-5): 0 quiet, 1 aware, 2 immersion, 3 cinema (fixed),
        // 4/5 custom (adjustable — the slots whose noise level `anc-level` can set).
        // `info`/`anc-level` show names.
        case let s where UInt8(s).map({ $0 <= 5 }) == true: modeByte = UInt8(s)!
        default: fail("unknown ANC mode: \(mode) (quiet/aware/immersion/cinema/custom1/custom2, or a slot index 0-5)")
        }
        // Set + read-back in ONE session. A separate oneShot for the verify-GET
        // would open a second channel back-to-back and intermittently return nil
        // (the 300ms-drain firmware quirk) — a false "not reachable" despite the
        // set landing. One channel, two sends: the proven applyProfile pattern.
        let r = transport.session { ch, t -> [UInt8]? in
            guard t.send(ch, BMAP.setAncMode(mode: modeByte)) != nil else { return nil }
            return t.send(ch, BMAP.getAncMode())
        } ?? nil
        guard let r = r, r.count >= 5, r[2] == OP_RESP_BYTE else { fail("failed to set ANC mode") }
        print("ANC: \(ancModeName(Int(r[4])))")
        return
    }
    guard let r = transport.oneShot(BMAP.getAncMode()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("headphones not reachable") }
    print("ANC: \(ancModeName(Int(r[4])))")
}

/// anc-level [0-10] — get/set the ACTIVE mode's CNC noise level via the correct
/// AudioModesModeConfig (1F,06) read-modify-write. 0 = max cancellation, 10 = full
/// transparency. ANC stays anchored to the mode (never the 255/off the old 1F,0A
/// `anc-depth` caused, #83). Refuses on a fixed-level mode (Quiet/Aware/spatial).
func cmdAncLevel(_ arg: String?) {
    if let arg = arg {
        guard let level = Int(arg), (0...10).contains(level) else {
            fail("anc-level must be 0-10 (0 = max cancellation, 10 = transparency)")
        }
        switch transport.setActiveModeLevel(level) {
        case .ok(let name, let lvl):
            print("\(name): noise level \(lvl)/10  (0 = max cancel … 10 = transparent)")
        case .fixed(let name):
            fail("\(name)'s noise level is fixed — switch to a custom (adjustable) mode to set a level")
        case .unreachable:
            fail("headphones not reachable")
        }
        return
    }
    guard let cfg = transport.readActiveModeConfig() else { fail("headphones not reachable") }
    print("\(cfg.displayName): noise level \(cfg.cncLevel)/10\(cfg.cncMutable ? "" : " (fixed)")")
}

/// Immersive Audio (spatial) mode names ↔ byte: 0 off, 1 Still, 2 Motion.
let spatialNames = ["off", "still", "motion"]
func spatialName(_ v: Int) -> String { (0..<spatialNames.count).contains(v) ? spatialNames[v] : "off" }

/// spatial [off|still|motion] — Immersive Audio on the ACTIVE mode (1F,06 RMW). Bare =
/// read. Settable only on the custom (spatialMutable) modes; named modes are fixed
/// (Immersion = Motion, Cinema = Still). The global 05,0F function is FuncNotSupp here.
func cmdSpatial(_ arg: String?) {
    if let arg = arg {
        guard let value = spatialNames.firstIndex(of: arg.lowercased()) else {
            fail("spatial must be off | still | motion")
        }
        switch transport.setActiveModeSpatial(value) {
        case .ok(let name, let spatial):
            print("\(name): Immersive Audio \(spatialName(spatial))")
        case .fixed(let name):
            fail("\(name)'s Immersive Audio is fixed — switch to a custom mode to set it (Immersion = Motion, Cinema = Still)")
        case .unreachable:
            fail("headphones not reachable")
        }
        return
    }
    guard let cfg = transport.readActiveModeConfig() else { fail("headphones not reachable") }
    print("\(cfg.displayName): Immersive Audio \(spatialName(Int(cfg.spatial)))\(cfg.spatialMutable ? "" : " (fixed)")")
}

/// mode-name [--slot <4|5>] [name] — get/rename a custom mode's name (1F,06 RMW on the
/// 32-byte name field). Only the custom slots (4/5, userConfigurable) can be renamed; the
/// named presets are locked. With `--slot N` the target is slot N (4 = C1, 5 = C2) and the
/// active ANC mode is left untouched — the Mac app uses this to rename C1/C2 in place.
/// Without `--slot`, the ACTIVE mode is targeted (must already be a custom slot). The name
/// persists on-device and shows on the C1/C2 buttons + in the Bose app.
func cmdModeName(slot: Int?, name: String?) {
    if let slot = slot, slot != 4 && slot != 5 { fail("--slot must be 4 (C1) or 5 (C2)") }
    guard let name = name, !name.isEmpty else {
        if let slot = slot {
            guard let info = transport.readModeInfo() else { fail("headphones not reachable") }
            print(info.customNames[slot] ?? "None")
        } else {
            guard let cfg = transport.readActiveModeConfig() else { fail("headphones not reachable") }
            print("\(cfg.displayName)\(cfg.userConfigurable ? "" : " (preset — name locked)")")
        }
        return
    }
    let result = slot.map { transport.setModeName(slot: $0, name: name) }
        ?? transport.setActiveModeName(name)
    switch result {
    case .ok(let n):       print("mode renamed: \(n)")
    case .notCustom:       fail(slot != nil
                                ? "slot \(slot!) is not a custom mode — only C1/C2 (4/5) can be renamed"
                                : "only the custom modes (C1/C2) can be renamed — switch to one first")
    case .unreachable:     fail("headphones not reachable")
    }
}

/// name [new name] — get/set the headphone name. SET is `01,02,06,{len},00,{utf8}`
/// (max 30 UTF-8 bytes): the generated builder emits only the [block,func,op]
/// header, so the length-prefixed body is hand-assembled here (mirrors Android
/// `BoseProtocol.setDeviceName`).
func cmdName(_ newName: String?) {
    if let newName = newName {
        let nameBytes = Array(newName.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 30 else {
            fail("name must be 1-30 UTF-8 bytes")
        }
        let header = BMAP.setDeviceName()           // [0x01, 0x02, 0x06, 0x00]
        let frame = [header[0], header[1], header[2], UInt8(nameBytes.count + 1), 0x00] + nameBytes
        guard transport.oneShot(frame) != nil else { fail("failed to set name") }
    }
    guard let r = transport.oneShot([0x01, 0x02, 0x01, 0x00]),
          r.count >= 6, r[2] == OP_RESP_BYTE else { fail("name query failed") }
    print("Name: \(parseString(r, from: 5))")
}

/// profile [name | save <name> | rm <name>] — list, apply, save, or remove a settings
/// preset. A preset bundles {ANC mode, noise level, EQ, multipoint, volume}; applying
/// sends only the fields a preset defines, in ONE RFCOMM session. Presets live in a
/// git-tracked JSON file (see Profiles.swift); `save` snapshots the current state.
func cmdProfile(_ a: [String]) {
    let path = ProfileStore.defaultPath()
    var store = ProfileStore.load(path)

    if a.isEmpty {
        if store.profiles.isEmpty {
            print("No profiles. Save one: bose profile save <name>")
        } else {
            print("Profiles (\(path)):")
            for p in store.profiles { print("  \(p.name)\(p.summary)") }
        }
        return
    }

    switch a[0].lowercased() {
    case "--json":
        // Machine-readable list for the Mac app's profile chips. Pure file read —
        // no radio.
        let list = store.profiles.map { ["name": $0.name, "summary": $0.summary] }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { print(str) } else { print("[]") }
    case "save":
        guard a.count >= 2 else { fail("usage: bose profile save <name>") }
        let name = a[1...].joined(separator: " ")
        guard let s = transport.getAllState() else { fail("headphones not reachable") }
        store.upsert(Profile(capturing: s, name: name))
        do { try store.save(path) } catch { fail("could not write \(path): \(error)") }
        print("Saved profile '\(name)'\(Profile(capturing: s, name: name).summary)")

    case "rm", "remove", "delete":
        guard a.count >= 2 else { fail("usage: bose profile rm <name>") }
        let name = a[1...].joined(separator: " ")
        guard store.profile(named: name) != nil else { fail("unknown profile: \(name)") }
        store.profiles.removeAll { $0.name.lowercased() == name.lowercased() }
        do { try store.save(path) } catch { fail("could not write \(path): \(error)") }
        print("Removed profile '\(name)'")

    default:
        let name = a.joined(separator: " ")
        guard let p = store.profile(named: name) else {
            fail("unknown profile: \(name) (list: bose profile)")
        }
        // Connection first: a profile's `pair` reroutes the multipoint slots via the
        // same evict → secondary(held) → primary(active) composite as `bose pair`,
        // BEFORE any settings land (settings write to the headphones regardless of
        // which devices hold the slots). A pair-only profile (e.g. `tv`) then skips
        // the settings session entirely — no settings is not a failure.
        if let pr = p.pair {
            guard pr.count == 2 else { fail("profile '\(name)': pair needs exactly [primary, secondary]") }
            cmdPair(pr[0], pr[1])
        }
        if p.hasDeviceSettings {
            guard transport.applyProfile(p) else { fail("failed to apply '\(name)'") }
        }
        print("Applied '\(name)'\(p.summary)")
    }
}

/// devices — known devices in three states (one RFCOMM session):
///   ● active     — audio sink (getConnectedDevices, 05,01 ground truth)
///   ○ connected  — ACL up but not the active sink (per-device getDeviceInfo, 04,05)
///   · offline    — neither
/// The v1 readout conflated connected-idle and offline under a single `·`.
func cmdDevices() {
    guard let states = transport.getDeviceStates(query: BoseDeviceMap.knownDevices.map { $0.mac }) else {
        fail("headphones not reachable")
    }
    // Match by resolved NAME, not raw MAC: the Mac's active 05,01 entry is a private
    // link address that never equals the static [devices.mac] address, so it only
    // lines up with the `mac` row once resolved through activeName (#81). Active wins
    // over idle when a device resolves to both.
    let active = Set(states.active.map { activeName(forMac: $0) })
    let idle = Set(states.connected.map { displayName(forMac: $0) })
    for dev in BoseDeviceMap.knownDevices {
        let state = active.contains(dev.name) ? "●"
                  : idle.contains(dev.name) ? "○" : "·"
        print("  \(state) \(dev.name)")
    }
}

/// Deterministic multipoint eviction. The headset holds at most 2 devices and the
/// firmware only evicts by its own LRU. When both slots are full and `target` isn't
/// already one of them, drop the LOWEST-priority (highest `priority` number) of the
/// two held devices first, so the caller's connect lands the new device against the
/// hierarchy in devices.toml instead of whatever the firmware would have dropped.
/// Returns the device it evicted (so the caller can restore it if the connect that
/// follows fails to land — never leave a multipoint slot empty for nothing).
@discardableResult
func evictLowestPriorityIfFull(target: [UInt8]) -> BoseDevice? {
    guard let st = transport.getDeviceStates(query: BoseDeviceMap.knownDevices.map { $0.mac })
    else { return nil }
    let targetKey = macString(target)
    var heldKeys = Set<String>()
    for m in st.active + st.connected { heldKeys.insert(macString(m)) }
    if heldKeys.contains(targetKey) { return nil }   // already connected — nothing to evict
    if heldKeys.count < 2 { return nil }             // a slot is free — no eviction needed
    let held = BoseDeviceMap.knownDevices.filter { heldKeys.contains(macString($0.mac)) }
    // Rank by the user's runtime order (priority.json) when present, else the compiled
    // devices.toml priority — evict the WORST-ranked (highest effectiveRank) held device.
    let order = PriorityOrder.load().order
    guard let victim = held.max(by: {
        effectiveRank($0.name, order: order, compiledPriority: $0.priority)
            < effectiveRank($1.name, order: order, compiledPriority: $1.priority)
    }) else { return nil }
    _ = transport.oneShot(BMAP.disconnectDevice(mac: victim.mac))
    print("Evicted \(victim.name) (priority \(victim.priority)) to free a multipoint slot")
    Thread.sleep(forTimeInterval: 0.8)           // let the slot clear before paging the target
    return victim
}

/// Re-page a device we evicted, after the target connect failed — restores the prior pair.
func restoreEvicted(_ victim: BoseDevice, failedTarget: String) {
    _ = transport.oneShot(BMAP.connectDevice(mac: victim.mac))
    print("Restored \(victim.name) (target \(failedTarget) was unreachable)")
}

/// connect / c <device> — poll-confirm via getConnectedDevices (ACK is NOT success).
func cmdConnect(_ deviceName: String) {
    let mac = macForName(deviceName)
    let evicted = evictLowestPriorityIfFull(target: mac)

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    let outcome = confirmConnect(mac)
    switch outcome {
    case .active: print("Connected \(deviceName)")
    case .idle:   print("Connected \(deviceName) (idle — audio stayed on the active device; multipoint)")
    case .none:
        if let evicted = evicted { restoreEvicted(evicted, failedTarget: deviceName) }
        fail("connect \(deviceName) not confirmed within timeout")
    }
}

/// swap <device> — same as connect: multipoint keeps both devices connected and
/// audio routes to whichever got the last connect. (v1's help text wrongly said
/// "Disconnect others" — it never disconnected anything; corrected here + in usage.)
func cmdSwap(_ targetName: String) {
    let mac = macForName(targetName)
    let evicted = evictLowestPriorityIfFull(target: mac)

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    let outcome = confirmConnect(mac)
    switch outcome {
    case .active: print("Swapped to \(targetName)")
    case .idle:   print("Connected \(targetName) (idle — audio stayed on the active device; multipoint)")
    case .none:
        if let evicted = evicted { restoreEvicted(evicted, failedTarget: targetName) }
        fail("swap to \(targetName) not confirmed within timeout")
    }
}

/// Outcome of a connect/swap. `active` = audio routed here (05,01); `idle` = ACL up
/// under multipoint but audio stayed on the prior sink (04,05 connected, not 05,01);
/// `none` = never connected. The idle case is a real connection — not a failure —
/// and must not exit non-zero (it spuriously broke the macOS app / scripts, surfaced
/// while testing multipoint: paging a 2nd device joins it idle, not active).
enum ConnectOutcome: Equatable { case active, idle, none }

/// Poll `getDeviceStates` (one session per tick: 05,01 active + 04,05 ACL) until the
/// target is audio-active, settled-idle, or the ~16s budget expires. Offline devices
/// page slowly, and under multipoint a paged device settles into connected-idle a beat
/// AFTER the command returns — so we must keep polling for BOTH states, not snapshot once.
///
/// An **idle** outcome (ACL up under multipoint, audio kept on the prior sink — the
/// common case when you tap a non-sink device) is a real *success*, not something to
/// wait out: returning it early kills the "Connecting…" hang (#134 — it used to burn the
/// full 16s on every idle connect). We require two *consecutive* idle reads (~3s) before
/// returning, so a transient mid-handover read on its way to `.active` isn't mistaken for
/// a settled idle; a read that doesn't yet show the target (still paging) resets the
/// streak, preserving the full 16s budget for a genuinely slow `.none`.
///
/// Returns `.active` the instant it's the sink; `.idle` once it's stably ACL-only (or at
/// the deadline if it was ever seen idle); `.none` if it never appeared.
func confirmConnect(_ mac: [UInt8]) -> ConnectOutcome {
    let target = macString(mac)
    let deadline = Date().addingTimeInterval(16.0)
    let idleConfirmPolls = 2          // consecutive idle reads (~3s) before we trust it
    var sawIdle = false
    var idleStreak = 0
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1.5)
        guard let st = transport.getDeviceStates(query: [mac]) else { continue }
        if st.active.contains(where: { macString($0) == target }) { return .active }
        if st.connected.contains(where: { macString($0) == target }) {
            sawIdle = true
            idleStreak += 1
            if idleStreak >= idleConfirmPolls { return .idle }   // settled idle — don't wait out the deadline
        } else {
            idleStreak = 0            // not ACL-up yet (still paging) — restart the idle confirm
        }
    }
    return sawIdle ? .idle : .none
}

/// disconnect / d <device>
func cmdDisconnect(_ deviceName: String) {
    let mac = macForName(deviceName)

    _ = transport.oneShot(BMAP.disconnectDevice(mac: mac))

    print("Disconnected \(deviceName)")
}

/// priority [--set n1 n2 …] [--clear] — the runtime multipoint order (priority.json).
/// Bare: print the saved order (or the compiled default). `--set`: validate + persist a
/// new order (index 0 = primary). `--clear`: revert to the devices.toml hierarchy.
/// Host-side only — never pushed to the headphones (firmware has no priority hierarchy).
func cmdPriority(_ a: [String]) {
    if a.isEmpty {
        let order = PriorityOrder.load().order
        print(order.isEmpty
            ? "priority: (default — devices.toml hierarchy)"
            : "priority: " + order.joined(separator: " "))
        return
    }
    if a[0] == "--clear" {
        PriorityOrder.clear()
        print("priority cleared (reverted to devices.toml hierarchy)")
        return
    }
    var names = a
    if names.first == "--set" { names.removeFirst() }
    guard !names.isEmpty else { fail("priority --set needs device names") }
    for n in names where BoseDeviceMap.device(n) == nil { fail("unknown device: \(n)") }
    do { try PriorityOrder(order: names.map { $0.lowercased() }).save() }
    catch { fail("could not save priority: \(error)") }
    print("priority set: " + names.joined(separator: " "))
}

/// pair <primary> <secondary> — make exactly these two the multipoint pair: evict any
/// OTHER held device, connect the secondary (held), then the primary (active). The Mac
/// app's drag-reorder shells this when the top-2 changes. The firmware has no priority
/// lock, so an aggressive re-pager (e.g. the Audikast) or a sleeping target can still win
/// the slot — we report the honest outcome rather than fight it with a retry loop.
func cmdPair(_ primary: String, _ secondary: String) {
    let pMac = macForName(primary)
    let sMac = macForName(secondary)
    if macString(pMac) == macString(sMac) { fail("pair needs two different devices") }
    let keep = Set([macString(pMac), macString(sMac)])

    // Evict everything that isn't the intended pair so both slots are free for them.
    if let st = transport.getDeviceStates(query: BoseDeviceMap.knownDevices.map { $0.mac }) {
        let held = st.active + st.connected
        var evictedAny = false
        for m in held where !keep.contains(macString(m)) {
            _ = transport.oneShot(BMAP.disconnectDevice(mac: m))
            print("Evicted \(displayName(forMac: m)) to free a slot for the pair")
            evictedAny = true
        }
        if evictedAny { Thread.sleep(forTimeInterval: 0.8) }   // let the slots clear
    }

    // Page the secondary first (settles held), then the primary (should become active).
    func page(_ mac: [UInt8]) -> ConnectOutcome {
        _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)
        return confirmConnect(mac)
    }
    let sOut = page(sMac)
    let pOut = page(pMac)

    let secNote = sOut == .none ? "not connected" : "held"
    switch pOut {
    case .active: print("Paired: \(primary) (active) + \(secondary) (\(secNote))")
    case .idle:   print("Paired: \(primary) (connected, idle) + \(secondary) (\(secNote))")
    case .none:   fail("pair: \(primary) did not connect (target asleep, or a device is re-grabbing the slot — power it off)")
    }
}

/// volume / vol / v [level] — generated setVolume uses SET_GET (05,05,02). The v1
/// inline frame is gone.
func cmdVolume(_ arg: String?) {
    if let level = arg.flatMap({ Int($0) }) {
        guard (0...31).contains(level) else { fail("volume must be 0-31") }
        guard let r = transport.oneShot(BMAP.setVolume(level: UInt8(level))) else {
            fail("volume set failed")
        }
        if !printVolume(r) { print("Set to \(level)") }
    } else {
        guard let r = transport.oneShot(BMAP.getVolume()) else { fail("volume query failed") }
        if !printVolume(r) { fail("volume query failed") }
    }
}

/// Print "<level>/<max>" from a volume RESP (05,05,RESP,len,max,level). Returns
/// false (so callers can fall back) if the frame isn't a usable RESP.
@discardableResult
func printVolume(_ r: [UInt8]) -> Bool {
    guard r.count >= 6, r[2] == OP_RESP_BYTE else { return false }
    print("\(r[5])/\(r[4])")
    return true
}

/// multipoint / mp [on|off] — generated setMultipoint uses SET_GET.
func cmdMultipoint(_ arg: String?) {
    if let toggle = arg {
        let on = ["on", "true", "1"].contains(toggle.lowercased())
        // Multipoint is SET_GET: the set's own RESP carries the new state, so there's
        // no need for a separate verify-GET (a second back-to-back channel open that
        // intermittently returns nil — the false "query failed" seen on-device).
        guard let r = transport.oneShot(BMAP.setMultipoint(state: on ? 0x07 : 0x00)),
              r.count >= 5, r[2] == OP_RESP_BYTE else { fail("multipoint set failed") }
        print(parseMultipointEnabled(r[4]) ? "on" : "off")
        return
    }
    guard let r = transport.oneShot(BMAP.getMultipoint()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("multipoint query failed") }
    print(parseMultipointEnabled(r[4]) ? "on" : "off")
}

/// auto-pause [on|off] — pause when headphones are removed (01,18). Generated
/// setAutoPlayPause uses SET_GET; the set's own RESP carries the new state (no verify-GET).
func cmdAutoPlayPause(_ arg: String?) {
    if let toggle = arg {
        let on = ["on", "true", "1"].contains(toggle.lowercased())
        guard let r = transport.oneShot(BMAP.setAutoPlayPause(enabled: on ? 1 : 0)),
              r.count >= 5, r[2] == OP_RESP_BYTE else { fail("auto-pause set failed") }
        print((r[4] & 0x01) != 0 ? "on" : "off")
        return
    }
    guard let r = transport.oneShot(BMAP.getAutoPlayPause()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("auto-pause query failed") }
    print((r[4] & 0x01) != 0 ? "on" : "off")
}

/// auto-answer [on|off] — answer a call when headphones are donned (01,1B). SET_GET.
func cmdAutoAnswer(_ arg: String?) {
    if let toggle = arg {
        let on = ["on", "true", "1"].contains(toggle.lowercased())
        guard let r = transport.oneShot(BMAP.setAutoAnswer(enabled: on ? 1 : 0)),
              r.count >= 5, r[2] == OP_RESP_BYTE else { fail("auto-answer set failed") }
        print((r[4] & 0x01) != 0 ? "on" : "off")
        return
    }
    guard let r = transport.oneShot(BMAP.getAutoAnswer()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("auto-answer query failed") }
    print((r[4] & 0x01) != 0 ? "on" : "off")
}

/// favorites [m1 m2 …] — which AudioModes slots are favourited (1F,08). Bare = list;
/// with mode indices = set them. GET first to learn the slot count, then build the
/// SET_GET (count + reversed bitmask) via the hand-written buildFavoritesSetGet — the
/// payload isn't expressible in the generated builder DSL (getFavorites() is generated).
func cmdFavorites(_ favArgs: [String]) {
    guard let g = transport.oneShot(BMAP.getFavorites()), g.count >= 5,
          let current = parseFavorites(g) else { fail("favorites query failed") }
    let slotCount = Int(g[4])  // payload[0] = slot count
    func fmt(_ modes: [Int]) -> String {
        modes.map { m in (AncMode(rawValue: UInt8(m)).map { "\(m):\($0)" } ?? "\(m)") }.joined(separator: " ")
    }
    if favArgs.isEmpty {
        print(current.isEmpty ? "(none)" : fmt(current))
        return
    }
    let modes = favArgs.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }) }
        .compactMap { Int($0) }
    guard !modes.isEmpty, modes.allSatisfy({ $0 >= 0 && $0 < slotCount }) else {
        fail("usage: bose favorites <mode indices 0-\(slotCount - 1)>")
    }
    guard let r = transport.oneShot(buildFavoritesSetGet(modes: modes, slotCount: slotCount)),
          let updated = parseFavorites(r) else { fail("favorites set failed") }
    print(updated.isEmpty ? "(none)" : fmt(updated))
}

/// play / pause / next / prev — generated mediaControl builder.
func cmdMedia(_ action: MediaAction) {
    _ = transport.oneShot(BMAP.mediaControl(action: action.rawValue))
    print("\(action)")
}

/// eq [bass mid treble] — generated setEqBand (SET_GET) per band; GET via getEqBand.
func cmdEq(_ eqArgs: [String]) {
    if eqArgs.isEmpty {
        guard let r = transport.oneShot(BMAP.getEqBand()),
              r.count >= 16, r[2] == OP_RESP_BYTE else { fail("EQ query failed") }
        // v1-proven layout: value bytes at absolute indices 6, 10, 14.
        let bass = Int(Int8(bitPattern: r[6]))
        let mid = Int(Int8(bitPattern: r[10]))
        let treble = Int(Int8(bitPattern: r[14]))
        print("bass: \(bass)  mid: \(mid)  treble: \(treble)  (range: -10 to +10)")
    } else {
        guard eqArgs.count == 3,
              let bass = Int(eqArgs[0]), let mid = Int(eqArgs[1]), let treble = Int(eqArgs[2]),
              (-10...10).contains(bass), (-10...10).contains(mid), (-10...10).contains(treble) else {
            fail("usage: bose eq <bass> <mid> <treble> (each -10 to +10)")
        }
        // Send all three bands in ONE session (the applyProfile pattern). Three
        // separate oneShots would open a fresh channel per band and intermittently
        // return nil on the 2nd/3rd (the 300ms-drain quirk), failing mid-bands and
        // leaving EQ half-applied. One channel, three SET_GET sends.
        let writes: [(Int, EqBand)] = [(bass, .bass), (mid, .mid), (treble, .treble)]
        let ok = transport.session { ch, t -> Bool in
            for (value, band) in writes where t.send(ch, BMAP.setEqBand(value: Int8(value), band: band.rawValue)) == nil {
                return false
            }
            return true
        } ?? false
        guard ok else { fail("EQ set failed") }
        print("EQ set: bass=\(bass) mid=\(mid) treble=\(treble)")
    }
}

/// raw <hex> — escape hatch: send arbitrary BMAP bytes, print the response.
func cmdRaw(_ hex: String) {
    let clean = hex.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "0x", with: "")
    var bytes: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        guard let next = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) else { break }
        guard let byte = UInt8(clean[i..<next], radix: 16) else { fail("invalid hex: \(clean[i..<next])") }
        bytes.append(byte)
        i = next
    }
    guard !bytes.isEmpty else { fail("no bytes to send") }

    guard let resp = transport.oneShot(bytes) else { print("No response"); return }
    let hexStr = resp.map { String(format: "%02x", $0) }.joined()
    print("Response (\(resp.count) bytes): \(hexStr)")

    let asciiBytes = resp.count > 4 ? Array(resp[4...]) : resp
    if let ascii = String(bytes: asciiBytes, encoding: .utf8)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
       !ascii.isEmpty,
       ascii.allSatisfy({ $0.isASCII && ($0.isPunctuation || $0.isLetter || $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" || $0 == "_") }) {
        print("ASCII: \(ascii)")
    }
}

// MARK: - Entry

func usage() {
    print("""
    bose — Bose QC Ultra 2 control (direct RFCOMM, generated BMAP layer)

    Usage:
      bose status               Connection, battery, ANC, volume, EQ (one session)
      bose info [--json]        Full state: identity, power, all audio config, devices (--json for the app;
                                --json is cached-first with no ACL link — add --page to force a live read)
      bose battery              Battery level
      bose devices              Known devices: ● active / ○ connected / · offline
      bose connect <device>     Route audio to device (poll-confirmed)
      bose disconnect <device>  Disconnect a device
      bose swap <device>        Route audio to device (multipoint; keeps others)
      bose pair <primary> <secondary>  Make these two the multipoint pair (primary active, secondary held; evicts others)
      bose priority [--set n… | --clear]  Show/set the runtime eviction order (index 0 = primary); drives connect/swap/pair eviction
      bose anc [mode]           Get/set ANC (quiet/aware/immersion/cinema/custom1/custom2, or slot 0-5)
      bose anc-level [0-10]     Get/set active mode's noise level (0=max cancel … 10=transparent; custom modes only)
      bose spatial [off|still|motion]  Get/set Immersive Audio on the active mode (custom modes only)
      bose mode-name [--slot 4|5] [name]  Get/rename a custom mode (active mode, or slot 4=C1 / 5=C2; persists on-device)
      bose name [new name]      Get/set headphone name (max 30 UTF-8 bytes)
      bose volume [0-31]        Get/set volume
      bose multipoint [on|off]  Get/set multipoint
      bose auto-pause [on|off]  Get/set auto-pause when headphones are removed (01,18)
      bose auto-answer [on|off] Get/set auto-answer when headphones are donned (01,1B)
      bose favorites [m …]      List favourite mode slots; pass indices to set them (1F,08)
      bose presence [--timeout s] [--json]  Passive BLE scan: are the headphones on & nearby? (receive-only)
      bose play|pause|next|prev Media transport
      bose eq [bass mid treble] Get/set EQ (each -10 to +10)
      bose profile [name]       Apply a preset (bare = list); save <name> / rm <name>
      bose raw <hex>            Send raw BMAP bytes

    Devices: \(BoseDeviceMap.knownDevices.map { $0.name }.joined(separator: ", "))
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(0) }

func requireArg(_ name: String) -> String {
    guard args.count >= 3 else { fail("Usage: bose \(args[1].lowercased()) <\(name)>") }
    return args[2].lowercased()
}

switch args[1].lowercased() {
case "status", "s":            cmdStatus()
case "info":                   args.contains("--json") ? cmdInfoJSON(forcePage: args.contains("--page")) : cmdInfo()
case "battery", "b":           cmdBattery()
case "presence":               cmdPresence(args.count >= 3 ? Array(args[2...]) : [])
case "anc":                    cmdAnc(args.count >= 3 ? args[2] : nil)
case "anc-level":              cmdAncLevel(args.count >= 3 ? args[2] : nil)
case "spatial", "immersive":   cmdSpatial(args.count >= 3 ? args[2] : nil)
case "mode-name":
    var mnArgs = args.count >= 3 ? Array(args[2...]) : []
    var mnSlot: Int? = nil
    if let i = mnArgs.firstIndex(of: "--slot") {
        guard i + 1 < mnArgs.count, let s = Int(mnArgs[i + 1]) else { fail("--slot needs a slot number (4 or 5)") }
        mnSlot = s
        mnArgs.removeSubrange(i...(i + 1))
    }
    cmdModeName(slot: mnSlot, name: mnArgs.isEmpty ? nil : mnArgs.joined(separator: " "))
case "name":                   cmdName(args.count >= 3 ? args[2...].joined(separator: " ") : nil)
case "devices":                cmdDevices()
case "connect", "c":           cmdConnect(requireArg("device"))
case "disconnect", "d":        cmdDisconnect(requireArg("device"))
case "swap":                   cmdSwap(requireArg("device"))
case "priority", "prio":       cmdPriority(args.count >= 3 ? Array(args[2...]) : [])
case "pair":
    guard args.count >= 4 else { fail("pair needs <primary> <secondary>") }
    cmdPair(args[2], args[3])
case "volume", "vol", "v":     cmdVolume(args.count >= 3 ? args[2] : nil)
case "multipoint", "mp":       cmdMultipoint(args.count >= 3 ? args[2] : nil)
case "auto-pause", "autopause": cmdAutoPlayPause(args.count >= 3 ? args[2] : nil)
case "auto-answer", "autoanswer": cmdAutoAnswer(args.count >= 3 ? args[2] : nil)
case "favorites", "favourites", "fav": cmdFavorites(args.count >= 3 ? Array(args[2...]) : [])
case "play":                   cmdMedia(.play)
case "pause":                  cmdMedia(.pause)
case "next":                   cmdMedia(.next)
case "prev":                   cmdMedia(.prev)
case "eq":                     cmdEq(args.count >= 3 ? Array(args[2...]) : [])
case "profile", "profiles":    cmdProfile(args.count >= 3 ? Array(args[2...]) : [])
case "raw":                    cmdRaw(requireArg("hex"))
case "-h", "--help", "help":   usage()
default:
    fail("Unknown command: \(args[1])")
}
