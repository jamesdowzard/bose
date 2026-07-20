package au.com.jd.bose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure unit tests for multipoint-eviction victim selection (Eviction.kt) — the Android
 * parity for the CLI's evictLowestPriorityIfFull. Hardware-free: drives the selection off
 * the generated BoseDeviceMap priorities (1 mac, 2 phone, 3 appletv, 4 ipad, 5 quest, 6 tv,
 * 7 iphone). Mirrors the macOS behaviour proven on-device.
 */
class EvictionTest {
    private fun mac(name: String) = BoseDeviceMap.mac(name)!!.toIntArray()

    @Test
    fun bothSlotsFull_targetNotHeld_evictsLowestPriority() {
        // mac (prio 1) + ipad (prio 4) held; switching to quest -> evict ipad (higher number).
        assertEquals("ipad", evictionVictim(listOf(mac("mac"), mac("ipad")), mac("quest"))?.name)
        // ipad (prio 4) + quest (prio 5) held; switching to iphone -> evict quest.
        assertEquals("quest", evictionVictim(listOf(mac("ipad"), mac("quest")), mac("iphone"))?.name)
        // Order of the held list must not matter — selection is by priority, not position.
        assertEquals("quest", evictionVictim(listOf(mac("quest"), mac("ipad")), mac("iphone"))?.name)
    }

    /**
     * The regression this file previously enshrined: with the everyday {mac, phone} pair
     * held, `phone` (prio 2) is the lowest-priority held device, so plain victim selection
     * chose THIS PHONE for any third target. BMAP-disconnecting the phone drops the ACL its
     * own RFCOMM socket rides on — the switch kills its own transport mid-flight. The local
     * device must never be a victim; the Mac (prio 1) goes instead.
     */
    @Test
    fun localPhoneIsNeverTheVictim() {
        assertEquals("mac", evictionVictim(listOf(mac("mac"), mac("phone")), mac("ipad"))?.name)
        assertEquals("mac", evictionVictim(listOf(mac("phone"), mac("mac")), mac("appletv"))?.name)
        // Even against a lower-priority partner, the phone is skipped and the partner goes.
        assertEquals("audikast", evictionVictim(listOf(mac("phone"), mac("audikast")), mac("ipad"))?.name)
    }

    @Test
    fun phoneIsOnlyEvictableHeldDevice_noVictim() {
        val unknown = intArrayOf(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        // Slots full with {phone, something we don't know}: the phone is off-limits and the
        // other isn't ours to rank -> no victim, let the firmware's LRU decide.
        assertNull(evictionVictim(listOf(mac("phone"), unknown), mac("ipad")))
    }

    @Test
    fun targetAlreadyHeld_noEviction() {
        assertNull(evictionVictim(listOf(mac("mac"), mac("phone")), mac("mac")))
        assertNull(evictionVictim(listOf(mac("mac"), mac("phone")), mac("phone")))
    }

    @Test
    fun freeSlot_noEviction() {
        assertNull(evictionVictim(listOf(mac("mac")), mac("ipad"))) // 1 held -> a slot is free
        assertNull(evictionVictim(emptyList(), mac("ipad")))        // 0 held
    }

    @Test
    fun unknownHeldDevice_picksAmongKnown() {
        val unknown = intArrayOf(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        // Two slots full (unknown + mac), target not held -> only known held is mac.
        assertEquals("mac", evictionVictim(listOf(unknown, mac("mac")), mac("ipad"))?.name)
    }

    @Test
    fun bothHeldUnknown_noVictim() {
        val u1 = intArrayOf(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        val u2 = intArrayOf(0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB)
        // Both slots full but neither is in our map -> let the firmware's LRU decide.
        assertNull(evictionVictim(listOf(u1, u2), mac("ipad")))
    }
}
