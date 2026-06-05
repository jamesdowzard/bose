package au.com.jd.bose

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests for the pure BMAP composite parsers (no hardware, no Android stubs).
 *
 * The captured response byte arrays mirror the macOS `macos/Tests/main.swift`
 * corpus 1:1 — the two platforms decode the same hardware-verified frames, so the
 * Android parsers must produce identical results.
 */
class ParsersTest {

    // Header [05 01 RESP len], count at [6], 6-byte MACs from [7].
    // Two devices: mac (BC..27) + phone (A8..1B).
    private val twoDevices = intArrayOf(
        0x05, 0x01, 0x03, 0x0E, 0x00, 0x00, 0x02,
        0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27,
        0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B,
    )

    // ── parseConnectedDevices (05,01) ──────────────────────────────────────────

    @Test
    fun connectedDevices_parsesTwoMacs() {
        val cd = Parsers.parseConnectedDevices(twoDevices)
        assertEquals(2, cd.size)
        assertArrayEquals(intArrayOf(0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27), cd[0])
        assertArrayEquals(intArrayOf(0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B), cd[1])
    }

    @Test
    fun connectedDevices_countZeroIsEmpty() {
        val zero = intArrayOf(0x05, 0x01, 0x03, 0x01, 0x00, 0x00, 0x00)
        assertTrue(Parsers.parseConnectedDevices(zero).isEmpty())
    }

    @Test
    fun connectedDevices_truncatedStopsAtBoundary() {
        val truncated = intArrayOf(
            0x05, 0x01, 0x03, 0x08, 0x00, 0x00, 0x02, 0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27,
        )
        assertEquals(1, Parsers.parseConnectedDevices(truncated).size)
    }

    @Test
    fun connectedDevices_wrongHeaderIsEmpty() {
        assertTrue(Parsers.parseConnectedDevices(intArrayOf(0x04, 0x09, 0x03, 0x00)).isEmpty())
        // non-RESP (GET echo)
        assertTrue(Parsers.parseConnectedDevices(intArrayOf(0x05, 0x01, 0x01, 0x00)).isEmpty())
        assertTrue(Parsers.parseConnectedDevices(intArrayOf()).isEmpty())
    }

    // ── parseCncLevel (1F,0A) + buildCncSet ───────────────────────────────────

    private val cncResp = intArrayOf(0x1F, 0x0A, 0x03, 0x05, 0x07, 0x01, 0x00, 0x01, 0x01)

    @Test
    fun cncLevel_parsesAndPreservesFields() {
        val cfg = Parsers.parseCncLevel(cncResp)!!
        assertEquals(7, cfg.level)
        assertEquals(1, cfg.autoCNC)
        assertEquals(0, cfg.spatial)
        assertEquals(1, cfg.windBlock)
        assertEquals(1, cfg.ancToggle)
    }

    @Test
    fun cncLevel_shortOrNonRespIsNull() {
        assertNull(Parsers.parseCncLevel(intArrayOf(0x1F, 0x0A, 0x03, 0x01, 0x05)))
        assertNull(Parsers.parseCncLevel(intArrayOf(0x1F, 0x0A, 0x01, 0x00)))
    }

    @Test
    fun buildCncSet_changesLevelPreservesRest() {
        val cfg = Parsers.parseCncLevel(cncResp)!!
        assertArrayEquals(
            intArrayOf(0x1F, 0x0A, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x01),
            Parsers.buildCncSet(3, cfg),
        )
        assertEquals(10, Parsers.buildCncSet(99, cfg)[4]) // clamps to 10
    }

    // ── parseAllState (bulk session) ──────────────────────────────────────────

    @Test
    fun allState_decodesFullSession() {
        val responses: Map<Pair<Int, Int>, IntArray> = mapOf(
            (0x02 to 0x02) to intArrayOf(0x02, 0x02, 0x03, 0x04, 0x4B, 0x00, 0x00, 0x01), // battery 75% charging
            (0x1F to 0x03) to intArrayOf(0x1F, 0x03, 0x03, 0x01, 0x01),                   // ANC aware
            (0x05 to 0x05) to intArrayOf(0x05, 0x05, 0x03, 0x02, 0x1F, 0x14),             // volMax 31, vol 20
            (0x05 to 0x01) to twoDevices,
            (0x1F to 0x0A) to cncResp,                                                    // cnc level 7
            (0x01 to 0x0A) to intArrayOf(0x01, 0x0A, 0x03, 0x01, 0x07),                   // multipoint on
            (0x08 to 0x07) to intArrayOf(0x08, 0x07, 0x03, 0x01, 0x04),                   // on head
            (0x00 to 0x05) to (intArrayOf(0x00, 0x05, 0x03, 0x05) + "1.2.3".map { it.code }.toIntArray()),
            // EQ RESP: value bytes at absolute indices 6, 10, 14 (signed).
            (0x01 to 0x07) to intArrayOf(
                0x01, 0x07, 0x03, 0x0C,
                0xF6, 0x0A, 0x03, 0x00,    // index 6  = bass = +3
                0xF6, 0x0A, 0x00, 0x01,    // index 10 = mid  = 0
                0xF6, 0x0A, 0xFD, 0x02,    // index 14 = treble = -3 (0xFD two's complement)
            ),
        )
        val s = Parsers.parseAllState { block, function -> responses[block to function] }
        assertEquals(75, s.batteryLevel)
        assertTrue(s.batteryCharging)
        assertEquals(1, s.ancMode)
        assertEquals(20, s.volume)
        assertEquals(31, s.volumeMax)
        assertEquals(2, s.connectedDevices.size)
        assertEquals(7, s.cncLevel)
        assertTrue(s.multipointEnabled)
        assertTrue(s.onHead)
        assertEquals("1.2.3", s.firmware)
        assertEquals(3, s.eqBass)
        assertEquals(0, s.eqMid)
        assertEquals(-3, s.eqTreble)
    }

    @Test
    fun allState_allNilProviderKeepsDefaults() {
        val empty = Parsers.parseAllState { _, _ -> null }
        assertEquals(0, empty.batteryLevel)
        assertTrue(empty.connectedDevices.isEmpty())
    }
}
