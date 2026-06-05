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

/**
 * Android RFCOMM transport for BMAP over SPP — the hand-written escape hatch that
 * the generated `BMAP` builders feed into.
 *
 * On-demand connection: each command opens RFCOMM, sends, reads, closes (~200-300ms).
 * Drains 300ms of initial data after connect (Bose firmware quirk). A `ReentrantLock`
 * serialises access so only one command owns the socket at a time. Single attempt per
 * command — no retry loops (CLAUDE.md).
 *
 * This layer is wire-only: it sends the `IntArray` frames the generated builders/
 * composites produce and returns the raw `IntArray` response for the parsers. It holds
 * NO command knowledge — block/function/operator semantics live in generated `BMAP`.
 */
object Transport {

    private const val TAG = "BoseTransport"

    // SPP UUID for BMAP over RFCOMM.
    private val BOSE_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")

    /** getDefaultAdapter() is deprecated but the only option for a context-free singleton. */
    @Suppress("DEPRECATION")
    private val adapter: BluetoothAdapter?
        get() = BluetoothAdapter.getDefaultAdapter()

    private val rfcommLock = ReentrantLock()
    private var socket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    val isConnected: Boolean
        get() = socket?.isConnected == true

    /** The Bose BluetoothDevice (for A2DP insurance), MAC from the generated map. */
    @SuppressLint("MissingPermission")
    fun boseDevice(): BluetoothDevice? = adapter?.getRemoteDevice(Headphone.MAC)

    // ── Connection management ──────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    fun connect(): Boolean {
        rfcommLock.lock()
        closeSocket()

        val adapter = adapter ?: run {
            Log.e(TAG, "No Bluetooth adapter")
            rfcommLock.unlock()
            return false
        }

        val device: BluetoothDevice = adapter.getRemoteDevice(Headphone.MAC)
        return try {
            Log.d(TAG, "Connecting via SPP UUID: $BOSE_UUID")
            val sock = device.createRfcommSocketToServiceRecord(BOSE_UUID)
            sock.connect()
            socket = sock
            inputStream = sock.inputStream
            outputStream = sock.outputStream
            Log.i(TAG, "RFCOMM connected")
            drainInitialData()
            true
        } catch (e: IOException) {
            Log.e(TAG, "RFCOMM connect failed: ${e.message}")
            disconnect()
            false
        }
    }

    /** Close socket and release the RFCOMM lock. */
    fun disconnect() {
        closeSocket()
        if (rfcommLock.isHeldByCurrentThread) rfcommLock.unlock()
    }

    private fun closeSocket() {
        try { inputStream?.close() } catch (_: Exception) {}
        try { outputStream?.close() } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        inputStream = null
        outputStream = null
    }

    /** Drain 300ms of unsolicited status data the Bose firmware sends on connect. */
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
     * On-demand connection pattern: connect, run block, disconnect. Each command gets
     * a fresh RFCOMM socket. connect() acquires rfcommLock; disconnect() releases it.
     */
    suspend fun <T> withConnection(block: suspend () -> T): T = withContext(Dispatchers.IO) {
        if (!connect()) throw IOException("Cannot connect to headphones")
        try {
            block()
        } finally {
            disconnect()
        }
    }

    // ── Low-level send/receive ─────────────────────────────────────────────────

    /**
     * Send a BMAP frame (the `IntArray` a generated builder produced) and wait for the
     * response, returned as an `IntArray` of 0..255 values. Single attempt — no retries.
     * Returns null on timeout or I/O error.
     */
    fun send(frame: IntArray, timeoutMs: Long = 3000): IntArray? {
        val os = outputStream ?: return null
        val ins = inputStream ?: return null
        val bytes = ByteArray(frame.size) { frame[it].toByte() }

        return try {
            Log.d(TAG, "TX: ${frame.toHexString()}")
            os.write(bytes)
            os.flush()

            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(512)
            while (System.currentTimeMillis() < deadline) {
                if (ins.available() > 0) {
                    Thread.sleep(100) // let the full response arrive
                    val n = ins.read(buf)
                    if (n > 0) {
                        val resp = IntArray(n) { buf[it].toInt() and 0xFF }
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

    private fun IntArray.toHexString(): String = joinToString(" ") { "%02X".format(it) }
}
