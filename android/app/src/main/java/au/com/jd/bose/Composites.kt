package au.com.jd.bose

import android.util.Log

/**
 * Live-channel composite commands — the codegen escape hatch.
 *
 * These need read-modify-write, multi-frame list parsing, or poll-confirm loops, so
 * they can't be a single generated builder. They orchestrate over `Transport` (the
 * RFCOMM channel), construct frames via generated `BMAP` where a primitive exists,
 * and decode with the pure `Parsers`. Kept to ~3 (CNC RMW, connected-devices list,
 * bulk getAllState) plus connectDevice's poll-confirm — same split as macOS.
 */
object Composites {

    private const val TAG = "BoseComposites"

    enum class SwitchResult { SWITCHED, TARGET_OFFLINE, FAILED }

    // GET frames for the composite commands. These commands are `composite = true` in
    // bmap.toml (variable-length / RMW response shapes the codegen DSL can't express),
    // so the GET frame is the plain header here and the response is parsed by Parsers.
    private val GET_CONNECTED_DEVICES = intArrayOf(0x05, 0x01, 0x01, 0x00)
    private val GET_CNC_LEVEL = intArrayOf(0x1F, 0x0A, 0x01, 0x00)

    /** GET connected devices (05,01) — the audio-active ground truth. */
    fun getConnectedDevices(): List<IntArray> {
        val resp = Transport.send(GET_CONNECTED_DEVICES) ?: return emptyList()
        return Parsers.parseConnectedDevices(resp)
    }

    /** GET CNC level (custom ANC depth) — first byte of the SettingsConfig (1F,0A). */
    fun getCncLevel(): Int? {
        val resp = Transport.send(GET_CNC_LEVEL) ?: return null
        return Parsers.parseCncLevel(resp)?.level
    }

    /**
     * SET CNC level (read-modify-write). Reads the current SettingsConfig, changes only
     * `level`, preserves autoCNC/spatial/windBlock/ancToggle, writes it back via SET_GET.
     */
    fun setCncLevel(level: Int): Boolean {
        if (level !in 0..10) return false
        val current = Transport.send(GET_CNC_LEVEL) ?: return false
        val cfg = Parsers.parseCncLevel(current) ?: return false
        val resp = Transport.send(Parsers.buildCncSet(level, cfg)) ?: return false
        return resp.size >= 4 && resp[2] == 0x03 // RESP
    }

    /**
     * Connect (switch audio to) a device by MAC. Sends connectDevice (04,01) for the
     * ACK, then polls getConnectedDevices on the SAME channel until the target MAC is
     * audio-active (up to ~16s). NEVER treats ACK as success (CLAUDE.md / #61-#64) — a
     * paged sleeping device has no reliable RESULT frame.
     */
    fun connectDevice(mac: IntArray): SwitchResult {
        val ack = Transport.send(BMAP.connectDevice(mac), timeoutMs = 5000)
            ?: return SwitchResult.FAILED
        if (ack.size < 4 || ack[2] != 0x07) return SwitchResult.FAILED // OP_ACK
        Log.i(TAG, "connectDevice: ACK received, polling for audio route...")

        val target = mac.toList()
        for (attempt in 1..8) {
            Thread.sleep(2000)
            val active = getConnectedDevices()
            if (active.any { it.toList() == target }) {
                Log.i(TAG, "connectDevice: verified on attempt $attempt — target audio-active")
                return SwitchResult.SWITCHED
            }
            Log.d(TAG, "connectDevice: attempt $attempt — target not yet active")
        }
        Log.w(TAG, "connectDevice: target not audio-active after 16s")
        return SwitchResult.TARGET_OFFLINE
    }

    /**
     * Bulk-read the full headphone state in a single RFCOMM session. Issues every GET
     * over the open channel and assembles a `HeadphoneState` via the pure parser.
     * Caller is responsible for being inside a `Transport.withConnection { }`.
     */
    fun getAllState(): Parsers.HeadphoneState =
        Parsers.parseAllState { block, function -> getResponse(block, function) }

    /** GET frame for an arbitrary (block, function) and return the raw response. */
    private fun getResponse(block: Int, function: Int): IntArray? =
        Transport.send(intArrayOf(block, function, 0x01, 0x00))
}
