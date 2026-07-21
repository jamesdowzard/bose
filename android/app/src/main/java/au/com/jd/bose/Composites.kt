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

    /**
     * Which of the queried devices the headset currently HOLDS, split into audio-active
     * (05,01) and ACL-connected-but-idle (04,05). Mirrors macOS `getDeviceStates`: prime a
     * warm session (05,01 is silent as the first cold frame, #81), read the active sink, then
     * probe 04,05 per non-active queried device for ACL presence. Caller must hold an open
     * connection (inside switchDevice's connect/disconnect bracket). Returns (active, connected).
     */
    fun getDeviceStates(query: List<IntArray>): Pair<List<IntArray>, List<IntArray>> {
        Transport.send(intArrayOf(0x02, 0x02, 0x01, 0x00)) // prime warm session (05,01 silent cold)
        val active = getConnectedDevices()
        val activeKeys = active.map { it.toList() }.toSet()
        val connected = mutableListOf<IntArray>()
        for (mac in query) {
            if (mac.toList() in activeKeys) continue
            if (BoseProtocol.getDeviceInfo(mac)?.connected == true) connected.add(mac)
        }
        return active to connected
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
     * Stored display names of the two custom slots (4, 5), for labelling the C1/C2 buttons
     * with their on-device names (set via the CLI `mode-name`). Mirrors macOS `readModeInfo`'s
     * custom-name leg. Caller must be inside `Transport.withConnection { }`. A slot that's
     * unset reads "None" (the caller maps that to the C1/C2 fallback); unreadable → omitted.
     */
    fun readCustomModeNames(): Map<Int, String> {
        Transport.send(intArrayOf(0x02, 0x02, 0x01, 0x00)) // prime warm session
        val names = mutableMapOf<Int, String>()
        for (idx in intArrayOf(4, 5)) {
            val r = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, idx)) ?: continue
            Parsers.parseModeConfig(r)?.let { names[idx] = it.displayName }
        }
        return names
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

    /** Outcome of an Immersive Audio (spatial) write — mirrors macOS `SpatialResult`. */
    sealed class SpatialResult {
        data class Ok(val name: String, val spatial: Int) : SpatialResult()
        data class Fixed(val name: String) : SpatialResult()
        object Unreachable : SpatialResult()
    }

    /**
     * Set the ACTIVE mode's Immersive Audio (spatial) mode (0 = off, 1 = Still, 2 = Motion)
     * via the same 1F,06 RMW as the noise level. The spatial byte is per-mode and only
     * editable where the firmware sets `spatialMutable` (response[41] bit2) — the custom
     * slots; named modes carry it fixed (Immersion = Motion, Cinema = Still). Refuses on a
     * fixed mode so the call is a clean no-op. The global AudioManagement function (05,0F) is
     * FuncNotSupp on this firmware — this per-mode RMW is the only working path. Caller must
     * be inside `Transport.withConnection { }`.
     */
    fun setActiveModeSpatial(spatial: Int): SpatialResult {
        Transport.send(intArrayOf(0x02, 0x02, 0x01, 0x00)) // prime warm session
        val cur = Transport.send(intArrayOf(0x1F, 0x03, 0x01, 0x00)) ?: return SpatialResult.Unreachable
        if (cur.size < 5) return SpatialResult.Unreachable
        val r1 = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, cur[4])) ?: return SpatialResult.Unreachable
        val cfg = Parsers.parseModeConfig(r1) ?: return SpatialResult.Unreachable
        if (!cfg.spatialMutable) return SpatialResult.Fixed(cfg.displayName)
        Transport.send(Parsers.buildModeConfigSet(cfg, newLevel = null, newSpatial = spatial))
        val after = Transport.send(intArrayOf(0x1F, 0x06, 0x01, 0x01, cur[4]))?.let { Parsers.parseModeConfig(it) }
        return SpatialResult.Ok(cfg.displayName, after?.spatial ?: cfg.spatial)
    }

    /**
     * Preflight a connect target against the headphones' OWN paired table (04,04) — the Android
     * parity of the CLI's `preflightPaired` (#157). The host-side device map drifts from the
     * headset's pairing list (tv/appletv are mapped but were never paired), and paging an
     * unpaired device ACKs then silently never connects — an indistinguishable ~20s timeout.
     *
     * Returns an abort hint ONLY when the device is provably absent from a readable paired list,
     * so the caller can fail fast BEFORE evicting a multipoint slot for a device that can't
     * answer. A no-op (null) when the list is unreadable or the device IS paired — it never
     * blocks a connect on an unreadable list. Caller must hold an open RFCOMM channel.
     */
    fun unpairedHint(mac: IntArray, deviceName: String): String? {
        val resp = Transport.send(BMAP.getListDevices()) ?: return null
        val paired = Parsers.parsePairedDevices(resp)
        if (paired.isEmpty() || paired.any { it.toList() == mac.toList() }) return null
        return "$deviceName is not in the headphones' paired list — it's in the device map, but " +
            "the headphones have never been paired with it (or have forgotten it). Pair it from " +
            "the device itself first; paging it can only time out."
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
