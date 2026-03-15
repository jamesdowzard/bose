package dev.bose.ctl

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews

/**
 * Home screen widget (4x1) showing device buttons.
 * Active device is highlighted in green, connected in orange, disconnected in grey.
 * Tapping any device starts BoseService directly via PendingIntent.getForegroundService()
 * to avoid Android 12+ background service start restrictions.
 */
class BoseWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "BoseWidget"
        private const val COLOR_ACTIVE = 0xFF00FF88.toInt()
        private const val COLOR_CONNECTED = 0xFFFF9F43.toInt()
        private const val COLOR_DISCONNECTED = 0xFF333333.toInt()

        fun updateAll(context: Context, activeDevice: String?, connectedDevices: List<String> = emptyList()) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BoseWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            for (id in ids) {
                updateWidget(context, manager, id, activeDevice, connectedDevices)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            activeDevice: String?,
            connectedDevices: List<String> = emptyList()
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_layout)

            val buttonIds = mapOf(
                "phone" to R.id.btn_phone,
                "mac" to R.id.btn_mac,
                "ipad" to R.id.btn_ipad,
                "iphone" to R.id.btn_iphone,
                "tv" to R.id.btn_tv,
            )

            for ((name, viewId) in buttonIds) {
                val color = when {
                    name == activeDevice -> COLOR_ACTIVE
                    name in connectedDevices -> COLOR_CONNECTED
                    else -> COLOR_DISCONNECTED
                }
                views.setTextColor(viewId, color)

                // Start foreground service directly — avoids background start restriction
                val intent = Intent(context, BoseService::class.java).apply {
                    action = BoseService.ACTION_CONNECT_DEVICE
                    putExtra(BoseService.EXTRA_DEVICE_NAME, name)
                }
                val pi = PendingIntent.getForegroundService(
                    context, viewId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                )
                views.setOnClickPendingIntent(viewId, pi)
            }

            manager.updateAppWidget(widgetId, views)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        val prefs = context.getSharedPreferences("bose_ctl", Context.MODE_PRIVATE)
        val activeDevice = prefs.getString("active_device", null)
        val connectedDevices = prefs.getStringSet("connected_devices", emptySet())?.toList() ?: emptyList()

        for (id in widgetIds) {
            updateWidget(context, manager, id, activeDevice, connectedDevices)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        if (intent.action == BoseService.BROADCAST_STATUS) {
            val success = intent.getBooleanExtra(BoseService.EXTRA_SUCCESS, false)
            if (success) {
                val activeDevice = intent.getStringExtra(BoseService.EXTRA_ACTIVE_DEVICE)
                val connectedDevices = intent.getStringArrayListExtra(BoseService.EXTRA_CONNECTED_DEVICES) ?: arrayListOf()
                context.getSharedPreferences("bose_ctl", Context.MODE_PRIVATE)
                    .edit()
                    .putString("active_device", activeDevice)
                    .putStringSet("connected_devices", connectedDevices.toSet())
                    .apply()
                updateAll(context, activeDevice, connectedDevices)
            }
        }
    }
}
