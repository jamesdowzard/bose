package au.com.jd.bose

/**
 * Thin BMAP command facade.
 *
 * The wire layer is now GENERATED: every non-composite frame is built by
 * `BMAP.*` (from protocol/spec/bmap.toml) and sent over `Transport` (RFCOMM). This
 * object holds NO frame-byte builders — it only constructs the generated frame,
 * issues it, and decodes the response into the small UI-facing types below. The
 * device map / headphone MAC come from `Devices.generated.kt` (no literals here).
 *
 * Composite commands (connect-device poll-confirm, CNC read-modify-write,
 * connected-devices list parse, bulk getAllState) live in `Composites.kt`.
 * RFCOMM lifecycle + send/recv live in `Transport.kt`.
 */
object BoseProtocol {

    private const val OP_RESP = 0x03
    private const val OP_ACK = 0x07

    // ── Transport delegation (kept for call-site compatibility) ─────────────────

    val isConnected: Boolean get() = Transport.isConnected
    fun connect(): Boolean = Transport.connect()
    fun disconnect() = Transport.disconnect()
    suspend fun <T> withConnection(block: suspend () -> T): T = Transport.withConnection(block)

    /** True if the response is a well-formed ACK or RESP (set-command success). */
    private fun IntArray?.isAccepted(): Boolean =
        this != null && size >= 4 && (this[2] == OP_ACK || this[2] == OP_RESP)

    // ── Battery ─────────────────────────────────────────────────────────────────

    data class BatteryInfo(val level: Int, val charging: Boolean)

    fun getBattery(): BatteryInfo? {
        val resp = Transport.send(BMAP.getBattery()) ?: return null
        if (resp.size >= 5 && resp[2] == OP_RESP) {
            val level = resp[4].coerceIn(0, 100)
            val charging = resp.size >= 8 && resp[7] != 0
            return BatteryInfo(level, charging)
        }
        return null
    }

    // ── ANC ──────────────────────────────────────────────────────────────────────

    /** UI-facing ANC mode (label-carrying). Wire values match generated `AncMode`. */
    enum class AncMode(val value: Int, val label: String) {
        QUIET(0, "Quiet"),
        AWARE(1, "Aware"),
        CUSTOM1(2, "Custom 1"),
        CUSTOM2(3, "Custom 2");

        companion object {
            fun fromInt(v: Int): AncMode = entries.find { it.value == v } ?: QUIET
        }
    }

    fun getAncMode(): AncMode? {
        val resp = Transport.send(BMAP.getAncMode()) ?: return null
        if (resp.size >= 5 && resp[2] == OP_RESP) return AncMode.fromInt(resp[4])
        return null
    }

    fun setAncMode(mode: AncMode): Boolean =
        Transport.send(BMAP.setAncMode(mode.value)).isAccepted()

    // ── Volume ─────────────────────────────────────────────────────────────────

    data class VolumeInfo(val max: Int, val current: Int)

    fun getVolume(): VolumeInfo? {
        val resp = Transport.send(BMAP.getVolume()) ?: return null
        if (resp.size >= 6 && resp[2] == OP_RESP) return VolumeInfo(resp[4], resp[5])
        return null
    }

    fun setVolume(level: Int): Boolean =
        Transport.send(BMAP.setVolume(level.coerceIn(0, 31))).isAccepted()

    // ── Media controls ───────────────────────────────────────────────────────────

    enum class MediaAction(val value: Int) { PLAY(1), PAUSE(2), NEXT(3), PREV(4) }

    fun mediaControl(action: MediaAction): Boolean =
        Transport.send(BMAP.mediaControl(action.value)).isAccepted()

    // ── Multipoint ───────────────────────────────────────────────────────────────

    fun getMultipoint(): Boolean? {
        val resp = Transport.send(BMAP.getMultipoint()) ?: return null
        // Wire values are 07=on / 00=off. Use `!= 0` to match Parsers.parseAllState
        // and macOS Parsers.swift (both treat any non-zero byte as enabled).
        if (resp.size >= 5 && resp[2] == OP_RESP) return resp[4] != 0x00
        return null
    }

    fun setMultipoint(enabled: Boolean): Boolean =
        Transport.send(BMAP.setMultipoint(if (enabled) 0x07 else 0x00)).isAccepted()

    // ── EQ (SET_GET; band: 0=bass 1=mid 2=treble, value -10..+10) ─────────────────

    data class EqBand(val id: Int, val value: Int)
    data class EqSettings(val bass: EqBand, val mid: EqBand, val treble: EqBand)

    fun setEqBand(band: Int, value: Int): Boolean {
        if (band !in 0..2 || value !in -10..10) return false
        val resp = Transport.send(BMAP.setEqBand(value, band)) ?: return false
        return resp.size >= 4 && resp[2] == OP_RESP
    }

    fun setEq(bass: Int, mid: Int, treble: Int): Boolean {
        if (bass !in -10..10 || mid !in -10..10 || treble !in -10..10) return false
        for ((band, value) in listOf(0 to bass, 1 to mid, 2 to treble)) {
            val resp = Transport.send(BMAP.setEqBand(value, band)) ?: return false
            if (resp.size < 4 || resp[2] != OP_RESP) return false
        }
        return true
    }

