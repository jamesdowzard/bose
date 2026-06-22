package au.com.jd.bose

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    // ── parseModeConfig (1F,06) + buildModeConfigSet ──────────────────────────
    // The CORRECT noise-level path (1F,06 RMW), replacing the 1F,0A footgun (#83).
    // Mirrors macOS `cli/Tests/main.swift` byte-for-byte (52-byte response).

    private fun mc(index: Int, name: String, mutability: Int, level: Int, anc: Int): IntArray {
        val p = IntArray(48)
        p[0] = index; p[3] = 1 // userConfigurable
        name.toByteArray(Charsets.UTF_8).forEachIndexed { i, b -> if (i < 32) p[6 + i] = b.toInt() and 0xFF }
        p[41] = mutability; p[42] = level; p[47] = anc
        return intArrayOf(0x1F, 0x06, 0x03, 0x30) + p
    }

    @Test
    fun modeConfig_parsesAdjustableCustom() {
        val cfg = Parsers.parseModeConfig(mc(5, "None", 0x1D, 7, 1))!!
        assertTrue(cfg.cncMutable) // 0x1D bit0 → adjustable
        assertEquals(7, cfg.cncLevel)
        assertEquals("None", cfg.displayName)
    }

    @Test
    fun modeConfig_fixedModeNotMutable() {
        val cfg = Parsers.parseModeConfig(mc(0, "Quiet", 0x00, 0, 1))!!
        assertFalse(cfg.cncMutable) // Quiet/Aware/spatial → fixed
    }

    @Test
    fun modeConfig_shortOrNonRespIsNull() {
        assertNull(Parsers.parseModeConfig(intArrayOf(0x1F, 0x06, 0x03, 0x05, 0, 0)))
        assertNull(Parsers.parseModeConfig(intArrayOf(0x1F, 0x06, 0x01, 0x00)))
    }

    @Test
    fun buildModeConfigSet_changesLevelForcesAnc() {
        val cfg = Parsers.parseModeConfig(mc(5, "None", 0x1D, 7, 1))!!
        val f = Parsers.buildModeConfigSet(cfg, 3)
        assertArrayEquals(intArrayOf(0x1F, 0x06, 0x02, 0x28), f.copyOfRange(0, 4)) // SET_GET len 40
        val sp = f.copyOfRange(4, f.size)
        assertEquals(5, sp[0]) // modeIndex @0
        assertArrayEquals("None".map { it.code }.toIntArray(), sp.copyOfRange(3, 7)) // name @3
        assertEquals(3, sp[35]) // new cncLevel @35
        assertEquals(1, sp[39]) // ancToggle forced ON @39 (level change can't disable ANC)
        assertEquals(7, Parsers.buildModeConfigSet(cfg, null).copyOfRange(4, 4 + 40)[35]) // nil keeps current
        assertEquals(10, Parsers.buildModeConfigSet(cfg, 99).copyOfRange(4, 4 + 40)[35]) // clamps to 10
    }

    // ── Immersive Audio / spatial (1F,06 response[41] bit2 + response[44]) ──────
    // Live verBosita (fw 8.2.20): custom modes p[41]=0x1d → spatialMutable; Immersion
    // p[44]=2 (Motion), Cinema p[44]=1 (Still). spatial byte: 0 off, 1 Still, 2 Motion.
    // Mirrors macOS `cli/Tests/main.swift`.

    private fun mcSpatial(value: Int): IntArray {
        val f = mc(5, "None", 0x1D, 7, 1)
        f[4 + 44] = value
        return f
    }

    @Test
    fun modeConfig_parsesSpatialMutableAndValue() {
        val custom = Parsers.parseModeConfig(mc(5, "None", 0x1D, 7, 1))!!
        assertTrue(custom.spatialMutable) // 0x1D bit2 → spatial editable
        val fixed = Parsers.parseModeConfig(mc(0, "Quiet", 0x00, 0, 1))!!
        assertFalse(fixed.spatialMutable)
        assertEquals(2, Parsers.parseModeConfig(mcSpatial(2))!!.spatial) // Motion
        assertEquals(1, Parsers.parseModeConfig(mcSpatial(1))!!.spatial) // Still
    }

    @Test
    fun buildModeConfigSet_changesSpatial() {
        val motionMode = Parsers.parseModeConfig(mcSpatial(0))!!
        // SET layout: spatial @37. newSpatial writes it; null keeps current; clamps to 0..2.
        assertEquals(2, Parsers.buildModeConfigSet(motionMode, null, 2).copyOfRange(4, 4 + 40)[37])
        assertEquals(2, Parsers.buildModeConfigSet(Parsers.parseModeConfig(mcSpatial(2))!!, null).copyOfRange(4, 4 + 40)[37]) // null keeps
        assertEquals(2, Parsers.buildModeConfigSet(motionMode, null, 9).copyOfRange(4, 4 + 40)[37]) // clamps to 2
        // level + spatial together: level @35, spatial @37
        val both = Parsers.buildModeConfigSet(motionMode, 4, 1).copyOfRange(4, 4 + 40)
        assertEquals(4, both[35]); assertEquals(1, both[37])
    }

    // ── Favorites (1F,08) ──────────────────────────────────────────────────────
    // Live capture on verBosita (fw 8.2.20): GET 1F 08 01 00 -> STATUS 1f 08 03 03 0b 00 07.
    // count 0x0b (11 slots) + reversed-order bitmask 00 07 = modes 0,1,2 favourited.
    // Mirrors macOS `cli/Tests/main.swift`.

    @Test
    fun favorites_decodesCapturedBitmask() {
        val resp = intArrayOf(0x1F, 0x08, 0x03, 0x03, 0x0B, 0x00, 0x07)
        assertEquals(listOf(0, 1, 2), Parsers.parseFavorites(resp))
    }

    @Test
    fun favorites_buildsLiveNoOpSetGet() {
        assertArrayEquals(
            intArrayOf(0x1F, 0x08, 0x02, 0x03, 0x0B, 0x00, 0x07),
            Parsers.buildFavoritesSetGet(listOf(0, 1, 2), 11),
        )
    }

    @Test
    fun favorites_highModeLandsInFirstMaskByte() {
        // Reversed byte order: mode 8 -> first mask byte, low modes -> last.
        assertArrayEquals(
            intArrayOf(0x1F, 0x08, 0x02, 0x03, 0x0B, 0x01, 0x00),
            Parsers.buildFavoritesSetGet(listOf(8), 11),
        )
        assertEquals(listOf(8), Parsers.parseFavorites(intArrayOf(0x1F, 0x08, 0x03, 0x03, 0x0B, 0x01, 0x00)))
    }

    @Test
    fun favorites_buildParseRoundTrips() {
        val mixed = listOf(0, 2, 9)
        val frame = Parsers.buildFavoritesSetGet(mixed, 11)
        val asResp = intArrayOf(0x1F, 0x08, 0x03) + frame.copyOfRange(3, frame.size)
        assertEquals(mixed, Parsers.parseFavorites(asResp))
    }

    @Test
    fun favorites_shortOrWrongHeaderIsNull() {
        assertNull(Parsers.parseFavorites(intArrayOf(0x1F, 0x08, 0x01, 0x00))) // non-RESP (GET echo)
        assertNull(Parsers.parseFavorites(intArrayOf(0x1F, 0x06, 0x03, 0x03, 0x0B, 0x00, 0x07))) // wrong func
    }

    // ── parseAllState (bulk session) ──────────────────────────────────────────

    @Test
    fun allState_decodesFullSession() {
        val responses: Map<Pair<Int, Int>, IntArray> = mapOf(
            (0x02 to 0x02) to intArrayOf(0x02, 0x02, 0x03, 0x04, 0x4B, 0x00, 0x00, 0x01), // battery 75% charging
            (0x1F to 0x03) to intArrayOf(0x1F, 0x03, 0x03, 0x01, 0x01),                   // ANC aware
            (0x05 to 0x05) to intArrayOf(0x05, 0x05, 0x03, 0x02, 0x1F, 0x14),             // volMax 31, vol 20
            (0x05 to 0x01) to twoDevices,
            (0x01 to 0x0A) to intArrayOf(0x01, 0x0A, 0x03, 0x01, 0x07),                   // multipoint on
            (0x01 to 0x18) to intArrayOf(0x01, 0x18, 0x03, 0x01, 0x01),                   // auto-pause on
            (0x01 to 0x1B) to intArrayOf(0x01, 0x1B, 0x03, 0x01, 0x00),                   // auto-answer off
            (0x1F to 0x08) to intArrayOf(0x1F, 0x08, 0x03, 0x03, 0x0B, 0x00, 0x07),       // favorites 0/1/2
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
        assertTrue(s.multipointEnabled)
        assertTrue(s.autoPlayPause)            // 01,18 status byte 0x01 & 0x01 → on
        assertFalse(s.autoAnswer)              // 01,1B status byte 0x00 → off
        assertEquals(listOf(0, 1, 2), s.favorites) // 1F,08 reversed bitmask 00 07
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
