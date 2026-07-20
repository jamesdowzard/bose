package au.com.jd.bose

/**
 * Pure BMAP response decoders for the composite commands.
 *
 * Deliberately free of Android / Bluetooth dependencies (no Context, no
 * BluetoothSocket) so they unit-test WITHOUT hardware — fed representative
 * response byte arrays (see app/src/test/.../ParsersTest.kt). The live-channel
 * orchestration that uses these parsers lives in `Composites.kt` (over Transport).
 *
 * Frames are `IntArray` of 0..255 values, matching the generated `BMAP` builders
 * and the macOS `Parsers.swift` corpus byte-for-byte.
 */
object Parsers {

    private const val OP_RESP = 0x03

    /** A full headphone state snapshot (decoded from one bulk session). */
    data class HeadphoneState(
        var batteryLevel: Int = 0,
        var batteryCharging: Boolean = false,
        var ancMode: Int = 0, // 0=quiet 1=aware 2=immersion 3=cinema 4/5=custom; 255=off
        var volume: Int = 0,
        var volumeMax: Int = 31,
        var connectedDevices: List<IntArray> = emptyList(), // audio-active (05,01)
        var firmware: String = "",
        var serialNumber: String = "",
        var productName: String = "",
        var platform: String = "",
        var codename: String = "",
        var audioCodec: String = "",
        var deviceName: String = "",
        var multipointEnabled: Boolean = false,
        var autoPlayPause: Boolean = false, // 01,18 — pause when removed
        var autoAnswer: Boolean = false, // 01,1B — answer call when donned
        var favorites: List<Int> = emptyList(), // 1F,08 — favourited mode slots
        var autoOffTimer: IntArray = IntArray(0),
        var eqBass: Int = 0,
        var eqMid: Int = 0,
        var eqTreble: Int = 0,
    )

    /**
     * One AudioModes mode slot, from the 1F,06 (AudioModesModeConfig) RESPONSE — the
     * CORRECT noise-level axis. Changing `cncLevel` via a 1F,06 read-modify-write keeps
     * ANC anchored to the mode (unlike the 1F,0A global write that detaches it → 255/off,
     * #83). Level semantics (fw 8.2.20): 0 = max cancellation (Quiet), 10 = full
     * transparency (Aware). Mirrors macOS `ModeConfig` byte-for-byte.
     */
    data class ModeConfig(
        val index: Int,
        val promptB1: Int,
        val promptB2: Int,
        val userConfigurable: Boolean,
        val name: IntArray, // 32 bytes, null-padded UTF-8
        val cncMutable: Boolean, // response[41] bit 0 — is the CNC level editable?
        val spatialMutable: Boolean, // response[41] bit 2 — is the spatial (Immersive Audio) mode editable?
        val cncLevel: Int,
        val autoCNC: Int,
        val spatial: Int, // 0 = off, 1 = Still (fixed-to-room), 2 = Motion (head-tracking)
        val windBlock: Int,
        val ancToggle: Int,
    ) {
        val displayName: String
            get() {
                val end = name.indexOfFirst { it == 0 }.let { if (it < 0) name.size else it }
                return String(ByteArray(end) { name[it].toByte() }, Charsets.UTF_8)
            }
    }

    /**
     * Multipoint enable from the 01,0A state byte. Bit 0 is the live enable flag; the
     * higher bits are slot/capability bits the firmware retains across toggles, so a
     * disabled-but-paired device reads 0x06, not 0x00 (#83). Mask the enable bit — the
     * old `!= 0` was the bug (0x06 != 0 misread "off" as "on"). Verified live on
     * fw 8.2.20: multipoint on -> 0x07, off -> 0x06. Mirrors macOS `parseMultipointEnabled`.
     */
    fun parseMultipointEnabled(stateByte: Int): Boolean = (stateByte and 0x01) != 0

    /**
     * Parse the connected-devices RESPONSE (05,01). Layout:
     *   [0x05, 0x01, RESP, len, ...] with count at byte 6 and 6-byte MACs from byte 7.
     * Returns [] on any malformed/short/non-RESP frame.
     */
    fun parseConnectedDevices(resp: IntArray): List<IntArray> {
        if (resp.size < 7 || resp[0] != 0x05 || resp[1] != 0x01 || resp[2] != OP_RESP) {
            return emptyList()
        }
        val count = resp[6]
        val devices = mutableListOf<IntArray>()
        for (i in 0 until count) {
            val offset = 7 + (i * 6)
            if (offset + 6 > resp.size) break
            devices.add(resp.copyOfRange(offset, offset + 6))
        }
        return devices
    }

