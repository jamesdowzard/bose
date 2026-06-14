// DO NOT EDIT — generated from devices.toml
// Source of truth: protocol/spec/devices.toml — regenerate with `make gen`.
// The single home for the headphone MAC + device map — no duplicate literals.

import Foundation

/// The headphones themselves (the RFCOMM target).
enum Headphone {
    static let mac = "E4:58:BC:C0:2F:72"
    static let dashMac = "E4-58-BC-C0-2F-72"  // IOBluetooth addressString format
    static let name = "verBosita"
}

/// A paired device the headphones can route audio to.
struct BoseDevice: Identifiable {
    let name: String
    let mac: [UInt8]
    let widget: Bool
    let label: String?  // friendly display name; nil -> fall back to name
    let priority: Int   // 1 = highest; lowest-priority held device is evicted on a full-multipoint connect
    var id: String { name }
    var macString: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

enum BoseDeviceMap {
    static let knownDevices: [BoseDevice] = [
        BoseDevice(name: "mac", mac: [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27], widget: true, label: nil, priority: 1),
        BoseDevice(name: "quest", mac: [0x78, 0xC4, 0xFA, 0xC8, 0x5C, 0x3D], widget: true, label: nil, priority: 5),
        BoseDevice(name: "ipad", mac: [0xF4, 0x81, 0xC4, 0xB5, 0xFA, 0xAB], widget: true, label: nil, priority: 4),
        BoseDevice(name: "iphone", mac: [0xF8, 0x4D, 0x89, 0xC4, 0xB6, 0xED], widget: true, label: nil, priority: 7),
        BoseDevice(name: "tv", mac: [0x14, 0xC1, 0x4E, 0xB7, 0xCB, 0x68], widget: false, label: nil, priority: 6),
        BoseDevice(name: "appletv", mac: [0x48, 0xE1, 0x5C, 0x5D, 0x33, 0xB6], widget: false, label: "Katrina's Apple TV", priority: 3),
        BoseDevice(name: "phone", mac: [0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B], widget: true, label: nil, priority: 2),
    ]

    static let cycleOrder = ["mac", "quest", "ipad", "iphone", "tv", "appletv", "phone"]

    static func device(_ name: String) -> BoseDevice? {
        knownDevices.first { $0.name == name.lowercased() }
    }

    static func mac(_ name: String) -> [UInt8]? { device(name)?.mac }

    static func name(forMac mac: [UInt8]) -> String? {
        knownDevices.first { $0.mac == mac }?.name
    }
}
