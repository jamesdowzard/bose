/// ParserTests: standalone unit tests for the pure composite parsers.
///
/// Compiled with `Parsers.swift` (Foundation-only — no IOBluetooth, no hardware)
/// by `cli/run-tests.sh`. Feeds representative/captured BMAP response byte arrays
/// to `parseConnectedDevices`, `parseCncLevel`, `parseAllState` (+ buildCncSet) and
/// asserts the decoded values. Exits non-zero on the first failure.

import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond {
        print("ok   - \(msg)")
    } else {
        print("FAIL - \(msg)")
        failures += 1
    }
}

// ── parseConnectedDevices (05,01) ───────────────────────────────────────────────

// Header [05 01 RESP len], count at [6], 6-byte MACs from [7].
// Two devices: mac (BC..27) + phone (A8..1B). byte[3]=len, byte[4..5] filler, byte[6]=count.
let twoDevices: [UInt8] = [
    0x05, 0x01, 0x03, 0x0E, 0x00, 0x00, 0x02,
    0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27,
    0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B,
]
let cd = parseConnectedDevices(twoDevices)
check(cd.count == 2, "connectedDevices: parses 2 MACs")
check(cd.first ?? [] == [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27], "connectedDevices: first MAC is mac")
check(cd.last ?? [] == [0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B], "connectedDevices: second MAC is phone")

// Empty list (count 0).
let zeroDevices: [UInt8] = [0x05, 0x01, 0x03, 0x01, 0x00, 0x00, 0x00]
check(parseConnectedDevices(zeroDevices).isEmpty, "connectedDevices: count 0 -> empty")

// Truncated payload (count says 2, only 1 MAC of bytes present) -> stop at boundary.
let truncated: [UInt8] = [0x05, 0x01, 0x03, 0x08, 0x00, 0x00, 0x02, 0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27]
check(parseConnectedDevices(truncated).count == 1, "connectedDevices: truncated -> 1 MAC, no crash")

// Wrong block/func or non-RESP -> [].
check(parseConnectedDevices([0x04, 0x09, 0x03, 0x00]).isEmpty, "connectedDevices: wrong header -> empty")
check(parseConnectedDevices([0x05, 0x01, 0x01, 0x00]).isEmpty, "connectedDevices: non-RESP (GET echo) -> empty")
check(parseConnectedDevices([]).isEmpty, "connectedDevices: empty input -> empty")

// ── parseCncLevel (1F,0A) ───────────────────────────────────────────────────────

// [1F 0A RESP len, level, autoCNC, spatial, windBlock, ancToggle]
let cncResp: [UInt8] = [0x1F, 0x0A, 0x03, 0x05, 0x07, 0x01, 0x00, 0x01, 0x01]
let cfg = parseCncLevel(cncResp)
check(cfg != nil, "cncLevel: parses RESP")
check(cfg?.level == 7, "cncLevel: level == 7")
check(cfg?.autoCNC == 1 && cfg?.spatial == 0 && cfg?.windBlock == 1 && cfg?.ancToggle == 1,
      "cncLevel: preserves autoCNC/spatial/windBlock/ancToggle")
check(parseCncLevel([0x1F, 0x0A, 0x03, 0x01, 0x05]) == nil, "cncLevel: short payload -> nil")
check(parseCncLevel([0x1F, 0x0A, 0x01, 0x00]) == nil, "cncLevel: non-RESP -> nil")

// ── parseMultipointEnabled (01,0A state byte) ──────────────────────────────────
// fw 8.2.20 live: on -> 0x07, off -> 0x06 (slot bits retained). Bit 0 is the live
// enable flag; the old `!= 0` misread 0x06 as "on" (#83).
check(parseMultipointEnabled(0x07), "multipoint: 0x07 -> on")
check(!parseMultipointEnabled(0x06), "multipoint: 0x06 (off-with-slots) -> off")
check(!parseMultipointEnabled(0x00), "multipoint: 0x00 -> off")
check(parseMultipointEnabled(0x01), "multipoint: 0x01 (bare enable bit) -> on")

