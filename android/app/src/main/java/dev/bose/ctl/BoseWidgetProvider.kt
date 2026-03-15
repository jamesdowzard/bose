package dev.bose.ctl

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
 * Home screen widget (4x1) showing device buttons.
 * Active device is highlighted in green (#00ff88).
 * Tapping any device sends CONNECT command via BoseService.
 */
class BoseWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "BoseWidget"
        private const val COLOR_ACTIVE = 0xFF00FF88.toInt()
        private const val COLOR_INACTIVE = 0xFF666666.toInt()
        private const val COLOR_BG = 0xFF1A1A1A.toInt()
        private const val ACTION_WIDGET_CLICK = "dev.bose.ctl.WIDGET_CLICK"

        /**
         * Update all widget instances with current active device.
         */
        fun updateAll(context: Context, activeDevice: String?) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BoseWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            for (id in ids) {
                updateWidget(context, manager, id, activeDevice)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            activeDevice: String?
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
                val isActive = name == activeDevice
                views.setTextColor(viewId, if (isActive) COLOR_ACTIVE else COLOR_INACTIVE)

                // Set click intent
                val intent = Intent(context, BoseWidgetProvider::class.java).apply {
                    action = ACTION_WIDGET_CLICK
                    putExtra("device_name", name)
                }
                val pi = PendingIntent.getBroadcast(
                    context, viewId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(viewId, pi)
            }

            manager.updateAppWidget(widgetId, views)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        // Get saved active device
        val prefs = context.getSharedPreferences("bose_ctl", Context.MODE_PRIVATE)
        val activeDevice = prefs.getString("active_device", null)

        for (id in widgetIds) {
            updateWidget(context, manager, id, activeDevice)
        }

        // Request fresh status
        val intent = Intent(context, BoseService::class.java).apply {
            action = BoseService.ACTION_REFRESH
        }
        context.startService(intent)
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
                context.startService(serviceIntent)
            }
            BoseService.BROADCAST_STATUS -> {
                val success = intent.getBooleanExtra(BoseService.EXTRA_SUCCESS, false)
                if (success) {
                    val activeDevice = intent.getStringExtra(BoseService.EXTRA_ACTIVE_DEVICE)
                    // Save for widget updates
                    context.getSharedPreferences("bose_ctl", Context.MODE_PRIVATE)
                        .edit()
                        .putString("active_device", activeDevice)
                        .apply()
                    updateAll(context, activeDevice)
                }
            }
        }
    }
}
