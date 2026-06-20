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
        // mac (prio 1) + phone (prio 2) held; switching to ipad -> evict phone (higher number).
        assertEquals("phone", evictionVictim(listOf(mac("mac"), mac("phone")), mac("ipad"))?.name)
        // mac (prio 1) + ipad (prio 4) held; switching to phone -> evict ipad.
        assertEquals("ipad", evictionVictim(listOf(mac("mac"), mac("ipad")), mac("phone"))?.name)
        // Order of the held list must not matter — selection is by priority, not position.
        assertEquals("ipad", evictionVictim(listOf(mac("ipad"), mac("mac")), mac("phone"))?.name)
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