// ── ModeConfig (1F,06 AudioModesModeConfig) ─────────────────────────────────────
// The CORRECT noise-level path (1F,06 RMW), replacing the 1F,0A footgun (#83).
// Build a synthetic 52-byte response (4 header + 48 payload).
func mc(index: UInt8, name: String, mutability: UInt8, level: UInt8, anc: UInt8) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 48)
    p[0] = index; p[3] = 1  // userConfigurable
    for (i, b) in Array(name.utf8).enumerated() where i < 32 { p[6 + i] = b }
    p[41] = mutability; p[42] = level; p[47] = anc
    return [0x1F, 0x06, 0x03, 0x30] + p
}
let custom = parseModeConfig(mc(index: 5, name: "None", mutability: 0x1D, level: 7, anc: 1))!
check(custom.cncMutable, "modeConfig: 0x1D mutability bit0 -> cncMutable (adjustable)")
check(custom.cncLevel == 7, "modeConfig: cncLevel 7")
check(custom.displayName == "None", "modeConfig: name parse")
let fixed = parseModeConfig(mc(index: 0, name: "Quiet", mutability: 0x00, level: 0, anc: 1))!
check(!fixed.cncMutable, "modeConfig: 0x00 mutability -> fixed (Quiet/Aware/spatial)")
check(parseModeConfig([0x1F, 0x06, 0x03, 0x05, 0, 0]) == nil, "modeConfig: short -> nil")
// buildModeConfigSet: SET layout differs from response — name@3, level@35, anc@39.
let setF = buildModeConfigSet(custom, newLevel: 3)
check(Array(setF[0...3]) == [0x1F, 0x06, 0x02, 0x28], "modeConfigSet: header SET_GET len 40")
let sp = Array(setF[4...])
check(sp[0] == 5, "modeConfigSet: modeIndex @0")
check(Array(sp[3..<7]) == Array("None".utf8), "modeConfigSet: name @3")
check(sp[35] == 3, "modeConfigSet: new cncLevel @35")
check(sp[39] == 1, "modeConfigSet: ancToggle forced ON @39 (level change can't disable ANC)")
check(buildModeConfigSet(custom, newLevel: nil)[4 + 35] == 7, "modeConfigSet: nil keeps current level")
check(buildModeConfigSet(custom, newLevel: 99)[4 + 35] == 10, "modeConfigSet: clamps to 10")

// ── Immersive Audio / spatial (1F,06 payload[41] bit2 + payload[44]) ─────────────
// Live verBosita (fw 8.2.20): custom modes p[41]=0x1d -> spatialMutable; Immersion
// p[44]=2 (Motion), Cinema p[44]=1 (Still). spatial byte: 0 off, 1 Still, 2 Motion.
check(custom.spatialMutable, "modeConfig: 0x1D mutability bit2 -> spatialMutable")
check(!fixed.spatialMutable, "modeConfig: 0x00 mutability -> spatial fixed")
func mcSpatial(_ value: UInt8) -> [UInt8] { var f = mc(index: 5, name: "None", mutability: 0x1D, level: 7, anc: 1); f[4 + 44] = value; return f }
check(parseModeConfig(mcSpatial(2))!.spatial == 2, "modeConfig: spatial byte @44 = Motion")
check(parseModeConfig(mcSpatial(1))!.spatial == 1, "modeConfig: spatial byte @44 = Still")
// SET layout: spatial @37. newSpatial writes it; nil keeps current; clamps to 0...2.
let motionMode = parseModeConfig(mcSpatial(0))!
check(buildModeConfigSet(motionMode, newLevel: nil, newSpatial: 2)[4 + 37] == 2, "modeConfigSet: new spatial @37 = Motion")
check(buildModeConfigSet(parseModeConfig(mcSpatial(2))!, newLevel: nil)[4 + 37] == 2, "modeConfigSet: nil keeps current spatial")
check(buildModeConfigSet(motionMode, newLevel: nil, newSpatial: 9)[4 + 37] == 2, "modeConfigSet: clamps spatial to 2")
check(buildModeConfigSet(motionMode, newLevel: 4, newSpatial: 1)[4 + 35] == 4, "modeConfigSet: level + spatial together (level @35)")

