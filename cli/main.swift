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

func isMacDevice(_ mac: [UInt8]) -> Bool {
    BoseDeviceMap.mac("mac") == mac
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
func cmdInfoJSON() {
    func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { print("{\"connected\":false}"); return }
        print(str)
    }

    guard let s = transport.getAllState() else { emit(["connected": false]); return }

    // Per-device 3-state, resolved by NAME (same logic as cmdDevices, #81). If the
    // dedicated probe is unreachable, fall back to active-only from getAllState.
    //
    // `getAllState` reads 05,01 as its 4th in-session read — well-warmed, reliably
    // returns the active sink (→ activeFromAll). The dedicated `getDeviceStates` opens
    // a FRESH session and re-reads 05,01 with a single battery prime; as the 2nd RFCOMM
    // session in quick succession that read can come back EMPTY (the #81 cold-channel
    // quirk a standalone `bose devices` call doesn't hit). When it does, `states.active`
    // is empty and every tile defaulted to offline even though the headphones report the
    // mac active. Union activeFromAll into active so the warm read always wins — no retry
    // loop (single-attempt rule), just don't discard data already in hand.
    var deviceStates: [String: String] = [:]
    let activeFromAll = Set(s.connectedDevices.map { activeName(forMac: $0) })
    if let states = transport.getDeviceStates(query: BoseDeviceMap.knownDevices.map { $0.mac }) {
        let active = activeFromAll.union(states.active.map { activeName(forMac: $0) })
        let idle = Set(states.connected.map { displayName(forMac: $0) }).subtracting(active)
        for dev in BoseDeviceMap.knownDevices {
            deviceStates[dev.name] = active.contains(dev.name) ? "active"
                                   : idle.contains(dev.name) ? "connected" : "offline"
        }
    } else {
        for dev in BoseDeviceMap.knownDevices {
            deviceStates[dev.name] = activeFromAll.contains(dev.name) ? "active" : "offline"
        }
    }

    // Active mode's noise config (1F,06) — drives the app's noise slider. Its own warm
    // session (event-driven read, not polled). `noiseAdjustable` (cncMutable) gates the
    // slider so a level write can never disable ANC (#83). nil → slider hidden/disabled.
    var mode: [String: Any] = ["noiseAdjustable": false, "spatialAdjustable": false]
    let modeInfo = transport.readModeInfo()
    if let cfg = modeInfo?.active {
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
        let n = modeInfo?.customNames[idx] ?? ""
        return n == "None" ? "" : n
    }

    var out: [String: Any] = [
        "connected": true,
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
    emit(out)
}

func ancModeName(_ mode: Int) -> String {
    AncMode(rawValue: UInt8(truncatingIfNeeded: mode))
        .map { "\($0)" } ?? "unknown(\(mode))"
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

/// mode-name <name> — rename the ACTIVE mode (1F,06 RMW on the 32-byte name field). Only
/// the custom slots (4/5, userConfigurable) can be renamed; the named presets are locked.
/// The name persists on-device and shows on the C1/C2 buttons + in the Bose app.
func cmdModeName(_ name: String?) {
    guard let name = name, !name.isEmpty else {
        guard let cfg = transport.readActiveModeConfig() else { fail("headphones not reachable") }
        print("\(cfg.displayName)\(cfg.userConfigurable ? "" : " (preset — name locked)")")
        return
    }
    switch transport.setActiveModeName(name) {
    case .ok(let n):       print("mode renamed: \(n)")
    case .notCustom:       fail("only the custom modes (C1/C2) can be renamed — switch to one first")
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
        guard transport.applyProfile(p) else { fail("failed to apply '\(name)'") }
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
    guard let victim = held.max(by: { $0.priority < $1.priority }) else { return nil }
    _ = transport.oneShot(BMAP.disconnectDevice(mac: victim.mac))
    if isMacDevice(victim.mac) { runBlueutil(["--disconnect", Headphone.mac]) }
    print("Evicted \(victim.name) (priority \(victim.priority)) to free a multipoint slot")
    Thread.sleep(forTimeInterval: 0.8)           // let the slot clear before paging the target
    return victim
}

/// Re-page a device we evicted, after the target connect failed — restores the prior pair.
func restoreEvicted(_ victim: BoseDevice, failedTarget: String) {
    _ = transport.oneShot(BMAP.connectDevice(mac: victim.mac))
    if isMacDevice(victim.mac) { runBlueutil(["--connect", Headphone.mac]) }
    print("Restored \(victim.name) (target \(failedTarget) was unreachable)")
}

/// connect / c <device> — poll-confirm via getConnectedDevices (ACK is NOT success).
func cmdConnect(_ deviceName: String) {
    let mac = macForName(deviceName)
    let evicted = evictLowestPriorityIfFull(target: mac)

    // For the Mac itself, ensure A2DP first (macOS link), like v1/the app.
    if isMacDevice(mac) {
        runBlueutil(["--connect", Headphone.mac])
        Thread.sleep(forTimeInterval: 1.5)
    }

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    switch confirmConnect(mac) {
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

    if isMacDevice(mac) {
        runBlueutil(["--connect", Headphone.mac])
        Thread.sleep(forTimeInterval: 1.5)
    }

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    switch confirmConnect(mac) {
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
enum ConnectOutcome { case active, idle, none }

/// Poll `getDeviceStates` (one session per tick: 05,01 active + 04,05 ACL) until the
/// target is audio-active, or the ~16s budget expires. Offline devices page slowly,
/// and under multipoint a paged device settles into connected-idle a beat AFTER the
/// command returns — so we must keep polling for BOTH states, not snapshot once.
/// Returns `.active` the instant it's the sink; `.idle` if it only ever reached ACL
/// (a real connection, exit 0); `.none` if it never appeared.
func confirmConnect(_ mac: [UInt8]) -> ConnectOutcome {
    let target = macString(mac)
    let deadline = Date().addingTimeInterval(16.0)
    var sawIdle = false
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1.5)
        guard let st = transport.getDeviceStates(query: [mac]) else { continue }
        if st.active.contains(where: { macString($0) == target }) { return .active }
        if st.connected.contains(where: { macString($0) == target }) { sawIdle = true }
    }
    return sawIdle ? .idle : .none
}

/// disconnect / d <device>
func cmdDisconnect(_ deviceName: String) {
    let mac = macForName(deviceName)

    _ = transport.oneShot(BMAP.disconnectDevice(mac: mac))

    // If disconnecting Mac, also drop the Mac BT stack link.
    if isMacDevice(mac) {
        runBlueutil(["--disconnect", Headphone.mac])
    }

    print("Disconnected \(deviceName)")
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
      bose info [--json]        Full state: identity, power, all audio config, devices (--json for the app)
      bose battery              Battery level
      bose devices              Known devices: ● active / ○ connected / · offline
      bose connect <device>     Route audio to device (poll-confirmed)
      bose disconnect <device>  Disconnect a device
      bose swap <device>        Route audio to device (multipoint; keeps others)
      bose anc [mode]           Get/set ANC (quiet/aware/immersion/cinema/custom1/custom2, or slot 0-5)
      bose anc-level [0-10]     Get/set active mode's noise level (0=max cancel … 10=transparent; custom modes only)
      bose spatial [off|still|motion]  Get/set Immersive Audio on the active mode (custom modes only)
      bose mode-name [name]     Get/rename the active mode (custom modes only; persists on-device)
      bose name [new name]      Get/set headphone name (max 30 UTF-8 bytes)
      bose volume [0-31]        Get/set volume
      bose multipoint [on|off]  Get/set multipoint
      bose auto-pause [on|off]  Get/set auto-pause when headphones are removed (01,18)
      bose auto-answer [on|off] Get/set auto-answer when headphones are donned (01,1B)
      bose favorites [m …]      List favourite mode slots; pass indices to set them (1F,08)
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
case "info":                   args.contains("--json") ? cmdInfoJSON() : cmdInfo()
case "battery", "b":           cmdBattery()
case "anc":                    cmdAnc(args.count >= 3 ? args[2] : nil)
case "anc-level":              cmdAncLevel(args.count >= 3 ? args[2] : nil)
case "spatial", "immersive":   cmdSpatial(args.count >= 3 ? args[2] : nil)
case "mode-name":              cmdModeName(args.count >= 3 ? args[2...].joined(separator: " ") : nil)
case "name":                   cmdName(args.count >= 3 ? args[2...].joined(separator: " ") : nil)
case "devices":                cmdDevices()
case "connect", "c":           cmdConnect(requireArg("device"))
case "disconnect", "d":        cmdDisconnect(requireArg("device"))
case "swap":                   cmdSwap(requireArg("device"))
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