    /**
     * Parse a 1F,06 AudioModesModeConfig RESPONSE. Payload (resp[4..]) offsets, confirmed
     * live + against the decompiled AudioModesModeConfigResponse: [0]=index, [1..2]=prompt,
     * [3]=userConfigurable, [6..37]=32-byte name, [41]=mutability bitfield (bit0=cncMutable),
     * [42]=cncLevel, [43]=autoCNC, [44]=spatial, [46]=windBlock, [47]=ancToggle. (The
     * RESPONSE layout differs from the SET payload — see buildModeConfigSet.)
     */
    fun parseModeConfig(resp: IntArray): ModeConfig? {
        if (resp.size < 4 + 48 || resp[0] != 0x1F || resp[1] != 0x06 || resp[2] != OP_RESP) return null
        val p = resp.copyOfRange(4, resp.size)
        return ModeConfig(
            index = p[0], promptB1 = p[1], promptB2 = p[2],
            userConfigurable = p[3] == 1,
            name = p.copyOfRange(6, 38), // [6..37] inclusive = 32 bytes
            cncMutable = (p[41] and 0x01) == 1,
            spatialMutable = (p[41] and 0x04) != 0,
            cncLevel = p[42], autoCNC = p[43], spatial = p[44],
            windBlock = p[46], ancToggle = p[47],
        )
    }

    /**
     * Build a 1F,06 AudioModesModeConfig SET_GET frame, changing only `cncLevel` and/or the
     * spatial (Immersive Audio) mode, and forcing `ancToggle = 1` (so a level change can't
     * disable ANC). SET payload layout (distinct from the response): [0]=index, [1..2]=prompt,
     * [3..34]=32-byte name, [35]=cncLevel, [36]=autoCNC, [37]=spatial, [38]=windBlock,
     * [39]=ancToggle. Pass newLevel/newSpatial=null to leave that field unchanged.
     * newSpatial: 0 = off, 1 = Still, 2 = Motion.
     */
    fun buildModeConfigSet(cfg: ModeConfig, newLevel: Int?, newSpatial: Int? = null): IntArray {
        val level = (newLevel ?: cfg.cncLevel).coerceIn(0, 10)
        val spatial = (newSpatial ?: cfg.spatial).coerceIn(0, 2)
        val name = IntArray(32) { if (it < cfg.name.size) cfg.name[it] else 0 }
        val payload = intArrayOf(cfg.index, cfg.promptB1, cfg.promptB2) + name +
            intArrayOf(level, cfg.autoCNC, spatial, cfg.windBlock, 0x01) // ancToggle forced on
        return intArrayOf(0x1F, 0x06, 0x02, payload.size) + payload
    }

    /**
     * Parse a 1F,08 AudioModes Favorites RESPONSE into the sorted favourited mode slots.
     * Wire format (verified live on verBosita fw 8.2.20 + the decompiled app's
     * AudioModesFavorites packets): payload[0] = slot count, then a REVERSED-order bitmask
     * of ceil(count/8) bytes — the LOW modes live in the LAST byte. For favourite mode d,
     * bit (d % 8) is set in byte (maskLen - floor(d/8) - 1). Live capture
     * `1f 08 03 03 0b 00 07` -> count 11, modes {0,1,2} (Quiet/Aware/Immersion).
     */
    fun parseFavorites(resp: IntArray): List<Int>? {
        if (resp.size < 5 || resp[0] != 0x1F || resp[1] != 0x08 || resp[2] != OP_RESP) return null
        val payload = resp.copyOfRange(4, resp.size)
        val count = payload[0]
        val mask = payload.copyOfRange(1, payload.size) // ceil(count/8) bytes, reversed order
        val modes = mutableListOf<Int>()
        for (k in mask.indices) {
            val group = mask.size - 1 - k // last byte = group 0 (modes 0..7)
            for (bit in 0 until 8) {
                if ((mask[k] shr bit) and 1 == 1) {
                    val mode = group * 8 + bit
                    if (mode < count) modes.add(mode)
                }
            }
        }
        return modes.sorted()
    }