    /** GET EQ. Value bytes at absolute indices 6/10/14 (signed), per the hardware capture. */
    fun getEq(): EqSettings? {
        val resp = Transport.send(BMAP.getEqBand()) ?: return null
        if (resp.size < 16 || resp[2] != OP_RESP) return null
        fun band(valueIdx: Int) = EqBand(resp[valueIdx - 1], resp[valueIdx].toByte().toInt())
        return EqSettings(band(6), band(10), band(14))
    }

    // ── Audio codec ──────────────────────────────────────────────────────────────

    data class AudioCodec(val codecId: Int, val bitrate: Int)

    fun getAudioCodec(): AudioCodec? {
        val resp = Transport.send(BMAP.getAudioCodec()) ?: return null
        if (resp.size < 6 || resp[2] != OP_RESP) return null
        val codecId = resp[4]
        val bitrate = if (resp.size >= 7) (resp[5] shl 8) or resp[6] else 0
        return AudioCodec(codecId, bitrate)
    }

    fun codecName(id: Int): String = when (id) {
        1 -> "SBC"
        2 -> "AAC"
        3 -> "aptX"
        4 -> "aptX HD"
        5 -> "aptX Adaptive"
        6 -> "LDAC"
        0 -> "Unknown"
        else -> "Codec $id"
    }

    // ── Device (Bluetooth) name ──────────────────────────────────────────────────

    fun getDeviceName(): String? {
        val resp = Transport.send(intArrayOf(0x01, 0x02, 0x01, 0x00)) ?: return null
        if (resp.size < 6 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3]
        if (payloadLen < 2) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        if (5 >= end) return null
        return Parsers.parseString(resp.copyOfRange(0, end), from = 5)
    }

    /**
     * SET device name. `01,02,06,{len},00,{utf8}` (max 30 UTF-8 bytes). The generated
     * builder only emits the [block, function, op] header — the variable-length,
     * length-prefixed UTF-8 body can't be expressed in the codegen payload DSL, so the
     * platform layer assembles it here over the generated block/function/operator.
     */
    fun setDeviceName(name: String): Boolean {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        if (nameBytes.size > 30) return false
        val header = BMAP.setDeviceName()            // [0x01, 0x02, 0x06, 0x00]
        val payloadLen = nameBytes.size + 1          // +1 for the leading 0x00
        val frame = intArrayOf(header[0], header[1], header[2], payloadLen, 0x00) +
            IntArray(nameBytes.size) { nameBytes[it].toInt() and 0xFF }
        return Transport.send(frame).isAccepted()
    }

    // ── String field queries (firmware / serial / product / platform / codename) ──
    //
    // Firmware IS in bmap.toml (a documented command) so it uses the generated builder.
    // Serial/product/platform/codename are read-only DIAGNOSTICS that never appeared in
    // the CLAUDE.md command tables, so they're not in the spec — their bare GET headers
    // `[block, func, GET, 0x00]` are issued literally here, exactly as macOS does in
    // Parsers.swift's parseAllState (e.g. the `(0x12, 0x0D)` provider key). Same split:
    // generated builders for the documented command set, literal GETs for off-spec reads.

    private fun getStringField(frame: IntArray): String? {
        val resp = Transport.send(frame) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3]
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return Parsers.parseString(resp.copyOfRange(0, end))
    }

    fun getFirmwareVersion() = getStringField(BMAP.getFirmware())
    fun getSerialNumber() = getStringField(intArrayOf(0x00, 0x07, 0x01, 0x00))
    fun getProductName() = getStringField(intArrayOf(0x00, 0x0F, 0x01, 0x00))
    fun getPlatform() = getStringField(intArrayOf(0x12, 0x0D, 0x01, 0x00))
    fun getCodename() = getStringField(intArrayOf(0x12, 0x0C, 0x01, 0x00))

    // ── Auto-off timer / wear / immersion (read-only diagnostics) ─────────────────

    fun getAutoOffTimer(): IntArray? {
        val resp = Transport.send(intArrayOf(0x01, 0x0B, 0x01, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val end = (4 + resp[3]).coerceAtMost(resp.size)
        return resp.copyOfRange(4, end)
    }

    fun autoOffTimerDescription(data: IntArray): String {
        if (data.isEmpty()) return "Unknown"
        return when (val value = data[0]) {
            0 -> "Never"
            20 -> "20 min"
            60 -> "60 min"
            180 -> "180 min"
            else -> "$value min"
        }
    }

    fun getImmersionLevel(): IntArray? {
        val resp = Transport.send(intArrayOf(0x01, 0x09, 0x01, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val end = (4 + resp[3]).coerceAtMost(resp.size)
        return resp.copyOfRange(4, end)
    }

    fun getWearState(): Boolean? {
        val resp = Transport.send(intArrayOf(0x08, 0x07, 0x01, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        return resp[4] == 0x04
    }

    // ── Device info (per-device ACL state) ───────────────────────────────────────

    data class DeviceInfo(val status: Int, val name: String, val connected: Boolean)

    /** GET device info (04,05). Status byte unreliable — cross-ref getConnectedDevices.
     *  Request frame from the generated builder (device_info in bmap.toml). */
    fun getDeviceInfo(mac: IntArray): DeviceInfo? {
        val resp = Transport.send(BMAP.getDeviceInfo(mac), timeoutMs = 2000) ?: return null
        if (resp.size < 11 || resp[2] != OP_RESP) return null
        val status = resp[10]
        val connected = (status and 0x01) != 0
        val name = if (resp.size > 13) Parsers.parseString(resp, from = 13) else ""
        return DeviceInfo(status, name, connected)
    }
}
