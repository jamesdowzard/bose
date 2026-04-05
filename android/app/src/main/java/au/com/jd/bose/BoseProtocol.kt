package au.com.jd.bose

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Bose QC Ultra RFCOMM protocol handler.
 *
 * Protocol format: [block, function, operator, length, ...payload]
 * Operators: 0x01=GET, 0x03=RESP, 0x04=ERR, 0x05=START, 0x06=SET, 0x07=ACK
 *
 * On-demand connection pattern: each command opens RFCOMM, sends, reads, closes.
 * Commands take ~200-300ms. Drain 300ms of initial data after connect (firmware quirk).
 * Single attempt per command -- no retry loops.
 */
object BoseProtocol {

    private const val TAG = "BoseProtocol"

    const val BOSE_MAC = "E4:58:BC:C0:2F:72"

    // SPP UUID for BMAP over RFCOMM
    val BOSE_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")

    // Operator constants
    const val OP_GET: Byte = 0x01
    const val OP_RESP: Byte = 0x03
    const val OP_ERR: Byte = 0x04
    const val OP_START: Byte = 0x05
    const val OP_SET: Byte = 0x06
    const val OP_ACK: Byte = 0x07

    // Known devices: name -> MAC bytes
    val DEVICES: LinkedHashMap<String, ByteArray> = linkedMapOf(
        "phone" to byteArrayOf(0xA8.toByte(), 0x76, 0x50, 0xD3.toByte(), 0xB1.toByte(), 0x1B),
        "mac" to byteArrayOf(0xBC.toByte(), 0xD0.toByte(), 0x74, 0x11, 0xDB.toByte(), 0x27),
        "ipad" to byteArrayOf(0xF4.toByte(), 0x81.toByte(), 0xC4.toByte(), 0xB5.toByte(), 0xFA.toByte(), 0xAB.toByte()),
        "iphone" to byteArrayOf(0xF8.toByte(), 0x4D, 0x89.toByte(), 0xC4.toByte(), 0xB6.toByte(), 0xED.toByte()),
        "tv" to byteArrayOf(0x14, 0xC1.toByte(), 0x4E, 0xB7.toByte(), 0xCB.toByte(), 0x68),
        "quest" to byteArrayOf(0x78, 0xC4.toByte(), 0xFA.toByte(), 0xC8.toByte(), 0x5C, 0x3D),
    )

    // Device MAC strings for display
    val DEVICE_MACS: Map<String, String> = mapOf(
        "phone" to "A8:76:50:D3:B1:1B",
        "mac" to "BC:D0:74:11:DB:27",
        "ipad" to "F4:81:C4:B5:FA:AB",
        "iphone" to "F8:4D:89:C4:B6:ED",
        "tv" to "14:C1:4E:B7:CB:68",
        "quest" to "78:C4:FA:C8:5C:3D",
    )

    val CYCLE_ORDER = listOf("mac", "quest", "ipad", "iphone", "tv", "phone")

    private val rfcommLock = ReentrantLock()
    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    val isConnected: Boolean
        get() = socket?.isConnected == true

    // ======================================================================
    // Connection management
    // ======================================================================

    /**
     * Connect to headphones via RFCOMM.
     * Drains 300ms of initial data after connect (Bose firmware quirk).
     */
    @SuppressLint("MissingPermission")
    fun connect(): Boolean {
        rfcommLock.lock()
        closeSocket()

        val adapter = BluetoothAdapter.getDefaultAdapter() ?: run {
            Log.e(TAG, "No Bluetooth adapter")
            rfcommLock.unlock()
            return false
        }

        val device: BluetoothDevice = adapter.getRemoteDevice(BOSE_MAC)

        try {
            Log.d(TAG, "Connecting via SPP UUID: $BOSE_UUID")
            val sock = device.createRfcommSocketToServiceRecord(BOSE_UUID)
            sock.connect()
            socket = sock
            inputStream = sock.inputStream
            outputStream = sock.outputStream
            Log.i(TAG, "RFCOMM connected")

            // Drain initial data (Bose firmware quirk -- sends unsolicited data on connect)
            drainInitialData()

            return true
        } catch (e: IOException) {
            Log.e(TAG, "RFCOMM connect failed: ${e.message}")
            disconnect()
            return false
        }
    }

    /** Close socket and release the RFCOMM lock. */
    fun disconnect() {
        closeSocket()
        if (rfcommLock.isHeldByCurrentThread) rfcommLock.unlock()
    }

