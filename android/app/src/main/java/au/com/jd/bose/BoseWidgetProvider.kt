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
 * Home screen widget showing device buttons with connection state.
 *
 * States:
 * - Green (#00FF88) = active (audio routed here)
 * - Orange (#FF9500) = connected but not active
 * - Grey (#666666) = offline/not connected
 *
 * Shows battery percentage overlay.
 * Tapping a device sends CONNECT command directly to BoseService
 * via PendingIntent.getForegroundService (companion device grants
 * background FGS start privileges).
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
        private const val PREFS_NAME = "bose_ctl"

        fun updateAll(context: Context, activeDevice: String?, connectedDevices: Set<String> = emptySet()) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BoseWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)

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
                "quest" to R.id.btn_quest,
            )

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

                // Send directly to service — companion device grants FGS privileges
                val intent = Intent(context, BoseService::class.java).apply {
                    action = BoseService.ACTION_CONNECT_DEVICE
                    putExtra(BoseService.EXTRA_DEVICE_NAME, name)
                }
                val pi = PendingIntent.getForegroundService(
                    context, viewId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(viewId, pi)
            }

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

        // Refresh status from headphones
        try {
            val refreshIntent = Intent(context, BoseService::class.java).apply {
                action = BoseService.ACTION_REFRESH
            }
            context.startForegroundService(refreshIntent)
        } catch (e: Exception) {
            Log.w(TAG, "Cannot start service for refresh: ${e.message}")
        }
    }
}
