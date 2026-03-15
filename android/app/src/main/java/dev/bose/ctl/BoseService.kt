package dev.bose.ctl

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

/**
 * Foreground service for managing Bose RFCOMM connection.
 * Must run as foreground service because Android 12+ blocks background service starts
 * from widget BroadcastReceivers.
 */
class BoseService : Service() {

    companion object {
        private const val TAG = "BoseService"
        private const val CHANNEL_ID = "bose_ctl"
        private const val NOTIFICATION_ID = 1

        const val ACTION_CONNECT_DEVICE = "dev.bose.ctl.CONNECT_DEVICE"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val ACTION_REFRESH = "dev.bose.ctl.REFRESH"

        const val BROADCAST_STATUS = "dev.bose.ctl.STATUS_UPDATE"
        const val EXTRA_ACTIVE_DEVICE = "active_device"
        const val EXTRA_CONNECTED_DEVICES = "connected_devices"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): BoseService = this@BoseService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWithNotification()

        when (intent?.action) {
            ACTION_CONNECT_DEVICE -> {
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: return START_NOT_STICKY
                executor.submit {
                    switchDevice(deviceName)
                    stopSelf(startId)
                }
            }
            ACTION_REFRESH -> {
                executor.submit {
                    refreshStatus()
                    stopSelf(startId)
                }
            }
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bose Control",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "RFCOMM operations"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun startForegroundWithNotification() {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_headphones)
            .setContentTitle("Bose")
            .setContentText("Switching source...")
            .setSilent(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureConnected(): Boolean {
        if (BoseProtocol.isConnected) return true
        Log.d(TAG, "Connecting to headphones...")
        return BoseProtocol.connect()
    }

    private fun queryConnectedNames(): ArrayList<String> {
        val connectedMacs = BoseProtocol.getConnectedDevices()
        return ArrayList(connectedMacs.map { BoseProtocol.nameForMac(it) })
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
                val connected = queryConnectedNames()
                broadcastStatus(deviceName, true, connected)
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
                val connected = queryConnectedNames()
                broadcastStatus(name, true, connected)
            } else {
                broadcastError("Could not get active device")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Refresh error", e)
            broadcastError(e.message ?: "Unknown error")
        }
    }

    private fun broadcastStatus(activeDevice: String, success: Boolean, connectedDevices: ArrayList<String>? = null) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_ACTIVE_DEVICE, activeDevice)
            putExtra(EXTRA_SUCCESS, success)
            connectedDevices?.let { putStringArrayListExtra(EXTRA_CONNECTED_DEVICES, it) }
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
