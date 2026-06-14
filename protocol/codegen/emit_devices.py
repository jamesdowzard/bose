"""Emit the device map (Swift + Kotlin) from the parsed devices.toml spec.

`devices.toml` is the single source of truth for the headphone MAC + the paired
device map + cycle order. The macOS app/CLI consume `Devices.generated.swift` and
the Android app consumes `Devices.generated.kt`, so no MAC string literal is ever
duplicated in hand-written code on either platform.

Produces (Swift):
  - `enum Headphone`            — the headphone MAC (colon + dash form) and name
  - `struct BoseDevice`         — name + 6-byte MAC + widget flag
  - `enum BoseDeviceMap`        — knownDevices list + cycleOrder

Produces (Kotlin):
  - `object Headphone`          — headphone MAC (colon form) + name
  - `data class BoseDevice`     — name + 6-byte MAC + widget flag
  - `object BoseDeviceMap`      — knownDevices/byName (cycle-ordered), cycleOrder,
                                  widgetDevices, mac()/nameForMac() helpers
"""


def _mac_bytes_literal(mac: str) -> str:
    """'BC:D0:74:11:DB:27' -> '0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27'."""
    parts = mac.replace("-", ":").split(":")
    return ", ".join(f"0x{int(p, 16):02X}" for p in parts)


def _kt_mac_bytes_literal(mac: str) -> str:
    """'BC:D0:74:11:DB:27' -> '0xBC.toByte(), 0xD0.toByte(), 0x74, ...'.

    Kotlin byte literals > 0x7F overflow the signed Byte range, so they need an
    explicit `.toByte()`; values <= 0x7F are valid Byte literals as-is.
    """
    parts = mac.replace("-", ":").split(":")

    def lit(p: str) -> str:
        v = int(p, 16)
        return f"0x{v:02X}.toByte()" if v > 0x7F else f"0x{v:02X}"

    return ", ".join(lit(p) for p in parts)


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
    lines.append("    let label: String?  // friendly display name; nil -> fall back to name")
    lines.append("    let priority: Int   // 1 = highest; lowest-priority held device is evicted on a full-multipoint connect")
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
        label = d.get("label")
        label_lit = f'"{label}"' if label else "nil"
        prio = d.get("priority", 999)
        lines.append(
            f'        BoseDevice(name: "{name}", mac: [{_mac_bytes_literal(d["mac"])}], '
            f"widget: {widget}, label: {label_lit}, priority: {prio}),"
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


def emit_devices_kotlin(spec: dict) -> str:
    headphone_mac = spec["headphone_mac"]
    headphone_name = spec["headphone_name"]
    cycle = spec["cycle_order"]
    devices = spec["devices"]

    lines: list[str] = []
    lines.append("package au.com.jd.bose")
    lines.append("")
    lines.append("/** The headphones themselves (the RFCOMM target). */")
    lines.append("object Headphone {")
    lines.append(f'    const val MAC = "{headphone_mac}"  // BluetoothAdapter.getRemoteDevice format')
    lines.append(f'    const val NAME = "{headphone_name}"')
    lines.append("}")
    lines.append("")
    lines.append("/** A paired device the headphones can route audio to. */")
    lines.append("data class BoseDevice(")
    lines.append("    val name: String,")
    lines.append("    val mac: ByteArray,")
    lines.append("    val widget: Boolean,")
    lines.append("    val label: String? = null,  // friendly display name; null -> fall back to name")
    lines.append("    val priority: Int = 999,  // 1 = highest; lowest-priority held device is evicted on a full-multipoint connect")
    lines.append(") {")
    lines.append('    val macString: String get() = mac.joinToString(":") { "%02X".format(it) }')
    lines.append("")
    lines.append("    // ByteArray needs structural equals/hashCode for data-class semantics.")
    lines.append("    override fun equals(other: Any?): Boolean {")
    lines.append("        if (this === other) return true")
    lines.append("        if (other !is BoseDevice) return false")
    lines.append("        return name == other.name && mac.contentEquals(other.mac) &&")
    lines.append("            widget == other.widget && label == other.label && priority == other.priority")
    lines.append("    }")
    lines.append("")
    lines.append("    override fun hashCode(): Int =")
    lines.append("        (((name.hashCode() * 31 + mac.contentHashCode()) * 31 + widget.hashCode()) * 31 +")
    lines.append("            (label?.hashCode() ?: 0)) * 31 + priority")
    lines.append("}")
    lines.append("")
    lines.append("/** Single source of truth for the paired device map (from devices.toml). */")
    lines.append("object BoseDeviceMap {")
    lines.append("    /** All known devices, in cycle order. */")
    lines.append("    val knownDevices: List<BoseDevice> = listOf(")
    for name in cycle:
        d = devices[name]
        widget = "true" if d.get("widget", False) else "false"
        label = d.get("label")
        label_lit = f'"{label}"' if label else "null"
        prio = d.get("priority", 999)
        lines.append(
            f'        BoseDevice("{name}", byteArrayOf({_kt_mac_bytes_literal(d["mac"])}), '
            f"widget = {widget}, label = {label_lit}, priority = {prio}),"
        )
    lines.append("    )")
    lines.append("")
    lines.append("    /** name -> device, insertion-ordered to match cycle order. */")
    lines.append("    val byName: Map<String, BoseDevice> =")
    lines.append("        knownDevices.associateByTo(LinkedHashMap()) { it.name }")
    lines.append("")
    cycle_lit = ", ".join(f'"{n}"' for n in cycle)
    lines.append(f"    val CYCLE_ORDER = listOf({cycle_lit})")
    lines.append("")
    lines.append("    /** Devices that get a home-screen widget button (excludes macOS-only ones). */")
    lines.append("    val widgetDevices: List<BoseDevice> = knownDevices.filter { it.widget }")
    lines.append("")
    lines.append("    fun mac(name: String): ByteArray? = byName[name.lowercase()]?.mac")
    lines.append("")
    lines.append("    fun nameForMac(mac: ByteArray): String =")
    lines.append("        knownDevices.firstOrNull { it.mac.contentEquals(mac) }?.name")
    lines.append('            ?: mac.joinToString(":") { "%02X".format(it) }')
    lines.append("}")
    lines.append("")
    return "\n".join(lines)
