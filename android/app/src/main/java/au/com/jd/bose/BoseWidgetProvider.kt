package au.com.jd.bose

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.util.Log
import android.widget.RemoteViews

/**
 * Home screen widget (5x1) showing device buttons with connection state.
 *
 * States:
 * - Green (#00FF88) = active (audio routed here)
 * - Orange (#FF9500) = connected but not active
 * - Grey (#666666) = offline/not connected
 *
 * Shows battery percentage overlay.
 * Tapping any device sends CONNECT command via BoseService.
 */
class BoseWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "BoseWidget"
        private const val COLOR_ACTIVE = 0xFF00FF88.toInt()
        private const val COLOR_CONNECTED = 0xFFFF9500.toInt()
        private const val COLOR_OFFLINE = 0xFF666666.toInt()
        private const val COLOR_ACTIVE_BG = 0xFF002211.toInt()
        private const val COLOR_CONNECTED_BG = 0xFF1A1500.toInt()
        private const val COLOR_OFFLINE_BG = 0xFF222222.toInt()
        private const val ACTION_WIDGET_CLICK = "au.com.jd.bose.WIDGET_CLICK"
        private const val PREFS_NAME = "bose_ctl"

        /**
         * Update all widget instances with current device states.
         */
        fun updateAll(context: Context, activeDevice: String?, connectedDevices: Set<String> = emptySet()) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BoseWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)

            // Save state
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString("active_device", activeDevice)
                .putStringSet("connected_devices", connectedDevices)
                .apply()

            for (id in ids) {
                updateWidget(context, manager, id, activeDevice, connectedDevices)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            activeDevice: String?,
            connectedDevices: Set<String>,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_layout)

            val buttonIds = mapOf(
                "phone" to R.id.btn_phone,
                "mac" to R.id.btn_mac,
                "ipad" to R.id.btn_ipad,
                "iphone" to R.id.btn_iphone,
                "tv" to R.id.btn_tv,
            )

            // Battery overlay
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val batteryLevel = prefs.getInt("battery_level", -1)

            for ((name, viewId) in buttonIds) {
                val isActive = name == activeDevice
                val isConnected = connectedDevices.contains(name)

                val textColor = when {
                    isActive -> COLOR_ACTIVE
                    isConnected -> COLOR_CONNECTED
                    else -> COLOR_OFFLINE
                }
                val bgColor = when {
                    isActive -> COLOR_ACTIVE_BG
                    isConnected -> COLOR_CONNECTED_BG
                    else -> COLOR_OFFLINE_BG
                }

                views.setTextColor(viewId, textColor)
                views.setInt(viewId, "setBackgroundColor", bgColor)

                // Click intent
                val intent = Intent(context, BoseWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_CLICK
                    putExtra("device_name", name)
                }
                val pi = PendingIntent.getBroadcast(
                    context, viewId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(viewId, pi)
            }

            // Battery text
            if (batteryLevel >= 0) {
                views.setTextViewText(R.id.txt_battery, "${batteryLevel}%")
                views.setTextColor(R.id.txt_battery, when {
                    batteryLevel <= 15 -> Color.RED
                    batteryLevel <= 30 -> COLOR_CONNECTED
                    else -> COLOR_ACTIVE
                })
            }

            manager.updateAppWidget(widgetId, views)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val activeDevice = prefs.getString("active_device", null)
        val connectedDevices = prefs.getStringSet("connected_devices", emptySet()) ?: emptySet()

        for (id in widgetIds) {
            updateWidget(context, manager, id, activeDevice, connectedDevices)
        }

        // Request fresh status
        val intent = Intent(context, BoseService::class.java).apply {
            action = BoseService.ACTION_REFRESH
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        when (intent.action) {
            ACTION_WIDGET_CLICK -> {
                val deviceName = intent.getStringExtra("device_name") ?: return
                Log.i(TAG, "Widget click: $deviceName")

                val serviceIntent = Intent(context, BoseService::class.java).apply {
                    action = BoseService.ACTION_CONNECT_DEVICE
                    putExtra(BoseService.EXTRA_DEVICE_NAME, deviceName)
                }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            }
            BoseService.BROADCAST_STATUS -> {
                val success = intent.getBooleanExtra(BoseService.EXTRA_SUCCESS, false)
                if (success) {
                    val activeDevice = intent.getStringExtra(BoseService.EXTRA_ACTIVE_DEVICE)
                    val connectedArr = intent.getStringArrayExtra(BoseService.EXTRA_CONNECTED_DEVICES)
                    val connectedDevices = connectedArr?.toSet() ?: emptySet()
                    val batteryLevel = intent.getIntExtra(BoseService.EXTRA_BATTERY_LEVEL, -1)

                    // Save battery for widget
                    if (batteryLevel >= 0) {
                        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                            .putInt("battery_level", batteryLevel)
                            .apply()
                    }

                    updateAll(context, activeDevice, connectedDevices)
                }
            }
        }
    }
}