    /**
     * Build a 1F,08 Favorites SET_GET frame from the desired favourite slots + slot count.
     * Inverse of parseFavorites; mirrors the app's AudioModesFavoritesSetGetPacket:
     * payload length = ceil(count/8)+1, payload[0] = count, bit (d % 8) of byte
     * (len - floor(d/8) - 1) set per favourite mode d. modes {0,1,2}, count 11 ->
     * `1F 08 02 03 0b 00 07` (the live no-op-restore frame).
     */
    fun buildFavoritesSetGet(modes: List<Int>, slotCount: Int): IntArray {
        val maskLen = (slotCount + 7) / 8 // ceil(count/8)
        val len = maskLen + 1
        val payload = IntArray(len)
        payload[0] = slotCount and 0xFF
        for (d in modes) if (d in 0 until slotCount) {
            payload[len - (d / 8) - 1] = payload[len - (d / 8) - 1] or (1 shl (d % 8))
        }
        return intArrayOf(0x1F, 0x08, 0x02, payload.size) + payload
    }

    /** Decode a UTF-8 string field response from a given payload offset. */
    fun parseString(resp: IntArray, from: Int = 4): String {
        if (resp.size <= from) return ""
        val bytes = ByteArray(resp.size - from) { resp[from + it].toByte() }
        return String(bytes, Charsets.UTF_8).trim('\u0000')
    }

    /**
     * A response provider keyed by the (block, function) of the GET frame. Lets
     * `parseAllState` be tested with a stub map and run live by closing over the
     * transport channel.
     */
    fun interface ResponseProvider {
        fun response(block: Int, function: Int): IntArray?
    }

    /**
     * Assemble a `HeadphoneState` from per-command responses. Pure given `provide`.
     * `provide(block, function)` returns the RESPONSE bytes for that GET (or null).
     */
    fun parseAllState(provide: ResponseProvider): HeadphoneState {
        val s = HeadphoneState()

        fun resp(b: Int, f: Int): IntArray? {
            // Require the frame to be the RESPONSE to THIS command: BMAP echoes the
            // queried block/func at r[0],r[1]. Without this, a leftover/late frame from a
            // prior command in the bulk session gets misread as the current field.
            // Matching block/func keeps every field bound to its own response.
            val r = provide.response(b, f) ?: return null
            return if (r.size >= 5 && r[0] == b && r[1] == f && r[2] == OP_RESP) r else null
        }

        resp(0x02, 0x02)?.let {
            s.batteryLevel = it[4].coerceIn(0, 100)
            s.batteryCharging = it.size >= 8 && it[7] != 0
        }
        resp(0x1F, 0x03)?.let { s.ancMode = it[4] }
        resp(0x05, 0x05)?.let { if (it.size >= 6) { s.volumeMax = it[4]; s.volume = it[5] } }

        provide.response(0x05, 0x01)?.let { s.connectedDevices = parseConnectedDevices(it) }

        resp(0x00, 0x05)?.let { s.firmware = parseString(it) }
        resp(0x00, 0x07)?.let { s.serialNumber = parseString(it) }
        resp(0x00, 0x0F)?.let { s.productName = parseString(it) }
        resp(0x12, 0x0D)?.let { s.platform = parseString(it) }
        resp(0x12, 0x0C)?.let { s.codename = parseString(it) }
        resp(0x01, 0x02)?.let { if (it.size >= 6) s.deviceName = parseString(it, from = 5) }

        resp(0x05, 0x04)?.let {
            val str = parseString(it)
            s.audioCodec = if (str.isNotEmpty()) str
            else it.copyOfRange(4, it.size).joinToString(" ") { b -> "%02X".format(b) }
        }

        resp(0x01, 0x0A)?.let { s.multipointEnabled = parseMultipointEnabled(it[4]) }
        resp(0x01, 0x18)?.let { if (it.size >= 5) s.autoPlayPause = (it[4] and 0x01) != 0 }
        resp(0x01, 0x1B)?.let { if (it.size >= 5) s.autoAnswer = (it[4] and 0x01) != 0 }
        provide.response(0x1F, 0x08)?.let { r -> parseFavorites(r)?.let { s.favorites = it } }
        resp(0x01, 0x0B)?.let { s.autoOffTimer = it.copyOfRange(4, it.size) }
        // No on-head/wear: StatusInEar (02,09) is an EARBUDS function; the QC Ultra 2
        // headphones answer FuncNotSupp. Live worn state isn't exposed over BMAP.

        provide.response(0x01, 0x07)?.let { r ->
            if (r.size >= 16 && r[2] == OP_RESP) {
                s.eqBass = r[6].toByte().toInt()
                s.eqMid = r[10].toByte().toInt()
                s.eqTreble = r[14].toByte().toInt()
            }
        }
        return s
    }
}
