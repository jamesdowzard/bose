package au.com.jd.bose

import android.util.Log

/**
 * Live-channel composite commands — the codegen escape hatch.
 *
 * These need read-modify-write, multi-frame list parsing, or poll-confirm loops, so
 * they can't be a single generated builder. They orchestrate over `Transport` (the
 * RFCOMM channel), construct frames via generated `BMAP` where a primitive exists,
 * and decode with the pure `Parsers`. Kept to ~3 (noise-level 1F,06 RMW,
 * connected-devices list, bulk getAllState) plus connectDevice's poll-confirm — same
 * split as macOS.
 */
object Composites {

    private const val TAG = "BoseComposites"

    enum class SwitchResult { SWITCHED, TARGET_OFFLINE, FAILED }

    // GET frames for the composite commands. These commands are `composite = true` in
    // bmap.toml (variable-length / RMW response shapes the codegen DSL can't express),
    // so the GET frame is the plain header here and the response is parsed by Parsers.
    private val GET_CONNECTED_DEVICES = intArrayOf(0x05, 0x01, 0x01, 0x00)

    /** GET connected devices (05,01) — the audio-active ground truth. */
    fun getConnectedDevices(): List<IntArray> {
        val resp = Transport.send(GET_CONNECTED_DEVICES) ?: return emptyList()
        return Parsers.parseConnectedDevices(resp)
    }

    /** Outcome of a noise-level write — mirrors macOS `AncLevelResult`. */
    sealed class AncLevelResult {
        data class Ok(val name: String, val level: Int) : AncLevelResult()
        data class Fixed(val name: String) : AncLevelResult()
        object Unreachable : AncLevelResult()
    }

    /**
     * Read the ACTIVE mode's full AudioModesModeConfig (1F,06). Resolves the current mode
     * index (1F,03) first, after priming with a 02,02 read — the 1F,06 GET only answers
     * inside a warm session. Caller must be inside `Transport.withConnection { }`. null if
     * unreachable.
     */
    fun readActiveModeConfig(): Parsers.ModeConfig? {
        Transport.send(intArrayOf(0x02, 0x02, 0x01, 0x00)) // prime warm session
        val cur = Transport.send(intArrayOf(0x1F, 0x03, 0x01, 0x00)) ?: return null
        if (cur.size < 5) return null
        val resp = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, cur[4])) ?: return null
        return Parsers.parseModeConfig(resp)
    }

    /**
     * Set the ACTIVE mode's CNC noise level (0 = max cancellation … 10 = transparency) via
     * the 1F,06 read-modify-write — the correct, ANC-anchored path (#83). Refuses on a mode
     * whose level is fixed (`cncMutable == false`: Quiet/Aware/spatial), so a level write
     * can never disable ANC. Caller must be inside `Transport.withConnection { }`.
     */
    fun setActiveModeLevel(level: Int): AncLevelResult {
        Transport.send(intArrayOf(0x02, 0x02, 0x01, 0x00)) // prime warm session
        val cur = Transport.send(intArrayOf(0x1F, 0x03, 0x01, 0x00)) ?: return AncLevelResult.Unreachable
        if (cur.size < 5) return AncLevelResult.Unreachable
        val r1 = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, cur[4])) ?: return AncLevelResult.Unreachable
        val cfg = Parsers.parseModeConfig(r1) ?: return AncLevelResult.Unreachable
        if (!cfg.cncMutable) return AncLevelResult.Fixed(cfg.displayName)
        Transport.send(Parsers.buildModeConfigSet(cfg, level))
        val after = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, cur[4]))?.let { Parsers.parseModeConfig(it) }
        return AncLevelResult.Ok(cfg.displayName, after?.cncLevel ?: cfg.cncLevel)
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
