/// bose-ctl: CLI for the Bose QC Ultra 2, rebuilt on the shared generated layer.
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
        case "custom1": modeByte = AncMode.custom1.rawValue
        case "custom2": modeByte = AncMode.custom2.rawValue
        default: fail("unknown ANC mode: \(mode) (quiet/aware/custom1/custom2)")
        }
        guard transport.oneShot(BMAP.setAncMode(mode: modeByte)) != nil else {
            fail("failed to set ANC mode")
        }
    }
    guard let r = transport.oneShot(BMAP.getAncMode()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("headphones not reachable") }
    print("ANC: \(ancModeName(Int(r[4])))")
}

/// devices — known devices with audio-active / connection state (ground truth).
/// Uses the getConnectedDevices composite (05,01) — the reliable source — not the
/// v1 unreliable getDeviceInfo status byte.
func cmdDevices() {
    let connected = Set(transport.getConnectedDevices().map { macString($0) })
    if connected.isEmpty && !transport.isHeadphoneConnected() {
        fail("headphones not reachable")
    }
    for dev in BoseDeviceMap.knownDevices {
        let isConnected = connected.contains(dev.macString)
        let state = isConnected ? "●" : "·"
        print("  \(state) \(dev.name)")
    }
}

/// connect / c <device> — poll-confirm via getConnectedDevices (ACK is NOT success).
func cmdConnect(_ deviceName: String) {
    let mac = macForName(deviceName)

    // For the Mac itself, ensure A2DP first (macOS link), like v1/the app.
    if isMacDevice(mac) {
        runBlueutil(["--connect", Headphone.mac])
        Thread.sleep(forTimeInterval: 1.5)
    }

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    if pollConfirmConnected(mac) {
        print("Connected \(deviceName)")
    } else {
        fail("connect \(deviceName) not confirmed within timeout")
    }
}

/// swap <device> — same as connect: multipoint keeps both devices connected and
/// audio routes to whichever got the last connect. (v1's help text wrongly said
/// "Disconnect others" — it never disconnected anything; corrected here + in usage.)
func cmdSwap(_ targetName: String) {
    let mac = macForName(targetName)

    if isMacDevice(mac) {
        runBlueutil(["--connect", Headphone.mac])
        Thread.sleep(forTimeInterval: 1.5)
    }

    _ = transport.oneShot(BMAP.connectDevice(mac: mac), timeout: 5.0)

    if pollConfirmConnected(mac) {
        print("Swapped to \(targetName)")
    } else {
        fail("swap to \(targetName) not confirmed within timeout")
    }
}

/// Poll getConnectedDevices until `mac` is audio-active (~16s budget). Offline
/// devices page slowly. Mirrors the macOS BoseManager poll-confirm.
func pollConfirmConnected(_ mac: [UInt8]) -> Bool {
    let target = macString(mac)
    let deadline = Date().addingTimeInterval(16.0)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 1.5)
        let active = transport.getConnectedDevices().map { macString($0) }
        if active.contains(target) { return true }
    }
    return false
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
        _ = transport.oneShot(BMAP.setMultipoint(state: on ? 0x07 : 0x00))
    }
    guard let r = transport.oneShot(BMAP.getMultipoint()),
          r.count >= 5, r[2] == OP_RESP_BYTE else { fail("multipoint query failed") }
    print((r[4] & 0xFF) != 0 ? "on" : "off")
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
            fail("usage: bose-ctl eq <bass> <mid> <treble> (each -10 to +10)")
        }
        // One SET_GET per band via the generated builder.
        let writes: [(Int, EqBand)] = [(bass, .bass), (mid, .mid), (treble, .treble)]
        for (value, band) in writes {
            guard transport.oneShot(BMAP.setEqBand(value: Int8(value), band: band.rawValue)) != nil else {
                fail("EQ set failed")
            }
        }
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
    bose-ctl — Bose QC Ultra 2 control (direct RFCOMM, generated BMAP layer)

    Usage:
      bose-ctl status               Connection, battery, ANC, volume, EQ (one session)
      bose-ctl battery              Battery level
      bose-ctl devices              Known devices with audio-active state
      bose-ctl connect <device>     Route audio to device (poll-confirmed)
      bose-ctl disconnect <device>  Disconnect a device
      bose-ctl swap <device>        Route audio to device (multipoint; keeps others)
      bose-ctl anc [mode]           Get/set ANC (quiet/aware/custom1/custom2)
      bose-ctl volume [0-31]        Get/set volume
      bose-ctl multipoint [on|off]  Get/set multipoint
      bose-ctl play|pause|next|prev Media transport
      bose-ctl eq [bass mid treble] Get/set EQ (each -10 to +10)
      bose-ctl raw <hex>            Send raw BMAP bytes

    Devices: \(BoseDeviceMap.knownDevices.map { $0.name }.joined(separator: ", "))
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(0) }

func requireArg(_ name: String) -> String {
    guard args.count >= 3 else { fail("Usage: bose-ctl \(args[1].lowercased()) <\(name)>") }
    return args[2].lowercased()
}

switch args[1].lowercased() {
case "status", "s":            cmdStatus()
case "battery", "b":           cmdBattery()
case "anc":                    cmdAnc(args.count >= 3 ? args[2] : nil)
case "devices":                cmdDevices()
case "connect", "c":           cmdConnect(requireArg("device"))
case "disconnect", "d":        cmdDisconnect(requireArg("device"))
case "swap":                   cmdSwap(requireArg("device"))
case "volume", "vol", "v":     cmdVolume(args.count >= 3 ? args[2] : nil)
case "multipoint", "mp":       cmdMultipoint(args.count >= 3 ? args[2] : nil)
case "play":                   cmdMedia(.play)
case "pause":                  cmdMedia(.pause)
case "next":                   cmdMedia(.next)
case "prev":                   cmdMedia(.prev)
case "eq":                     cmdEq(args.count >= 3 ? Array(args[2...]) : [])
case "raw":                    cmdRaw(requireArg("hex"))
case "-h", "--help", "help":   usage()
default:
    fail("Unknown command: \(args[1])")
}
