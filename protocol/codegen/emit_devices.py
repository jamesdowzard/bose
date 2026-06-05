"""Emit the Swift device map from the parsed devices.toml spec.

`devices.toml` is the single source of truth for the headphone MAC + the paired
device map + cycle order. The macOS app (and CLI) consume `Devices.generated.swift`
so no MAC string literal is ever duplicated in hand-written code.

Produces:
  - `enum Headphone`            — the headphone MAC (colon + dash form) and name
  - `struct BoseDevice`         — name + 6-byte MAC + widget flag
  - `enum BoseDeviceMap`        — knownDevices list + cycleOrder
"""


def _mac_bytes_literal(mac: str) -> str:
    """'BC:D0:74:11:DB:27' -> '0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27'."""
    parts = mac.replace("-", ":").split(":")
    return ", ".join(f"0x{int(p, 16):02X}" for p in parts)


def _dash(mac: str) -> str:
    return mac.replace(":", "-")


def emit_devices_swift(spec: dict) -> str:
    headphone_mac = spec["headphone_mac"]
    headphone_name = spec["headphone_name"]
    cycle = spec["cycle_order"]
    devices = spec["devices"]

    lines: list[str] = []
    lines.append("import Foundation")
    lines.append("")
    lines.append("/// The headphones themselves (the RFCOMM target).")
    lines.append("enum Headphone {")
    lines.append(f'    static let mac = "{headphone_mac}"')
    lines.append(f'    static let dashMac = "{_dash(headphone_mac)}"  // IOBluetooth addressString format')
    lines.append(f'    static let name = "{headphone_name}"')
    lines.append("}")
    lines.append("")
    lines.append("/// A paired device the headphones can route audio to.")
    lines.append("struct BoseDevice: Identifiable {")
    lines.append("    let name: String")
    lines.append("    let mac: [UInt8]")
    lines.append("    let widget: Bool")
    lines.append("    var id: String { name }")
    lines.append("    var macString: String {")
    lines.append('        mac.map { String(format: "%02X", $0) }.joined(separator: ":")')
    lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append("enum BoseDeviceMap {")
    lines.append("    static let knownDevices: [BoseDevice] = [")
    # Emit in cycle order so the list is deterministic and matches switch order.
    for name in cycle:
        d = devices[name]
        widget = "true" if d.get("widget", False) else "false"
        lines.append(
            f'        BoseDevice(name: "{name}", mac: [{_mac_bytes_literal(d["mac"])}], widget: {widget}),'
        )
    lines.append("    ]")
    lines.append("")
    cycle_lit = ", ".join(f'"{n}"' for n in cycle)
    lines.append(f"    static let cycleOrder = [{cycle_lit}]")
    lines.append("")
    lines.append("    static func device(_ name: String) -> BoseDevice? {")
    lines.append("        knownDevices.first { $0.name == name.lowercased() }")
    lines.append("    }")
    lines.append("")
    lines.append("    static func mac(_ name: String) -> [UInt8]? { device(name)?.mac }")
    lines.append("")
    lines.append("    static func name(forMac mac: [UInt8]) -> String? {")
    lines.append("        knownDevices.first { $0.mac == mac }?.name")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)
