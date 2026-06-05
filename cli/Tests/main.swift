/// ParserTests: standalone unit tests for the pure composite parsers.
///
/// Compiled with `Parsers.swift` (Foundation-only — no IOBluetooth, no hardware)
/// by `macos/run-tests.sh`. Feeds representative/captured BMAP response byte arrays
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

// buildCncSet preserves the other four and clamps level into 0...10.
let set = buildCncSet(level: 3, preserving: cfg!)
check(set == [0x1F, 0x0A, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x01],
      "buildCncSet: changes level=3, preserves rest, SET_GET op")
let clamped = buildCncSet(level: 99, preserving: cfg!)
check(clamped[4] == 10, "buildCncSet: clamps level to 10")

// ── parseAllState (bulk session) ─────────────────────────────────────────────────

// Stub provider: returns a representative RESP per (block,func) GET.
let responses: [[UInt8]: [UInt8]] = [
    [0x02, 0x02]: [0x02, 0x02, 0x03, 0x04, 0x4B, 0x00, 0x00, 0x01],          // battery 75%, charging
    [0x1F, 0x03]: [0x1F, 0x03, 0x03, 0x01, 0x01],                            // ANC = aware (1)
    [0x05, 0x05]: [0x05, 0x05, 0x03, 0x02, 0x1F, 0x14],                      // volMax 31, vol 20
    [0x05, 0x01]: twoDevices,                                                // 2 active devices
    [0x1F, 0x0A]: cncResp,                                                   // cnc level 7
    [0x01, 0x0A]: [0x01, 0x0A, 0x03, 0x01, 0x07],                            // multipoint on
    [0x08, 0x07]: [0x08, 0x07, 0x03, 0x01, 0x04],                            // on head
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
check(state.onHead, "allState: on head")
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

// profileFrames: full profile → ordered SET frames (anc, vol, mp, 3x eq, depth).
let cnc2 = CncConfig(level: 7, autoCNC: 1, spatial: 0, windBlock: 1, ancToggle: 1)
let full = Profile(name: "t", ancMode: "aware", ancDepth: 5,
                   eq: EqValues(bass: 3, mid: 0, treble: -3), multipoint: true, volume: 20)
let pf = profileFrames(full, currentCnc: cnc2)
check(pf.count == 7, "profileFrames: 7 frames")
check(pf[0] == [0x1F, 0x03, 0x05, 0x02, 0x01, 0x01], "profileFrames: anc aware (START)")
check(pf[1] == [0x05, 0x05, 0x02, 0x01, 0x14], "profileFrames: volume 20 (SET_GET)")
check(pf[2] == [0x01, 0x0A, 0x02, 0x01, 0x07], "profileFrames: multipoint on")
check(pf[3] == [0x01, 0x07, 0x02, 0x02, 0x03, 0x00], "profileFrames: eq bass +3")
check(pf[5] == [0x01, 0x07, 0x02, 0x02, 0xFD, 0x02], "profileFrames: eq treble -3 (signed)")
check(pf[6] == [0x1F, 0x0A, 0x02, 0x05, 0x05, 0x01, 0x00, 0x01, 0x01], "profileFrames: cnc depth 5 preserves rest")
// nil currentCnc → depth frame skipped; empty profile → no frames.
check(profileFrames(full, currentCnc: nil).count == 6, "profileFrames: nil cnc skips depth")
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

// Encode omits unset fields (clean human-editable JSON).
let encoded = String(data: try! JSONEncoder().encode(Profile(name: "x", ancMode: "quiet")), encoding: .utf8)!
check(encoded.contains("ancMode"), "profile encode: keeps set field")
check(!encoded.contains("volume"), "profile encode: omits nil fields")

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
check(cap.ancDepth == 8 && cap.volume == 12, "profile capture: depth + volume")
check(cap.eq == EqValues(bass: 2, mid: -1, treble: 4), "profile capture: eq")
check(cap.multipoint == true, "profile capture: multipoint")

// ── summary ─────────────────────────────────────────────────────────────────────

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
