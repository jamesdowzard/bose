/// bose-ctl: CLI for Bose QC Ultra headphone control
/// All commands go through bosed daemon (Unix socket → phone → RFCOMM).
/// No direct RFCOMM — phone is the sole controller.

import Foundation

let DAEMON_SOCKET = "/tmp/bosed.sock"

// Known device names
let knownDevices: [String: String] = [
    "mac":    "BC:D0:74:11:DB:27",
    "phone":  "A8:76:50:D3:B1:1B",
    "ipad":   "F4:81:C4:B5:FA:AB",
    "iphone": "F8:4D:89:C4:B6:ED",
    "tv":     "14:C1:4E:B7:CB:68",
]

// === Daemon Client ===

func daemonRequest(_ json: [String: Any], timeout: Int = 10) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        DAEMON_SOCKET.withCString { cstr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strcpy(dest, cstr)
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Foundation.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return nil }

    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard let requestData = try? JSONSerialization.data(withJSONObject: json),
          let requestStr = String(data: requestData, encoding: .utf8) else { return nil }

    let sent = requestStr.withCString { ptr in write(fd, ptr, requestStr.utf8.count) }
    guard sent > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: 8192)
    let bytesRead = read(fd, &buffer, buffer.count)
    guard bytesRead > 0 else { return nil }

    let responseStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
    guard let respData = responseStr.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else { return nil }

    return parsed
}

func runCommand(_ cmd: String, _ args: [String]) {
    var request: [String: Any]
    var timeout = 10

    switch cmd {
    case "status", "s":
        request = ["cmd": "status"]
    case "connect", "c":
        guard args.count >= 3 else { print("Usage: bose-ctl connect <device>"); exit(1) }
        request = ["cmd": "connect", "device": args[2]]
        timeout = 15
    case "disconnect", "d":
        guard args.count >= 3 else { print("Usage: bose-ctl disconnect <device>"); exit(1) }
        request = ["cmd": "disconnect", "device": args[2]]
    case "swap":
        guard args.count >= 3 else { print("Usage: bose-ctl swap <device>"); exit(1) }
        request = ["cmd": "swap", "device": args[2]]
        timeout = 15
    case "battery", "b":
        request = ["cmd": "battery"]
    case "devices":
        request = ["cmd": "devices"]
        timeout = 15
    case "anc":
        if args.count >= 3 {
            request = ["cmd": "anc", "mode": args[2]]
        } else {
            request = ["cmd": "anc"]
        }
    case "reconnect":
        request = ["cmd": "reconnect"]
        timeout = 15
    case "raw":
        guard args.count >= 3 else { print("Usage: bose-ctl raw <hex>"); exit(1) }
        request = ["cmd": "raw", "hex": args[2]]
    default:
        print("Unknown command: \(cmd)")
        exit(1)
    }

    guard let response = daemonRequest(request, timeout: timeout) else {
        print("Error: bosed daemon not running. Start it with: launchctl load ~/Library/LaunchAgents/com.jamesdowzard.bosed.plist")
        exit(1)
    }

    guard let ok = response["ok"] as? Bool else {
        print("Error: invalid response")
        exit(1)
    }

    if !ok {
        let error = response["error"] as? String ?? "unknown error"
        print("Error: \(error)")
        exit(1)
    }

    guard let data = response["data"] as? [String: Any] else {
        print("OK")
        return
    }

    // Format output
    switch cmd {
    case "status", "s":
        let connected = data["rfcomm_connected"] as? Bool ?? false
        if !connected {
            print("RFCOMM: disconnected")
            return
        }
        if let active = data["active_device"] as? String {
            print("Active:   \(active)")
        }
        if let devices = data["connected_devices"] as? [String] {
            print("Connected: \(devices.joined(separator: ", "))")
        }
        if let s1 = data["slot1"] as? String {
            let s2 = data["slot2"] as? String ?? "—"
            print("Slots:    \(s1) | \(s2)")
        }
        if let bat = data["battery_level"] as? Int {
            let charging = data["battery_charging"] as? Bool ?? false
            print("Battery:  \(bat)%\(charging ? " ⚡" : "")")
        }
        if let anc = data["anc_mode"] as? String {
            print("ANC:      \(anc)")
        }
        if let fw = data["firmware"] as? String {
            print("Firmware: \(fw)")
        }

    case "connect", "c":
        let device = data["device"] as? String ?? "?"
        print("Switched to \(device)")

    case "disconnect", "d":
        let device = data["device"] as? String ?? "?"
        print("Disconnected \(device)")

    case "swap":
        let device = data["device"] as? String ?? "?"
        print("Swapped to \(device)")

    case "battery", "b":
        let level = data["level"] as? Int ?? 0
        let charging = data["charging"] as? Bool ?? false
        print("\(level)%\(charging ? " ⚡" : "")")

    case "devices":
        if let devices = data["devices"] as? [[String: Any]] {
            for d in devices {
                let name = d["name"] as? String ?? "?"
                let devName = d["device_name"] as? String ?? ""
                let connected = d["connected"] as? Bool ?? false
                let primary = d["primary"] as? Bool ?? false
                let state = primary ? "●" : (connected ? "○" : "·")
                print("  \(state) \(name)\(devName.isEmpty ? "" : " (\(devName))")")
            }
        }

    case "anc":
        let mode = data["mode"] as? String ?? "?"
        print("ANC: \(mode)")

    case "reconnect":
        let connected = data["connected"] as? Bool ?? false
        print(connected ? "Connected" : "Failed to connect")

    case "raw":
        if let hex = data["hex"] as? String, let length = data["length"] as? Int {
            print("Response (\(length) bytes): \(hex)")
            if let ascii = data["ascii"] as? String, !ascii.isEmpty {
                print("ASCII: \(ascii)")
            }
        } else {
            print("No response")
        }

    default:
        break
    }
}

// === Main ===
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    bose-ctl — Bose QC Ultra 2 control (via bosed daemon)

    Usage:
      bose-ctl status              Connection status, battery, ANC
      bose-ctl connect <device>    Switch audio to device
      bose-ctl disconnect <device> Disconnect device
      bose-ctl swap <device>       Disconnect others, switch to device
      bose-ctl battery             Battery level
      bose-ctl devices             All devices with connection state
      bose-ctl anc [mode]          Get/set ANC (quiet/aware/custom1/custom2)
      bose-ctl reconnect           Reconnect RFCOMM
      bose-ctl raw <hex>           Send raw BMAP bytes

    Devices: \(knownDevices.keys.sorted().joined(separator: ", "))
    """)
    exit(0)
}

runCommand(args[1].lowercased(), args)