// ── Custom mode rename (1F,06 name field, SET payload [3..34]) ────────────────────
// newName writes 32-byte UTF-8 at [3..34], null-padded; nil keeps the existing name.
let named = buildModeConfigSet(custom, newLevel: nil, newName: "Spatial")
let np = Array(named[4...])
check(Array(np[3..<10]) == Array("Spatial".utf8), "modeConfigSet: newName written @3")
check(np[3 + 7] == 0 && np[3 + 31] == 0, "modeConfigSet: name null-padded to 32")
let keptName = Array(buildModeConfigSet(custom, newLevel: nil)[4...])  // re-base slice to 0
check(Array(keptName[3..<7]) == Array("None".utf8), "modeConfigSet: nil newName keeps existing name")
// Over-long name truncates to 32 bytes (name field stays 32, level still lands at [35]).
let longName = String(repeating: "x", count: 50)
let longF = buildModeConfigSet(custom, newLevel: 5, newName: longName)
check(longF.count == 4 + 40, "modeConfigSet: over-long name truncated (payload stays 40)")
check(Array(longF[4...])[35] == 5, "modeConfigSet: level still @35 after long name")

// ── Favorites (1F,08) ───────────────────────────────────────────────────────────
// Live capture on verBosita (fw 8.2.20): GET 1F 08 01 00 -> STATUS 1f 08 03 03 0b 00 07.
// count 0x0b (11 slots) + reversed-order bitmask 00 07 = modes 0,1,2 favourited.
let favResp: [UInt8] = [0x1F, 0x08, 0x03, 0x03, 0x0B, 0x00, 0x07]
check(parseFavorites(favResp) ?? [] == [0, 1, 2], "favorites: decodes captured 0b 00 07 -> {0,1,2}")
// Round-trip: building the SET_GET from {0,1,2}/count 11 reproduces the live no-op frame.
check(buildFavoritesSetGet(modes: [0, 1, 2], slotCount: 11) == [0x1F, 0x08, 0x02, 0x03, 0x0B, 0x00, 0x07],
      "favorites: builds the live no-op SET_GET 1F 08 02 03 0b 00 07")
// A high mode (slot 8) lands in the FIRST mask byte (reversed order), low modes in the last.
let fav8 = buildFavoritesSetGet(modes: [8], slotCount: 11)
check(fav8 == [0x1F, 0x08, 0x02, 0x03, 0x0B, 0x01, 0x00], "favorites: mode 8 -> first mask byte (reversed)")
check(parseFavorites([0x1F, 0x08, 0x03, 0x03, 0x0B, 0x01, 0x00]) ?? [] == [8], "favorites: decodes mode 8 from first byte")
// Build/parse are inverses across a mixed set.
let mixed = [0, 2, 9]
let rt = parseFavorites([0x1F, 0x08, 0x03] + [UInt8(buildFavoritesSetGet(modes: mixed, slotCount: 11).count - 4)]
                        + Array(buildFavoritesSetGet(modes: mixed, slotCount: 11).dropFirst(4)))
check(rt ?? [] == mixed, "favorites: build->parse round-trips {0,2,9}")
// Guards: short / non-RESP / wrong header -> nil.
check(parseFavorites([0x1F, 0x08, 0x01, 0x00]) == nil, "favorites: non-RESP (GET echo) -> nil")
check(parseFavorites([0x1F, 0x06, 0x03, 0x03, 0x0B, 0x00, 0x07]) == nil, "favorites: wrong func -> nil")

// ── parseAllState (bulk session) ─────────────────────────────────────────────────

