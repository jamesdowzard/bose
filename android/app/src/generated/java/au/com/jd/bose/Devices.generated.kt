// DO NOT EDIT — generated from devices.toml
// Source of truth: protocol/spec/devices.toml — regenerate with `make gen`.
// The single home for the headphone MAC + device map — no duplicate literals.

package au.com.jd.bose

/** The headphones themselves (the RFCOMM target). */
object Headphone {
    const val MAC = "E4:58:BC:C0:2F:72"  // BluetoothAdapter.getRemoteDevice format
    const val NAME = "verBosita"
}

/** A paired device the headphones can route audio to. */
data class BoseDevice(
    val name: String,
    val mac: ByteArray,
    val widget: Boolean,
    val label: String? = null,  // friendly display name; null -> fall back to name
    val priority: Int = 999,  // 1 = highest; lowest-priority held device is evicted on a full-multipoint connect
) {
    val macString: String get() = mac.joinToString(":") { "%02X".format(it) }

    // ByteArray needs structural equals/hashCode for data-class semantics.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BoseDevice) return false
        return name == other.name && mac.contentEquals(other.mac) &&
            widget == other.widget && label == other.label && priority == other.priority
    }

    override fun hashCode(): Int =
        (((name.hashCode() * 31 + mac.contentHashCode()) * 31 + widget.hashCode()) * 31 +
            (label?.hashCode() ?: 0)) * 31 + priority
}

/** Single source of truth for the paired device map (from devices.toml). */
object BoseDeviceMap {
    /** All known devices: cycle-order first, then source-only extras. */
    val knownDevices: List<BoseDevice> = listOf(
        BoseDevice("mac", byteArrayOf(0xBC.toByte(), 0xD0.toByte(), 0x74, 0x11, 0xDB.toByte(), 0x27), widget = true, label = null, priority = 1),
        BoseDevice("quest", byteArrayOf(0x78, 0xC4.toByte(), 0xFA.toByte(), 0xC8.toByte(), 0x5C, 0x3D), widget = true, label = null, priority = 5),
        BoseDevice("ipad", byteArrayOf(0xF4.toByte(), 0x81.toByte(), 0xC4.toByte(), 0xB5.toByte(), 0xFA.toByte(), 0xAB.toByte()), widget = true, label = null, priority = 4),
        BoseDevice("iphone", byteArrayOf(0xF8.toByte(), 0x4D, 0x89.toByte(), 0xC4.toByte(), 0xB6.toByte(), 0xED.toByte()), widget = true, label = null, priority = 7),
        BoseDevice("tv", byteArrayOf(0xB4.toByte(), 0x23, 0xA2.toByte(), 0x45, 0x9C.toByte(), 0x4D), widget = false, label = "Living Room TV", priority = 6),
        BoseDevice("appletv", byteArrayOf(0x48, 0xE1.toByte(), 0x5C, 0x5D, 0x33, 0xB6.toByte()), widget = false, label = "Katrina's Apple TV", priority = 3),
        BoseDevice("phone", byteArrayOf(0xA8.toByte(), 0x76, 0x50, 0xD3.toByte(), 0xB1.toByte(), 0x1B), widget = true, label = null, priority = 2),
        BoseDevice("audikast", byteArrayOf(0x00, 0x1D, 0x43, 0xB8.toByte(), 0x03, 0x01), widget = false, label = "Avantree Audikast Plus", priority = 8),
    )

    /** name -> device, insertion-ordered to match cycle order. */
    val byName: Map<String, BoseDevice> =
        knownDevices.associateByTo(LinkedHashMap()) { it.name }

    val CYCLE_ORDER = listOf("mac", "quest", "ipad", "iphone", "tv", "appletv", "phone")

    /** Devices that get a home-screen widget button (excludes macOS-only ones). */
    val widgetDevices: List<BoseDevice> = knownDevices.filter { it.widget }

    fun mac(name: String): ByteArray? = byName[name.lowercase()]?.mac

    fun nameForMac(mac: ByteArray): String =
        knownDevices.firstOrNull { it.mac.contentEquals(mac) }?.name
            ?: mac.joinToString(":") { "%02X".format(it) }
}
