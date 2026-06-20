package au.com.jd.bose

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Binder
import android.os.IBinder
import android.util.Log
import android.view.KeyEvent
import java.util.concurrent.Executors

/**
 * Foreground service for managing Bose RFCOMM connection.
 *
 * Registered as companion device — has background FGS start privileges.
 *
 * Features:
 * - Handles connecting, querying, and switching devices off the main thread
 * - A2DP auto-accept: when Bose headphones connect (incoming ACL),
 *   triggers BluetoothA2dp.connect() as insurance for Samsung devices
 * - Media playback nudge to force audio stream handover
 * - Broadcasts state changes to UI, updates widget directly
 */
class BoseService : Service() {

    companion object {
        private const val TAG = "BoseService"
        private const val CHANNEL_ID = "bose_service"
        private const val NOTIFICATION_ID = 1

        const val ACTION_CONNECT_DEVICE = "au.com.jd.bose.CONNECT_DEVICE"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val ACTION_REFRESH = "au.com.jd.bose.REFRESH"

        // Media transport sent to the headphones via BMAP mediaControl (05,03).
        const val ACTION_MEDIA = "au.com.jd.bose.MEDIA"
        const val EXTRA_MEDIA_ACTION = "media_action" // BoseProtocol.MediaAction.value

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
            ACTION_MEDIA -> {
                val actionValue = intent.getIntExtra(EXTRA_MEDIA_ACTION, -1)
                val mediaAction = BoseProtocol.MediaAction.entries.find { it.value == actionValue }
                if (mediaAction != null) executor.submit { sendMedia(mediaAction) }
            }
        }
        return START_STICKY
    }

    // ======================================================================
    // Notification
    // ======================================================================

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bose Controller",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Bose QC Ultra controller service"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_headphones)
            .setContentTitle("Bose")
            .setContentText(text)
            .setContentIntent(pi)
            .setOngoing(true)
            // Media transport — sends BMAP mediaControl (05,03) to the headphones.
            .addAction(mediaAction(android.R.drawable.ic_media_previous, "Prev", BoseProtocol.MediaAction.PREV))
            .addAction(mediaAction(android.R.drawable.ic_media_play, "Play", BoseProtocol.MediaAction.PLAY))
            .addAction(mediaAction(android.R.drawable.ic_media_pause, "Pause", BoseProtocol.MediaAction.PAUSE))
            .addAction(mediaAction(android.R.drawable.ic_media_next, "Next", BoseProtocol.MediaAction.NEXT))
            .build()
    }

    /** A notification action that fires the headphone media command via the service. */
    private fun mediaAction(icon: Int, title: String, action: BoseProtocol.MediaAction): Notification.Action {
        val intent = Intent(this, BoseService::class.java).apply {
            this.action = ACTION_MEDIA
            putExtra(EXTRA_MEDIA_ACTION, action.value)
        }
        // Distinct requestCode per action so PendingIntents don't collide.
        val pi = PendingIntent.getForegroundService(
            this, 100 + action.value, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), title, pi).build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    // ======================================================================
    // A2DP (phone-side insurance, "switch to phone" only)
    // ======================================================================

    // No ACL auto-accept: the old aclReceiver called ensureA2dp on every Bose ACL
    // reconnect, which fought user switches to other devices (#61-#64). Samsung's BT
    // stack auto-reconnects ACL after a drop — the receiver would then force A2DP back
    // to the phone, stealing audio from iPad/Mac. A2DP connect happens ONLY in
    // switchDevice's "phone" branch, via the quarantined A2dpReflection hack.

    @SuppressLint("MissingPermission")
    private fun setupA2dpProxy() {
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter ?: return
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

    /**
     * Phone-side A2DP insurance for the "switch to phone" path only. The hidden-API
     * reflection itself is quarantined in [A2dpReflection] — do NOT expand this beyond
     * the local-phone case (never HFP; never on every ACL reconnect — see CLAUDE.md).
     */
    @SuppressLint("MissingPermission")
    private fun ensureA2dp(device: BluetoothDevice) {
        val proxy = a2dpProxy ?: run {
            Log.w(TAG, "A2DP proxy not available")
            return
        }
        A2dpReflection.connect(proxy, device)
    }

    // ======================================================================
    // Media playback nudge
    // ======================================================================

    /**
     * Send pause then play to force active media apps to re-route audio
     * through the new Bluetooth output. Without this, apps like Spotify
     * keep streaming to the old sink even after A2DP connects.
     */
    private fun nudgeMediaPlayback() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (!am.isMusicActive) {
            Log.d(TAG, "No active music, skipping playback nudge")
            return
        }
        Log.i(TAG, "Nudging media playback for audio handover")
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE))
        Thread.sleep(300)
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PLAY))
    }

    // ======================================================================
    // Protocol operations
    // ======================================================================

    private fun ensureConnected(): Boolean {
        if (BoseProtocol.isConnected) return true
        Log.d(TAG, "Connecting to headphones...")
        return BoseProtocol.connect()
    }

    @SuppressLint("MissingPermission")
    private fun switchDevice(deviceName: String) {
        // Skip if already the active device
        val prefs = getSharedPreferences("bose_ctl", Context.MODE_PRIVATE)
        if (prefs.getString("active_device", null) == deviceName) {
            Log.d(TAG, "Already active on $deviceName, skipping")
            return
        }

        try {
            if (!ensureConnected()) {
                broadcastError("Cannot connect to headphones")
                return
            }

            val mac = BoseDeviceMap.mac(deviceName)?.toIntArray()
            if (mac == null) {
                broadcastError("Unknown device: $deviceName")
                return
            }

            // Multipoint eviction (parity with the CLI's evictLowestPriorityIfFull): the
            // headset holds 2 devices and the firmware only evicts by its own LRU. When both
            // slots are full and the target isn't already held, drop the LOWEST-priority held
            // device first so the connect lands the target against our hierarchy, not the
            // firmware's LRU. Restore the victim if the target then fails to connect — never
            // leave a slot empty for nothing.
            val (active, connected) = Composites.getDeviceStates(
                BoseDeviceMap.knownDevices.map { it.mac.toIntArray() }
            )
            val victim = evictionVictim(active + connected, mac)
            if (victim != null) {
                Log.i(TAG, "Evicting ${victim.name} (priority ${victim.priority}) to free a multipoint slot")
                Transport.send(BMAP.disconnectDevice(victim.mac.toIntArray()))
                Thread.sleep(800) // let the slot clear before paging the target
            }

            Log.i(TAG, "Switching to $deviceName")
            val result = Composites.connectDevice(mac)

            when (result) {
                Composites.SwitchResult.SWITCHED -> {
                    // Confirmed by polling getConnectedDevices (never ACK-as-success).
                    Log.i(TAG, "Switch to $deviceName confirmed — target is audio-active")
                    updateNotification("Active: $deviceName")

                    if (deviceName == "phone") {
                        val boseDevice = Transport.boseDevice()
                        if (boseDevice != null) {
                            Log.i(TAG, "Proactively connecting A2DP for local device")
                            ensureA2dp(boseDevice)
                        }

                        Thread.sleep(500)
                        nudgeMediaPlayback()
                    }

                    BoseWidgetProvider.updateAll(this, deviceName, setOf(deviceName))
                    broadcastStatus(deviceName, true)
                }

                Composites.SwitchResult.TARGET_OFFLINE -> {
                    Log.w(TAG, "$deviceName is not connected to Bose — can't switch")
                    restoreEvicted(victim, deviceName)
                    broadcastError("$deviceName is offline — connect it to Bose first")
                }

                Composites.SwitchResult.FAILED -> {
                    restoreEvicted(victim, deviceName)
                    broadcastError("Failed to switch to $deviceName")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Switch error", e)
            broadcastError(e.message ?: "Unknown error")
        } finally {
            BoseProtocol.disconnect()
        }
    }

    /**
     * Re-page a device we evicted, after the target connect failed — restores the prior
     * pair so we never leave a multipoint slot empty for nothing. No-op when nothing was
     * evicted. Mirrors the CLI's `restoreEvicted`. (No host-side BT action: unlike the Mac
     * — which also runs blueutil for its own link — Android just re-sends the BMAP connect.)
     */
    private fun restoreEvicted(victim: BoseDevice?, failedTarget: String) {
        if (victim == null) return
        Log.i(TAG, "Restoring ${victim.name} (target $failedTarget was unreachable)")
        Transport.send(BMAP.connectDevice(victim.mac.toIntArray()))
    }

    /** Send a media transport command (play/pause/next/prev) to the headphones. */
    private fun sendMedia(action: BoseProtocol.MediaAction) {
        try {
            if (!ensureConnected()) {
                broadcastError("Cannot connect to headphones")
                return
            }
            Log.i(TAG, "Media: $action")
            BoseProtocol.mediaControl(action)
        } catch (e: Exception) {
            Log.e(TAG, "Media error", e)
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

            val audioMacs = Composites.getConnectedDevices()
            val audioNames = audioMacs.map { BoseDeviceMap.nameForMac(it.toByteArray()) }

            val connectedNames = mutableListOf<String>()
            for (device in BoseDeviceMap.knownDevices) {
                val info = BoseProtocol.getDeviceInfo(device.mac.toIntArray())
                if (info != null && info.connected) connectedNames.add(device.name)
            }

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
        a2dpProxy?.let {
            getSystemService(BluetoothManager::class.java)?.adapter?.closeProfileProxy(BluetoothProfile.A2DP, it)
        }
        executor.shutdownNow()
        BoseProtocol.disconnect()
        super.onDestroy()
    }
}