// Stub provider: returns a representative RESP per (block,func) GET.
let responses: [[UInt8]: [UInt8]] = [
    [0x02, 0x02]: [0x02, 0x02, 0x03, 0x04, 0x4B, 0x00, 0x00, 0x01],          // battery 75%, charging
    [0x1F, 0x03]: [0x1F, 0x03, 0x03, 0x01, 0x01],                            // ANC = aware (1)
    [0x05, 0x05]: [0x05, 0x05, 0x03, 0x02, 0x1F, 0x14],                      // volMax 31, vol 20
    [0x05, 0x01]: twoDevices,                                                // 2 active devices
    [0x1F, 0x0A]: cncResp,                                                   // cnc level 7
    [0x01, 0x0A]: [0x01, 0x0A, 0x03, 0x01, 0x07],                            // multipoint on
    [0x01, 0x18]: [0x01, 0x18, 0x03, 0x01, 0x01],                            // auto-pause on
    [0x01, 0x1B]: [0x01, 0x1B, 0x03, 0x01, 0x00],                            // auto-answer off
    [0x1F, 0x08]: [0x1F, 0x08, 0x03, 0x03, 0x0B, 0x00, 0x07],                // favorites 0/1/2
    [0x00, 0x05]: [0x00, 0x05, 0x03, 0x05] + Array("1.2.3".utf8),            // firmware
    // EQ RESP: parser reads value bytes at absolute indices 6, 10, 14 (v1-proven
    // layout: 3x 4-byte groups, value is the 3rd byte of each group).
    [0x01, 0x07]: [0x01, 0x07, 0x03, 0x0C,
                   0xF6, 0x0A, 0x03, 0x00,    // index 6  = bass = +3
                   0xF6, 0x0A, 0x00, 0x01,    // index 10 = mid  = 0
                   0xF6, 0x0A, 0xFD, 0x02],   // index 14 = treble = -3 (0xFD two's complement)
]
let state = parseAllState { block, function in responses[[block, function]] }
check(state.batteryLevel == 75 && state.batteryCharging, "allState: battery 75% charging")
check(state.ancMode == 1, "allState: ANC mode aware")
check(state.volume == 20 && state.volumeMax == 31, "allState: volume 20/31")
check(state.connectedDevices.count == 2, "allState: 2 connected devices")
check(state.cncLevel == 7, "allState: cnc level 7")
check(state.multipointEnabled, "allState: multipoint on")
check(state.autoPlayPause, "allState: auto-pause on")
check(!state.autoAnswer, "allState: auto-answer off")
check(state.favorites == [0, 1, 2], "allState: favorites 0/1/2")
check(state.firmware == "1.2.3", "allState: firmware 1.2.3")
check(state.eq.bass == 3 && state.eq.mid == 0 && state.eq.treble == -3, "allState: EQ +3/0/-3 (signed)")

// Missing responses must not crash — defaults stay.
let empty = parseAllState { _, _ in nil }
check(empty.batteryLevel == 0 && empty.connectedDevices.isEmpty, "allState: all-nil provider -> defaults")

// ── parseDeviceInfo (04,05) ──────────────────────────────────────────────────────

// RESP: status byte at index 10 (bit0 = ACL connected), optional name from index 13.
let devInfoConnected: [UInt8] = [
    0x04, 0x05, 0x03, 0x10,             // header (RESP)
    0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27, // bytes 4..9 (echoed mac — ignored)
    0x03,                              // byte 10 = status, bit0 set -> connected
    0x00, 0x00,                        // bytes 11,12 filler
] + Array("mac".utf8)                  // name from byte 13
let di = parseDeviceInfo(devInfoConnected)
check(di?.connected == true, "deviceInfo: status bit0 set -> connected")
check(di?.status == 3, "deviceInfo: status == 3")
check(di?.name == "mac", "deviceInfo: name parsed from byte 13")

// status bit0 clear -> not connected, no name present.
let devInfoOffline: [UInt8] = [0x04, 0x05, 0x03, 0x07, 0xF4, 0x81, 0xC4, 0xB5, 0xFA, 0xAB, 0x00]
check(parseDeviceInfo(devInfoOffline)?.connected == false, "deviceInfo: status bit0 clear -> not connected")

// Short frame and non-RESP (GET echo) -> nil.
check(parseDeviceInfo([0x04, 0x05, 0x03, 0x00]) == nil, "deviceInfo: short frame -> nil")
check(parseDeviceInfo([0x04, 0x05, 0x01, 0x06, 0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27, 0x00]) == nil,
      "deviceInfo: non-RESP (GET echo) -> nil")

// ── profiles ─────────────────────────────────────────────────────────────────────

// profileFrames: full profile → ordered SET frames (anc, vol, mp, 3x eq[, depth]).
// #83: ANC depth is the SAME axis as a named mode, so a NAMED-mode profile (aware)
// must NOT emit the depth frame even when ancDepth is set — writing it disables ANC.
let cnc2 = CncConfig(level: 7, autoCNC: 1, spatial: 0, windBlock: 1, ancToggle: 1)
let full = Profile(name: "t", ancMode: "aware", ancDepth: 5,
                   eq: EqValues(bass: 3, mid: 0, treble: -3), multipoint: true, volume: 20)