    /** Close socket without releasing the lock (used internally by connect). */
    private fun closeSocket() {
        try { inputStream?.close() } catch (_: Exception) {}
        try { outputStream?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        inputStream = null
        outputStream = null
    }

    /**
     * Drain 300ms of initial data after RFCOMM connect.
     * Bose firmware sends unsolicited status data on connection.
     */
    private fun drainInitialData() {
        val ins = inputStream ?: return
        val buf = ByteArray(1024)
        val deadline = System.currentTimeMillis() + 300
        try {
            while (System.currentTimeMillis() < deadline) {
                if (ins.available() > 0) {
                    val n = ins.read(buf)
                    Log.d(TAG, "Drained $n bytes of initial data")
                } else {
                    Thread.sleep(20)
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "Drain error (non-fatal): ${e.message}")
        }
    }

    /**
     * On-demand connection pattern: connect, execute block, disconnect.
     * Each command gets a fresh RFCOMM socket.
     * connect() acquires rfcommLock, disconnect() releases it.
     */
    suspend fun <T> withConnection(block: suspend () -> T): T = withContext(Dispatchers.IO) {
        connect()
        try {
            block()
        } finally {
            disconnect()
        }
    }

    // ======================================================================
    // Low-level send/receive
    // ======================================================================

    /**
     * Send a protocol message and wait for a response.
     * Single attempt -- no retry loops.
     */
    fun send(bytes: ByteArray, timeoutMs: Long = 3000): ByteArray? {
        val os = outputStream ?: return null
        val ins = inputStream ?: return null

        return try {
            Log.d(TAG, "TX: ${bytes.toHexString()}")
            os.write(bytes)
            os.flush()

            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(512)

            while (System.currentTimeMillis() < deadline) {
                if (ins.available() > 0) {
                    // Small delay to let the full response arrive
                    Thread.sleep(100)
                    val n = ins.read(buf)
                    if (n > 0) {
                        val resp = buf.copyOf(n)
                        Log.d(TAG, "RX: ${resp.toHexString()}")
                        return resp
                    }
                }
                Thread.sleep(50)
            }
            Log.w(TAG, "Timeout waiting for response")
            null
        } catch (e: IOException) {
            Log.e(TAG, "Send/receive error: ${e.message}")
            null
        }
    }

    // ======================================================================
    // Battery
    // ======================================================================

    data class BatteryInfo(val level: Int, val charging: Boolean)

    /** Battery level (0-100) and charging flag. GET 02,02,01,00 */
    fun getBattery(): BatteryInfo? {
        val resp = send(byteArrayOf(0x02, 0x02, OP_GET, 0x00)) ?: return null
        if (resp.size >= 5 && resp[2] == OP_RESP) {
            val level = (resp[4].toInt() and 0xFF).coerceIn(0, 100)
            val charging = resp.size >= 8 && (resp[7].toInt() and 0xFF) != 0
            return BatteryInfo(level, charging)
        }
        return null
    }

    // ======================================================================
    // ANC (Active Noise Cancellation)
    // ======================================================================

    enum class AncMode(val value: Int, val label: String) {
        QUIET(0, "Quiet"),
        AWARE(1, "Aware"),
        CUSTOM1(2, "Custom 1"),
        CUSTOM2(3, "Custom 2");

        companion object {
            fun fromByte(b: Byte): AncMode =
                entries.find { it.value == (b.toInt() and 0xFF) } ?: QUIET
        }
    }

    /** GET ANC mode. 1f,03,01,00 -> byte4 = mode */
    fun getAncMode(): AncMode? {
        val resp = send(byteArrayOf(0x1F, 0x03, OP_GET, 0x00)) ?: return null
        if (resp.size >= 5 && resp[2] == OP_RESP) {
            return AncMode.fromByte(resp[4])
        }
        return null
    }

    /** SET ANC mode. 1f,03,05,02,{mode},01 */
    fun setAncMode(mode: AncMode): Boolean {
        val cmd = byteArrayOf(0x1F, 0x03, OP_START, 0x02, mode.value.toByte(), 0x01)
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Volume
    // ======================================================================

    data class VolumeInfo(val max: Int, val current: Int)

    /** GET volume. 05,05,01,00 -> max,current */
    fun getVolume(): VolumeInfo? {
        val resp = send(byteArrayOf(0x05, 0x05, OP_GET, 0x00)) ?: return null
        if (resp.size >= 6 && resp[2] == OP_RESP) {
            val max = resp[4].toInt() and 0xFF
            val current = resp[5].toInt() and 0xFF
            return VolumeInfo(max, current)
        }
        return null
    }

    /** SET volume (0-31). 05,05,02,01,{level} */
    fun setVolume(level: Int): Boolean {
        val clamped = level.coerceIn(0, 31)
        val cmd = byteArrayOf(0x05, 0x05, 0x02, 0x01, clamped.toByte())
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Media controls
    // ======================================================================

    enum class MediaAction(val value: Int) {
        PLAY(1), PAUSE(2), NEXT(3), PREV(4)
    }

    /** Media control. 05,03,05,01,{action} */
    fun mediaControl(action: MediaAction): Boolean {
        val cmd = byteArrayOf(0x05, 0x03, OP_START, 0x01, action.value.toByte())
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Connected devices (ground truth for connection state)
    // ======================================================================

    /** GET connected devices. 05,01,01,00 -> count at byte 6, MACs from byte 7 */
    fun getConnectedDevices(): List<ByteArray> {
        val resp = send(byteArrayOf(0x05, 0x01, OP_GET, 0x00)) ?: return emptyList()
        if (resp.size < 7 || resp[0] != 0x05.toByte() || resp[1] != 0x01.toByte()
            || resp[2] != OP_RESP) return emptyList()

        val count = resp[6].toInt() and 0xFF
        val devices = mutableListOf<ByteArray>()
        var i = 7
        for (j in 0 until count) {
            if (i + 6 > resp.size) break
            devices.add(resp.copyOfRange(i, i + 6))
            i += 6
        }
        return devices
    }

    /** GET active device MAC. 04,09,01,00 -> MAC at bytes 4-9 */
    fun getActiveDevice(): ByteArray? {
        val resp = send(byteArrayOf(0x04, 0x09, OP_GET, 0x00)) ?: return null
        if (resp.size < 10 || resp[2] != OP_RESP) return null
        return resp.copyOfRange(4, 10)
    }

    // ======================================================================
    // Paired devices
    // ======================================================================

    /** GET paired devices. 04,04,01,00 -> count + MAC array */
    fun getPairedDevices(): List<ByteArray> {
        val resp = send(byteArrayOf(0x04, 0x04, OP_GET, 0x00)) ?: return emptyList()
        if (resp.size < 5 || resp[2] != OP_RESP) return emptyList()

        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return emptyList()

        val count = resp[4].toInt() and 0xFF
        val devices = mutableListOf<ByteArray>()
        var i = 5
        for (j in 0 until count) {
            if (i + 6 > resp.size) break
            devices.add(resp.copyOfRange(i, i + 6))
            i += 6
        }
        return devices
    }

    // ======================================================================
    // Device info
    // ======================================================================

    data class DeviceInfo(
        val status: Int,
        val name: String,
        val connected: Boolean,  // bit 0 of status
    )

    /** GET device info. 04,05,01,06,{MAC} -> MAC at 4-9, status at 10, name from 13 */
    fun getDeviceInfo(mac: ByteArray): DeviceInfo? {
        val cmd = byteArrayOf(0x04, 0x05, OP_GET, 0x06) + mac
        val resp = send(cmd, timeoutMs = 2000) ?: return null
        if (resp.size < 11 || resp[2] != OP_RESP) return null

        val status = resp[10].toInt() and 0xFF
        val connected = (status and 0x01) != 0
        val nameOffset = 13
        val name = if (resp.size > nameOffset) {
            String(resp, nameOffset, resp.size - nameOffset, Charsets.UTF_8)
                .trim('\u0000')
        } else ""

        return DeviceInfo(status, name, connected)
    }

    // ======================================================================
    // Connect / Disconnect device
    // ======================================================================

    /**
     * Connect (switch audio to) a device by MAC.
     * Command: 04,01,05,07,00,{MAC} (START operator)
     * NEVER use 0x03 (RemoveDevice) -- it unpairs.
     */
    fun connectDevice(mac: ByteArray): Boolean {
        val cmd = byteArrayOf(0x04, 0x01, OP_START, 0x07, 0x00) + mac
        val resp = send(cmd, timeoutMs = 10000) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    /**
     * Disconnect a device by MAC.
     * Command: 04,02,05,06,{MAC} (START operator)
     */
    fun disconnectDevice(mac: ByteArray): Boolean {
        val cmd = byteArrayOf(0x04, 0x02, OP_START, 0x06) + mac
        val resp = send(cmd, timeoutMs = 5000) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Firmware version
    // ======================================================================

    /** GET firmware version. 00,05,01,00 -> version string */
    fun getFirmwareVersion(): String? {
        val resp = send(byteArrayOf(0x00, 0x05, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return String(resp, 4, end - 4, Charsets.UTF_8).trim('\u0000')
    }

    // ======================================================================
    // Serial number
    // ======================================================================

    /** GET serial number. 00,07,01,00 -> serial string */
    fun getSerialNumber(): String? {
        val resp = send(byteArrayOf(0x00, 0x07, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return String(resp, 4, end - 4, Charsets.UTF_8).trim('\u0000')
    }

    // ======================================================================
    // Product name
    // ======================================================================

    /** GET product name. 00,0f,01,00 -> name string */
    fun getProductName(): String? {
        val resp = send(byteArrayOf(0x00, 0x0F, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return String(resp, 4, end - 4, Charsets.UTF_8).trim('\u0000')
    }

    // ======================================================================
    // Platform
    // ======================================================================

    /** GET platform string. 12,0d,01,00 -> e.g. "OTG-QCC-384" */
    fun getPlatform(): String? {
        val resp = send(byteArrayOf(0x12, 0x0D, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return String(resp, 4, end - 4, Charsets.UTF_8).trim('\u0000')
    }

    // ======================================================================
    // Codename
    // ======================================================================

    /** GET codename. 12,0c,01,00 -> e.g. "wolverine" */
    fun getCodename(): String? {
        val resp = send(byteArrayOf(0x12, 0x0C, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 1) return null
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return String(resp, 4, end - 4, Charsets.UTF_8).trim('\u0000')
    }

    // ======================================================================
    // Audio codec
    // ======================================================================

    data class AudioCodec(val codecId: Int, val bitrate: Int)

    /** GET audio codec. 05,04,01,00 -> codec ID + bitrate */
    fun getAudioCodec(): AudioCodec? {
        val resp = send(byteArrayOf(0x05, 0x04, OP_GET, 0x00)) ?: return null
        if (resp.size < 6 || resp[2] != OP_RESP) return null
        val codecId = resp[4].toInt() and 0xFF
        val bitrate = if (resp.size >= 7) {
            ((resp[5].toInt() and 0xFF) shl 8) or (resp[6].toInt() and 0xFF)
        } else 0
        return AudioCodec(codecId, bitrate)
    }

    fun codecName(id: Int): String = when (id) {
        0 -> "Unknown"
        1 -> "SBC"
        2 -> "AAC"
        3 -> "aptX"
        4 -> "aptX HD"
        5 -> "aptX Adaptive"
        6 -> "LDAC"
        else -> "Codec $id"
    }

    // ======================================================================
    // Device name (Bluetooth name)
    // ======================================================================

    /** GET device name. 01,02,01,00 -> 0x00 + UTF-8 name */
    fun getDeviceName(): String? {
        val resp = send(byteArrayOf(0x01, 0x02, OP_GET, 0x00)) ?: return null
        if (resp.size < 6 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 2) return null
        // Skip the leading 0x00 byte
        val start = 5
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        if (start >= end) return null
        return String(resp, start, end - start, Charsets.UTF_8).trim('\u0000')
    }

    /** SET device name. 01,02,06,len,00,name_bytes */
    fun setDeviceName(name: String): Boolean {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val payloadLen = nameBytes.size + 1 // +1 for leading 0x00
        val cmd = byteArrayOf(0x01, 0x02, OP_SET, payloadLen.toByte(), 0x00) + nameBytes
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Multipoint
    // ======================================================================

    /** GET multipoint. 01,0a,01,00 -> 0x07=on, 0x00=off */
    fun getMultipoint(): Boolean? {
        val resp = send(byteArrayOf(0x01, 0x0A, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        return (resp[4].toInt() and 0xFF) == 0x07
    }

    /** SET multipoint. 01,0a,02,01,{07/00} */
    fun setMultipoint(enabled: Boolean): Boolean {
        val value: Byte = if (enabled) 0x07 else 0x00
        val cmd = byteArrayOf(0x01, 0x0A, 0x02, 0x01, value)
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && (resp[2] == OP_ACK || resp[2] == OP_RESP)
    }

    // ======================================================================
    // Auto-off timer
    // ======================================================================

    /** GET auto-off timer. 01,0b,01,00 -> timer bytes */
    fun getAutoOffTimer(): ByteArray? {
        val resp = send(byteArrayOf(0x01, 0x0B, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return resp.copyOfRange(4, end)
    }

    fun autoOffTimerDescription(data: ByteArray): String {
        if (data.isEmpty()) return "Unknown"
        val value = data[0].toInt() and 0xFF
        return when (value) {
            0 -> "Never"
            20 -> "20 min"
            60 -> "60 min"
            180 -> "180 min"
            else -> "$value min"
        }
    }

    // ======================================================================
    // Immersion level
    // ======================================================================

    // ======================================================================
    // CNC Level (AudioModes SettingsConfig 1F,0A)
    // ======================================================================

    /** GET CNC level (custom ANC depth). 1F,0A,01,00 -> 5-byte payload */
    fun getCncLevel(): Int? {
        val resp = send(byteArrayOf(0x1F, 0x0A, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        return resp[4].toInt() and 0xFF
    }

    /** SET CNC level. Reads current config, changes cncLevel, preserves other fields. */
    fun setCncLevel(level: Int): Boolean {
        if (level !in 0..10) return false
        // Read current to preserve other fields
        val current = send(byteArrayOf(0x1F, 0x0A, OP_GET, 0x00)) ?: return false
        if (current.size < 9 || current[2] != OP_RESP) return false
        val cmd = byteArrayOf(0x1F, 0x0A, OP_SET_GET, 0x05,
            level.toByte(), current[5], current[6], current[7], current[8])
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && resp[2] == OP_RESP
    }

    // ======================================================================
    // Immersion (Settings block)
    // ======================================================================

    /** GET immersion level. 01,09,01,00 -> 7 bytes */
    fun getImmersionLevel(): ByteArray? {
        val resp = send(byteArrayOf(0x01, 0x09, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        val payloadLen = resp[3].toInt() and 0xFF
        val end = (4 + payloadLen).coerceAtMost(resp.size)
        return resp.copyOfRange(4, end)
    }

    // ======================================================================
    // Wear state
    // ======================================================================

    /** GET wear state. 08,07,01,00 -> 0x04 = on head */
    fun getWearState(): Boolean? {
        val resp = send(byteArrayOf(0x08, 0x07, OP_GET, 0x00)) ?: return null
        if (resp.size < 5 || resp[2] != OP_RESP) return null
        return (resp[4].toInt() and 0xFF) == 0x04
    }

    // ======================================================================
    // EQ (SET uses SET_GET operator 0x02, not SET 0x06)
    // ======================================================================

    private const val OP_SET_GET: Byte = 0x02

    /** SET one EQ band. 01,07,02,02,{value},{band}. band: 0=bass 1=mid 2=treble. value: -10 to +10 */
    fun setEqBand(band: Int, value: Int): Boolean {
        if (band !in 0..2 || value !in -10..10) return false
        val cmd = byteArrayOf(0x01, 0x07, OP_SET_GET, 0x02, value.toByte(), band.toByte())
        val resp = send(cmd) ?: return false
        return resp.size >= 4 && resp[2] == OP_RESP
    }

    /** SET all three EQ bands. */
    fun setEq(bass: Int, mid: Int, treble: Int): Boolean {
        if (bass !in -10..10 || mid !in -10..10 || treble !in -10..10) return false
        for ((band, value) in listOf(0 to bass, 1 to mid, 2 to treble)) {
            val cmd = byteArrayOf(0x01, 0x07, OP_SET_GET, 0x02, value.toByte(), band.toByte())
            val resp = send(cmd) ?: return false
            if (resp.size < 4 || resp[2] != OP_RESP) return false
        }
        return true
    }

    data class EqBand(val id: Int, val value: Int)
    data class EqSettings(val bass: EqBand, val mid: EqBand, val treble: EqBand)

    /** GET EQ. 01,07,01,00 -> 12 bytes: 3x f6,0a,XX,YY (bass/mid/treble) */
    fun getEq(): EqSettings? {
        val resp = send(byteArrayOf(0x01, 0x07, OP_GET, 0x00)) ?: return null
        if (resp.size < 16 || resp[2] != OP_RESP) return null

        fun parseBand(offset: Int): EqBand? {
            if (offset + 3 >= resp.size) return null
            return EqBand(resp[offset + 2].toInt() and 0xFF, resp[offset + 3].toInt() and 0xFF)
        }

        val bass = parseBand(4) ?: return null
        val mid = parseBand(8) ?: return null
        val treble = parseBand(12) ?: return null
        return EqSettings(bass, mid, treble)
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    fun macToString(mac: ByteArray): String =
        mac.joinToString(":") { String.format("%02X", it) }

    fun nameForMac(mac: ByteArray): String {
        for ((name, addr) in DEVICES) {
            if (addr.contentEquals(mac)) return name
        }
        return macToString(mac)
    }

    fun nextDevice(currentName: String): String {
        val idx = CYCLE_ORDER.indexOf(currentName)
        return if (idx >= 0) {
            CYCLE_ORDER[(idx + 1) % CYCLE_ORDER.size]
        } else {
            CYCLE_ORDER[0]
        }
    }

    private fun ByteArray.toHexString(): String =
        joinToString(" ") { String.format("%02X", it) }
}
