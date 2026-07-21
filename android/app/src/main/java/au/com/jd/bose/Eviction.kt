package au.com.jd.bose

/**
 * Deterministic multipoint-eviction victim selection — the pure, hardware-free core of the
 * connect-path device hierarchy. Mirrors macOS `evictLowestPriorityIfFull` in cli/main.swift
 * (the macOS app / Raycast / Hammerspoon inherit it by shelling `bose`; Android needs its own).
 *
 * The headset holds at most 2 devices and the firmware only evicts by its own LRU
 * (ConnectionPriority 0x10 is FuncNotSupp — see docs/reverse-engineering.md). So when both
 * slots are full and the target isn't already held, we drop the LOWEST-priority held device
 * (the highest `priority` number in devices.toml) first, so the subsequent connect lands the
 * target against our hierarchy instead of whatever the firmware's LRU would have dropped.
 *
 * THIS PHONE IS NEVER A VICTIM. Unlike the Mac's CLI — which runs on a host that isn't
 * one of the two slots it arbitrates — the Android app talks BMAP over an RFCOMM socket
 * that rides the phone's own ACL link. Disconnecting the phone therefore tears down the
 * very channel the switch is being issued on: the connect never lands and `restoreEvicted`
 * no-ops against a dead socket. With the everyday {mac, phone} pair held, plain
 * lowest-priority selection picks `phone` (priority 2) over `mac` (1) for ANY third target,
 * so the common case was a guaranteed self-destruct.
 *
 * Returns the device to evict, or null when no eviction is needed/possible:
 *  - target already held (it's one of the two)             -> null
 *  - a slot is free (fewer than 2 devices held)            -> null
 *  - the only evictable held device is this phone          -> null (let the firmware decide)
 *  - both full but neither held device is in our map       -> null (let the firmware decide)
 */
private fun macKey(mac: IntArray): String = mac.joinToString(":") { "%02X".format(it and 0xFF) }

/** devices.toml key for the local device — the S21 this app runs on. */
const val LOCAL_DEVICE_NAME = "phone"

fun evictionVictim(
    heldMacs: List<IntArray>,
    targetMac: IntArray,
    localDeviceName: String = LOCAL_DEVICE_NAME,
): BoseDevice? {
    val heldKeys = heldMacs.map { macKey(it) }.toSet()
    if (macKey(targetMac) in heldKeys) return null // already connected — nothing to evict
    if (heldKeys.size < 2) return null // a slot is free — no eviction needed
    return BoseDeviceMap.knownDevices
        .filter { it.macString in heldKeys }
        .filter { it.name != localDeviceName } // never cut the link we're talking over
        .maxByOrNull { it.priority } // highest priority number = lowest priority = the victim
}