let pf = profileFrames(full, currentCnc: cnc2)
check(pf.count == 6, "profileFrames: named-mode profile skips depth (6 frames, #83)")
check(pf[0] == [0x1F, 0x03, 0x05, 0x02, 0x01, 0x01], "profileFrames: anc aware (START)")
check(pf[1] == [0x05, 0x05, 0x02, 0x01, 0x14], "profileFrames: volume 20 (SET_GET)")
check(pf[2] == [0x01, 0x0A, 0x02, 0x01, 0x07], "profileFrames: multipoint on")
check(pf[3] == [0x01, 0x07, 0x02, 0x02, 0x03, 0x00], "profileFrames: eq bass +3")
check(pf[5] == [0x01, 0x07, 0x02, 0x02, 0xFD, 0x02], "profileFrames: eq treble -3 (signed)")
check(!pf.contains(where: { $0.count >= 2 && $0[0] == 0x1F && $0[1] == 0x0A }),
      "profileFrames: never emits a 1F,0A CNC frame (the footgun is gone, #83)")
// Profiles NEVER write a noise level now — even a profile carrying ancDepth emits no
// CNC frame (level is set per-mode via anc-level / 1F,06, not via profiles).
let customP = Profile(name: "c1", ancMode: "custom1", ancDepth: 5)
let pfc = profileFrames(customP, currentCnc: cnc2)
check(!pfc.contains(where: { $0.count >= 2 && $0[0] == 0x1F && $0[1] == 0x0A }),
      "profileFrames: ancDepth profile emits no CNC frame")
check(pfc.count == 1, "profileFrames: custom1+depth -> just the mode-select frame")
// noiseLevel is applied via the live 1F,06 RMW in applyProfile, NOT as a static frame —
// so a custom-mode profile carrying a noiseLevel still emits only the mode-select frame.
let nlP = profileFrames(Profile(name: "nl", ancMode: "custom1", noiseLevel: 3), currentCnc: nil)
check(nlP.count == 1 && nlP[0] == [0x1F, 0x03, 0x05, 0x02, 0x04, 0x01],
      "profileFrames: noiseLevel adds no static frame (RMW lives in applyProfile)")
check(profileFrames(Profile(name: "empty"), currentCnc: nil).isEmpty, "profileFrames: empty profile -> none")
// EQ values clamp into -10...10.
let clampP = profileFrames(Profile(name: "c", eq: EqValues(bass: 99, mid: -99, treble: 0)), currentCnc: nil)
check(clampP[0] == [0x01, 0x07, 0x02, 0x02, 0x0A, 0x00], "profileFrames: eq clamps +99 -> +10")
check(clampP[1] == [0x01, 0x07, 0x02, 0x02, 0xF6, 0x01], "profileFrames: eq clamps -99 -> -10")

// JSON round-trip: decode store, case-insensitive lookup, absent field stays nil.
let pjson = "{\"profiles\":[{\"name\":\"flight\",\"ancMode\":\"quiet\",\"ancDepth\":10,\"multipoint\":false}]}"
let store = try! JSONDecoder().decode(ProfileStore.self, from: Data(pjson.utf8))
check(store.profiles.count == 1, "profileStore: decodes 1")
check(store.profile(named: "FLIGHT")?.ancDepth == 10, "profileStore: case-insensitive lookup")
check(store.profile(named: "flight")?.volume == nil, "profile: absent field stays nil")
// New noiseLevel field decodes; legacy inert ancDepth still decodes alongside it.
let njson = "{\"profiles\":[{\"name\":\"c\",\"ancMode\":\"custom1\",\"noiseLevel\":3}]}"
let nstore = try! JSONDecoder().decode(ProfileStore.self, from: Data(njson.utf8))
check(nstore.profile(named: "c")?.noiseLevel == 3, "profile: decodes noiseLevel")
check(nstore.profile(named: "c")?.ancDepth == nil, "profile: noiseLevel-only profile has nil ancDepth")

// Encode omits unset fields (clean human-editable JSON).
let encoded = String(data: try! JSONEncoder().encode(Profile(name: "x", ancMode: "quiet")), encoding: .utf8)!
check(encoded.contains("ancMode"), "profile encode: keeps set field")
check(!encoded.contains("volume"), "profile encode: omits nil fields")
let encN = String(data: try! JSONEncoder().encode(Profile(name: "x", noiseLevel: 4)), encoding: .utf8)!
check(encN.contains("noiseLevel"), "profile encode: keeps noiseLevel")

// upsert replaces by name (case-insensitive), doesn't duplicate.
var st = ProfileStore(profiles: [Profile(name: "a", volume: 5)])
st.upsert(Profile(name: "A", volume: 9))
st.upsert(Profile(name: "b"))
check(st.profiles.count == 2, "store upsert: replaces, no dup")
check(st.profile(named: "a")?.volume == 9, "store upsert: updated value")

