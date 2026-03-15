package dev.bose.ctl

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/**
 * Bose QC Ultra RFCOMM protocol handler.
 *
 * Protocol format: [block, function, operator, length, ...payload]
 * Operators: 0x01=GET, 0x03=RESP, 0x04=ERR, 0x05=START, 0x06=SET, 0x07=ACK
 */
object BoseProtocol {

    private const val TAG = "BoseProtocol"

    const val BOSE_MAC = "E4:58:BC:C0:2F:72"
    val BOSE_UUID: UUID = UUID.fromString("00000000-deca-fade-deca-deafdecacaff")

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
    )

    // Non-phone devices for cycling
    val CYCLE_ORDER = listOf("mac", "ipad", "iphone", "tv", "phone")

    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    val isConnected: Boolean
        get() = socket?.isConnected == true

    /**
     * Connect to the Bose headphones via RFCOMM.
     * Uses SDP UUID lookup first, falls back to reflection-based channel creation.
     */
    @SuppressLint("MissingPermission")
    fun connect(): Boolean {
        disconnect()

        val adapter = BluetoothAdapter.getDefaultAdapter() ?: run {
            Log.e(TAG, "No Bluetooth adapter")
            return false
        }

        val device: BluetoothDevice = adapter.getRemoteDevice(BOSE_MAC) ?: run {
            Log.e(TAG, "Device not found: $BOSE_MAC")
            return false
        }

        // Try SDP UUID first
        try {
            Log.d(TAG, "Trying SDP UUID: $BOSE_UUID")
            val sock = device.createRfcommSocketToServiceRecord(BOSE_UUID)
            sock.connect()
            socket = sock
            inputStream = sock.inputStream
            outputStream = sock.outputStream
            Log.i(TAG, "Connected via SDP UUID")

            // Verify with a probe
            val probe = send(byteArrayOf(0x00, 0x05, OP_GET, 0x00), timeoutMs = 2000)
            if (probe != null && probe.size >= 4 && probe[0] == 0x00.toByte() && probe[1] == 0x05.toByte()) {
                Log.i(TAG, "Protocol verified")
                return true
            }
            Log.w(TAG, "SDP connected but probe failed, trying RFCOMM channels")
            disconnect()
        } catch (e: IOException) {
            Log.w(TAG, "SDP UUID failed: ${e.message}")
            disconnect()
        }

        // Fallback: try specific RFCOMM channels
        val channels = intArrayOf(2, 14, 22, 25)
        for (ch in channels) {
            try {
                Log.d(TAG, "Trying RFCOMM channel $ch")
                val method = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                val sock = method.invoke(device, ch) as BluetoothSocket
                sock.connect()
                socket = sock
                inputStream = sock.inputStream
                outputStream = sock.outputStream

                // Verify
                val probe = send(byteArrayOf(0x00, 0x05, OP_GET, 0x00), timeoutMs = 2000)
                if (probe != null && probe.size >= 4 && probe[0] == 0x00.toByte() && probe[1] == 0x05.toByte()) {
                    Log.i(TAG, "Connected on RFCOMM channel $ch")
                    return true
                }
                Log.w(TAG, "Channel $ch connected but probe failed")
                disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "Channel $ch failed: ${e.message}")
                disconnect()
            }
        }

        Log.e(TAG, "All connection methods failed")
        return false
    }

    fun disconnect() {
        try { inputStream?.close() } catch (_: Exception) {}
        try { outputStream?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        inputStream = null
        outputStream = null
    }

    /**
     * Send a protocol message and wait for a response.
     */
    fun send(bytes: ByteArray, timeoutMs: Long = 3000): ByteArray? {
        val os = outputStream ?: return null
        val ins = inputStream ?: return null

        return try {
            os.write(bytes)
            os.flush()

            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(256)

            while (System.currentTimeMillis() < deadline) {
                if (ins.available() > 0) {
                    // Small delay to let the full response arrive
                    Thread.sleep(100)
                    val n = ins.read(buf)
                    if (n > 0) {
                        return buf.copyOf(n)
                    }
                }
                Thread.sleep(50)
            }
            null
        } catch (e: IOException) {
            Log.e(TAG, "Send/receive error: ${e.message}")
            null
        }
    }

    /**
     * Get the currently active source device MAC.
     * Command: [0x04, 0x09, 0x01, 0x00]
     * Response: [0x04, 0x09, 0x03, 0x06, ...6 MAC bytes]
     */
    fun getActiveDevice(): ByteArray? {
        val resp = send(byteArrayOf(0x04, 0x09, OP_GET, 0x00)) ?: return null
        if (resp.size >= 10 && resp[2] == OP_RESP) {
            return resp.copyOfRange(4, 10)
        }
        return null
    }

    /**
     * Get list of paired/connected devices.
     * Command: [0x04, 0x04, 0x01, 0x00]
     */
    fun getPairedDevices(): List<ByteArray> {
        val resp = send(byteArrayOf(0x04, 0x04, OP_GET, 0x00)) ?: return emptyList()
        if (resp.size < 8 || resp[2] != OP_RESP) return emptyList()

        val payloadLen = resp[3].toInt() and 0xFF
        if (payloadLen < 7 || resp.size < 4 + payloadLen) return emptyList()

        val devices = mutableListOf<ByteArray>()
        var i = 5
        while (i + 6 <= resp.size && i < 4 + payloadLen) {
            devices.add(resp.copyOfRange(i, i + 6))
            i += 6
        }
        return devices
    }

    /**
     * Connect (switch source to) a device by MAC.
     * Command: [0x04, 0x02, 0x05, 0x06] + 6 MAC bytes
     * Returns: true if ACK received
     */
    fun connectDevice(mac: ByteArray): Boolean {
        val cmd = byteArrayOf(0x04, 0x02, OP_START, 0x06) + mac
        val resp = send(cmd, timeoutMs = 10000) ?: return false
        return resp.size >= 4 && resp[2] == OP_ACK
    }

    /**
     * Disconnect a device by MAC.
     * Command: [0x04, 0x03, 0x05, 0x06] + 6 MAC bytes
     */
    fun disconnectDevice(mac: ByteArray): Boolean {
        val cmd = byteArrayOf(0x04, 0x03, OP_START, 0x06) + mac
        val resp = send(cmd, timeoutMs = 5000) ?: return false
        return resp.size >= 4 && resp[2] == OP_ACK
    }

    // === Helpers ===

    fun macToString(mac: ByteArray): String =
        mac.joinToString(":") { String.format("%02X", it) }

    fun nameForMac(mac: ByteArray): String {
        for ((name, addr) in DEVICES) {
            if (addr.contentEquals(mac)) return name
        }
        return macToString(mac)
    }

    /**
     * Get the next device in the cycle order after the current active one.
     */
    fun nextDevice(currentName: String): String {
        val idx = CYCLE_ORDER.indexOf(currentName)
        return if (idx >= 0) {
            CYCLE_ORDER[(idx + 1) % CYCLE_ORDER.size]
        } else {
            CYCLE_ORDER[0]
        }
    }
}
