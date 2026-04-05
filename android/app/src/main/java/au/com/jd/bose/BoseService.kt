package au.com.jd.bose

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.util.concurrent.Executors

/**
 * Foreground service for managing Bose RFCOMM connection.
 *
 * Features:
 * - Handles connecting, querying, and switching devices off the main thread
 * - A2DP auto-accept: when Bose headphones connect (incoming ACL),
 *   triggers BluetoothA2dp.connect() as insurance for Samsung devices
 * - Broadcasts state changes to UI + widget
 */
class BoseService : Service() {

    companion object {
        private const val TAG = "BoseService"
        private const val CHANNEL_ID = "bose_service"
        private const val NOTIFICATION_ID = 1

        const val ACTION_CONNECT_DEVICE = "au.com.jd.bose.CONNECT_DEVICE"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val ACTION_REFRESH = "au.com.jd.bose.REFRESH"

        const val BROADCAST_STATUS = "au.com.jd.bose.STATUS_UPDATE"
        const val EXTRA_ACTIVE_DEVICE = "active_device"
        const val EXTRA_CONNECTED_DEVICES = "connected_devices"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"
        const val EXTRA_BATTERY_LEVEL = "battery_level"
        const val EXTRA_BATTERY_CHARGING = "battery_charging"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val binder = LocalBinder()
    private var a2dpProxy: BluetoothA2dp? = null

    inner class LocalBinder : Binder() {
        fun getService(): BoseService = this@BoseService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Bose Controller active"))
        registerA2dpReceiver()
        setupA2dpProxy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT_DEVICE -> {
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME)
                    ?: return START_STICKY
                executor.submit { switchDevice(deviceName) }
            }
            ACTION_REFRESH -> {
                executor.submit { refreshStatus() }
            }
        }
        return START_STICKY
    }

    // ======================================================================
    // Notification channel + foreground notification
    // ======================================================================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Bose Controller",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Bose QC Ultra controller service"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_headphones)
                .setContentTitle("Bose")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_headphones)
                .setContentTitle("Bose")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        }
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }

    // ======================================================================
    // A2DP auto-accept
    // ======================================================================

    private val aclReceiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_ACL_CONNECTED) return

            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            } ?: return

            if (device.address != BoseProtocol.BOSE_MAC) return

            Log.i(TAG, "Bose ACL connected -- ensuring A2DP")
            ensureA2dp(device)
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    private fun registerA2dpReceiver() {
        val filter = IntentFilter(BluetoothDevice.ACTION_ACL_CONNECTED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(aclReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(aclReceiver, filter)
        }
    }

    @SuppressLint("MissingPermission")
    private fun setupA2dpProxy() {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (profile == BluetoothProfile.A2DP) {
                    a2dpProxy = proxy as BluetoothA2dp
                    Log.d(TAG, "A2DP proxy connected")
                }
            }
            override fun onServiceDisconnected(profile: Int) {
                if (profile == BluetoothProfile.A2DP) {
                    a2dpProxy = null
                }
            }
        }, BluetoothProfile.A2DP)
    }

    @SuppressLint("MissingPermission")
    private fun ensureA2dp(device: BluetoothDevice) {
        val proxy = a2dpProxy ?: run {
            Log.w(TAG, "A2DP proxy not available")
            return
        }
        try {
            // Use reflection to call connect() -- not in public API
            val method = BluetoothA2dp::class.java.getMethod("connect", BluetoothDevice::class.java)
            val result = method.invoke(proxy, device) as Boolean
            Log.i(TAG, "A2DP connect result: $result")
        } catch (e: Exception) {
            Log.w(TAG, "A2DP connect failed: ${e.message}")
        }
    }

    // ======================================================================
    // Protocol operations
    // ======================================================================

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
                updateNotification("Active: $deviceName")
                broadcastStatus(deviceName, true)
            } else {
                broadcastError("Failed to switch to $deviceName")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Switch error", e)
            broadcastError(e.message ?: "Unknown error")
        } finally {
            BoseProtocol.disconnect()
        }
    }

    private fun refreshStatus() {
        try {
            if (!ensureConnected()) {
                broadcastError("Cannot connect to headphones")
                return
            }

            // Audio-connected devices (ground truth for active)
            val audioMacs = BoseProtocol.getConnectedDevices()
            val audioNames = audioMacs.map { BoseProtocol.nameForMac(it) }

            // Per-device ACL status for all connected devices
            val connectedNames = mutableListOf<String>()
            for ((name, mac) in BoseProtocol.DEVICES) {
                val info = BoseProtocol.getDeviceInfo(mac)
                if (info != null && info.connected) connectedNames.add(name)
            }

            // Battery
            val battery = BoseProtocol.getBattery()

            val activeName = audioNames.firstOrNull() ?: connectedNames.firstOrNull() ?: "none"
            updateNotification(buildString {
                append("Active: $activeName")
                battery?.let { append(" | ${it.level}%") }
            })

            broadcastFullStatus(
                activeDevice = activeName,
                connectedDevices = connectedNames,
                batteryLevel = battery?.level ?: -1,
                batteryCharging = battery?.charging ?: false,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Refresh error", e)
            broadcastError(e.message ?: "Unknown error")
        } finally {
            BoseProtocol.disconnect()
        }
    }

    // ======================================================================
    // Broadcasts
    // ======================================================================

    private fun broadcastStatus(activeDevice: String, success: Boolean) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_ACTIVE_DEVICE, activeDevice)
            putExtra(EXTRA_SUCCESS, success)
        }
        sendBroadcast(intent)
    }

    private fun broadcastFullStatus(
        activeDevice: String,
        connectedDevices: List<String>,
        batteryLevel: Int,
        batteryCharging: Boolean,
    ) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_ACTIVE_DEVICE, activeDevice)
            putExtra(EXTRA_CONNECTED_DEVICES, connectedDevices.toTypedArray())
            putExtra(EXTRA_BATTERY_LEVEL, batteryLevel)
            putExtra(EXTRA_BATTERY_CHARGING, batteryCharging)
            putExtra(EXTRA_SUCCESS, true)
        }
        sendBroadcast(intent)

        // Update widget
        BoseWidgetProvider.updateAll(this, activeDevice, connectedDevices.toSet())
    }

    private fun broadcastError(error: String) {
        val intent = Intent(BROADCAST_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_SUCCESS, false)
            putExtra(EXTRA_ERROR, error)
        }
        sendBroadcast(intent)
    }

    // ======================================================================
    // Lifecycle
    // ======================================================================

    override fun onDestroy() {
        try { unregisterReceiver(aclReceiver) } catch (_: Exception) {}
        a2dpProxy?.let {
            BluetoothAdapter.getDefaultAdapter()?.closeProfileProxy(BluetoothProfile.A2DP, it)
        }
        executor.shutdownNow()
        BoseProtocol.disconnect()
        super.onDestroy()
    }
}