// capture: HeadphoneState → fully-populated profile.
var snap = HeadphoneState()
snap.ancMode = 1; snap.cncLevel = 8; snap.eq = (bass: 2, mid: -1, treble: 4)
snap.multipointEnabled = true; snap.volume = 12
let cap = Profile(capturing: snap, name: "now")
check(cap.ancMode == "aware", "profile capture: ancMode name")
check(cap.noiseLevel == 8 && cap.volume == 12, "profile capture: noise level + volume")
check(cap.ancDepth == nil, "profile capture: inert ancDepth left nil (level → noiseLevel)")
check(cap.eq == EqValues(bass: 2, mid: -1, treble: 4), "profile capture: eq")
check(cap.multipoint == true, "profile capture: multipoint")

// summary surfaces the noise level (not the inert depth).
check(Profile(name: "s", ancMode: "custom1", noiseLevel: 3).summary == " — anc custom1, noise 3",
      "profile summary: shows noise level")

// ── priority: effectiveRank + victim selection + round-trip ─────────────────────

// Listed device ranks by its index (0 = primary, kept longest).
check(effectiveRank("ipad", order: ["ipad", "mac"], compiledPriority: 4) == 0,
      "rank: listed primary = index 0")
check(effectiveRank("mac", order: ["ipad", "mac"], compiledPriority: 1) == 1,
      "rank: listed secondary = index 1")
// Unlisted device sorts AFTER all listed ones, then by compiled priority.
check(effectiveRank("audikast", order: ["ipad", "mac"], compiledPriority: 8) == 10,
      "rank: unlisted = order.count + compiledPriority")
// Empty order = pure compiled fallback (index-free).
check(effectiveRank("phone", order: [], compiledPriority: 2) == 2,
      "rank: empty order falls back to compiled priority")

// Victim selection mirrors `held.max(by: effectiveRank<)`: the WORST-ranked held device.
func victim(_ held: [(String, Int)], _ order: [String]) -> String? {
    held.max(by: {
        effectiveRank($0.0, order: order, compiledPriority: $0.1)
            < effectiveRank($1.0, order: order, compiledPriority: $1.1)
    })?.0
}
// Default (no override): audikast (compiled 8) is evicted over mac (1).
check(victim([("mac", 1), ("audikast", 8)], []) == "audikast",
      "victim: compiled default evicts the lowest-priority (audikast)")
// Runtime order FLIPS it: user keeps audikast (listed) → mac (unlisted) is evicted instead.
check(victim([("mac", 1), ("audikast", 8)], ["ipad", "audikast"]) == "mac",
      "victim: runtime order overrides compiled — unlisted mac evicted, listed audikast kept")

// PriorityOrder round-trips through disk (BOSE_STATE_DIR override).
let tmpPrio = NSTemporaryDirectory() + "bose-prio-test-\(ProcessInfo.processInfo.processIdentifier)"
setenv("BOSE_STATE_DIR", tmpPrio, 1)
try? PriorityOrder(order: ["ipad", "mac", "phone"]).save()
check(PriorityOrder.load().order == ["ipad", "mac", "phone"], "priority.json: save/load round-trip")
PriorityOrder.clear()
check(PriorityOrder.load().order == [], "priority.json: clear reverts to empty (compiled default)")
try? FileManager.default.removeItem(atPath: tmpPrio)

// ── Profile pair (one-tap tv mode) ─────────────────────────────────────────────

let tvJson = #"{"profiles":[{"name":"tv","pair":["audikast","phone"]}]}"#
let tvStore = try? JSONDecoder().decode(ProfileStore.self, from: Data(tvJson.utf8))
check(tvStore?.profiles.first?.pair == ["audikast", "phone"], "profile pair: decodes [primary, secondary]")
check(tvStore?.profiles.first?.hasDeviceSettings == false, "profile pair: pair-only profile sets no device settings")
check(tvStore?.profiles.first?.summary.contains("pair audikast+phone") == true, "profile pair: summary shows the pair")
check(Profile(name: "x", ancMode: "quiet", pair: ["a", "b"]).hasDeviceSettings,
      "profile pair: settings+pair profile still has device settings")
