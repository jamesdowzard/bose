package dev.bose.ctl

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.util.Log
import java.util.concurrent.Executors

/**
 * Background service for managing Bose RFCOMM connection.
 * Handles connecting, querying, and switching devices off the main thread.
 */
class BoseService : Service() {

    companion object {
        private const val TAG = "BoseService"

        const val ACTION_CONNECT_DEVICE = "dev.bose.ctl.CONNECT_DEVICE"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val ACTION_REFRESH = "dev.bose.ctl.REFRESH"

        const val BROADCAST_STATUS = "dev.bose.ctl.STATUS_UPDATE"
        const val EXTRA_ACTIVE_DEVICE = "active_device"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): BoseService = this@BoseService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT_DEVICE -> {
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: return START_NOT_STICKY
                executor.submit { switchDevice(deviceName) }
            }
            ACTION_REFRESH -> {
                executor.submit { refreshStatus() }
            }
        }
        return START_NOT_STICKY
    }

    private fun ensureConnected(): Boolean {
        if (BoseProtocol.isConnected) return true
        Log.d(TAG, "Connecting to headphones...")
        return BoseProtocol.connect()
    }

    private fun switchDevice(deviceName: String) {
        try {
            if (!ensureConnected()) {
                broadcastError("Cannot connect to headphones")
                return
            }

            val mac = BoseProtocol.DEVICES[deviceName]
            if (mac == null) {
                broadcastError("Unknown device: $deviceName")
                return
            }

            Log.i(TAG, "Switching to $deviceName")
            val success = BoseProtocol.connectDevice(mac)

            if (success) {
                broadcastStatus(deviceName, true)
            } else {
                broadcastError("Failed to switch to $deviceName")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Switch error", e)
            broadcastError(e.message ?: "Unknown error")
        }
    }

    private fun refreshStatus() {
        try {
            if (!ensureConnected()) {
                broadcastError("Cannot connect to headphones")
                return
            }

            val activeMac = BoseProtocol.getActiveDevice()
            if (activeMac != null) {
                val name = BoseProtocol.nameForMac(activeMac)
                broadcastStatus(name, true)
            } else {
                broadcastError("Could not get active device")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Refresh error", e)
            broadcastError(e.message ?: "Unknown error")
        }
    }

    private fun broadcastStatus(activeDevice: String, success: Boolean) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_ACTIVE_DEVICE, activeDevice)
            putExtra(EXTRA_SUCCESS, success)
        }
        sendBroadcast(intent)
    }

    private fun broadcastError(error: String) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_SUCCESS, false)
            putExtra(EXTRA_ERROR, error)
        }
        sendBroadcast(intent)
    }

    override fun onDestroy() {
        executor.shutdownNow()
        BoseProtocol.disconnect()
        super.onDestroy()
    }
}
