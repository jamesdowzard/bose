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
 * Returns the device to evict, or null when no eviction is needed/possible:
 *  - target already held (it's one of the two)            -> null
 *  - a slot is free (fewer than 2 devices held)            -> null
 *  - both full but neither held device is in our map       -> null (let the firmware decide)
 */
private fun macKey(mac: IntArray): String = mac.joinToString(":") { "%02X".format(it and 0xFF) }

fun evictionVictim(heldMacs: List<IntArray>, targetMac: IntArray): BoseDevice? {
    val heldKeys = heldMacs.map { macKey(it) }.toSet()
    if (macKey(targetMac) in heldKeys) return null // already connected — nothing to evict
    if (heldKeys.size < 2) return null // a slot is free — no eviction needed
    return BoseDeviceMap.knownDevices
        .filter { it.macString in heldKeys }
        .maxByOrNull { it.priority } // highest priority number = lowest priority = the victim
}