let pairEnc = try? JSONEncoder().encode(ProfileStore(profiles: [Profile(name: "tv", pair: ["audikast", "phone"])]))
let pairRT = pairEnc.flatMap { try? JSONDecoder().decode(ProfileStore.self, from: $0) }
check(pairRT?.profiles.first?.pair == ["audikast", "phone"], "profile pair: encode/decode round-trip")
check(Profile(name: "plain", ancMode: "quiet").pair == nil, "profile pair: absent stays nil (older profiles decode)")

// ── StateCache (cached-first info --json, #148) ────────────────────────────────

// Fresh temp dir (the priority tests above removed theirs; use our own regardless).
let tmpCache = NSTemporaryDirectory() + "bose-cache-test-\(ProcessInfo.processInfo.processIdentifier)"
setenv("BOSE_STATE_DIR", tmpCache, 1)

check(StateCache.staleOutput() == nil, "stateCache: empty dir -> no stale output (bare fallback)")

let liveSnap: [String: Any] = ["connected": true, "reachable": true,
                               "batteryLevel": 80, "ancMode": 1, "ageSeconds": 999]
let t0 = Date(timeIntervalSince1970: 1_000_000)
StateCache.save(liveSnap, now: t0)
let loaded = StateCache.load()
check(loaded != nil, "stateCache: save/load round-trip")
check((loaded?.snapshot["batteryLevel"] as? Int) == 80, "stateCache: snapshot preserves values")
check(loaded?.snapshot["reachable"] == nil && loaded?.snapshot["ageSeconds"] == nil,
      "stateCache: cache-layer keys stripped on save (can't re-persist as live)")
check(loaded?.savedAt == t0, "stateCache: savedAt stamp survives")

let stale = StateCache.staleOutput(now: t0.addingTimeInterval(90))
check((stale?["reachable"] as? Bool) == false, "stateCache: stale output -> reachable=false")
check((stale?["ageSeconds"] as? Int) == 90, "stateCache: ageSeconds computed from savedAt")
check((stale?["connected"] as? Bool) == true, "stateCache: connected keeps the cached headphone state")
check((stale?["cachedAt"] as? Double) == 1_000_000, "stateCache: cachedAt = save epoch")

// Pure stamp: age clamps at zero (a clock skew can't emit a negative age).
let stamped = StateCache.stamp(["connected": true], savedAt: t0, now: t0.addingTimeInterval(-5))
check((stamped[StateCache.ageSecondsKey] as? Int) == 0, "stateCache: stamp clamps negative age to 0")

try? FileManager.default.removeItem(atPath: tmpCache)

// ── isBoseAdvert (passive BLE presence match) ──────────────────────────────────

check(isBoseAdvert(name: "verBosita", mfr: []), "presence: exact name matches (no mfr needed)")
check(isBoseAdvert(name: "", mfr: [0x9E, 0x00, 0x00, 0x2C]), "presence: Bose company ID 0x009E matches")
check(!isBoseAdvert(name: "AirPods Pro", mfr: [0x4C, 0x00, 0x10]), "presence: Apple advert rejected")
check(!isBoseAdvert(name: "verbosita", mfr: []), "presence: name match is exact (case-sensitive)")
check(!isBoseAdvert(name: "", mfr: [0x9E]), "presence: 1-byte mfr rejected (needs both ID bytes)")
check(!isBoseAdvert(name: "", mfr: []), "presence: empty advert rejected")

// ── correlationLine (BLE battery-decode dataset) ───────────────────────────────

let corrNow = Date(timeIntervalSince1970: 2_000_000)
let corr = StateCache.correlationLine(now: corrNow, rssi: -56, mfr: [0x9E, 0x00, 0x2C],
                                      cachedBattery: 44, cacheAge: 120)
check(corr == #"{"battery":44,"cacheAgeSeconds":120,"mfr":"9e002c","rssi":-56,"ts":2000000}"#,
      "correlation: full line serialises deterministically (sorted keys)")
check(StateCache.correlationLine(now: corrNow, rssi: -56, mfr: [0x9E], cachedBattery: nil, cacheAge: 5) == nil,
      "correlation: no cached battery -> no line (nothing to correlate)")
let corrNoAge = StateCache.correlationLine(now: corrNow, rssi: -40, mfr: [], cachedBattery: 80, cacheAge: nil)
check(corrNoAge?.contains("cacheAgeSeconds") == false && corrNoAge?.contains("\"battery\":80") == true,
      "correlation: age omitted when unknown, battery kept")

// ── summary ─────────────────────────────────────────────────────────────────────

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
