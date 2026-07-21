package au.com.jd.bose

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews

/**
 * Home screen widget showing device buttons with connection state.
 *
 * Paper-card surface — matches the #98 app retheme (warm paper + burnt-orange).
 * The card sits on the user's home-screen wallpaper, so active/connected are
 * solid filled chips (read on any wallpaper); offline is a recessed paper chip.
 *
 * States (chip fill / text):
 * - Burnt-orange fill (#AF3A03), paper text = active (audio routed here)
 * - Blue fill (#1B4A82), paper text = connected but not active
 * - Muted paper fill (#E6DCC6), secondary text (#6E6A5E) = offline/not connected
 *
 * Shows battery percentage overlay (own on-paper thresholds, see below).
 * Tapping a device sends CONNECT command directly to BoseService
 * via PendingIntent.getForegroundService (companion device grants
 * background FGS start privileges).
 */
class BoseWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "BoseWidget"
        // Paper-card palette — shared with the #98 app retheme. Active/connected are
        // filled chips (strong fill + paper text); offline is a recessed paper chip.
        private const val COLOR_PAPER = 0xFFFCFAF4.toInt()        // chip text on filled states
        private const val COLOR_ACTIVE = COLOR_PAPER              // text on the burnt-orange chip
        private const val COLOR_CONNECTED = COLOR_PAPER           // text on the blue chip
        private const val COLOR_OFFLINE = 0xFF6E6A5E.toInt()      // secondary text on the paper chip
        private const val COLOR_ACTIVE_BG = 0xFFAF3A03.toInt()    // burnt-orange
        private const val COLOR_CONNECTED_BG = 0xFF1B4A82.toInt() // blue
        private const val COLOR_OFFLINE_BG = 0xFFE6DCC6.toInt()   // hairline / muted paper
        // Battery overlay sits on the paper card — needs on-paper-readable colours.
        private const val COLOR_BATTERY_LOW = 0xFFA82E2E.toInt()  // warm red,     <= 15
        private const val COLOR_BATTERY_MID = 0xFFAF3A03.toInt()  // burnt-orange, <= 30
        private const val COLOR_BATTERY_OK = 0xFF6E6A5E.toInt()   // secondary grey, healthy
        private const val PREFS_NAME = "bose_ctl"
        // Provenance of the painted snapshot, so a system-triggered onUpdate repaint
        // (which has no caller to tell it) can still say "this is last-known, not live".
        private const val KEY_SNAPSHOT_STALE = "snapshot_stale"
        private const val KEY_SNAPSHOT_AT = "snapshot_at"

        /**
         * Battery chip text. A cached snapshot carries a "· Xm" age suffix so an
         * hours-old paint can never read as live — same staleness vocabulary as the
         * in-app banner and the Mac (`StateCache.ageText`). Pure: unit-tested.
         */
        internal fun batteryText(batteryLevel: Int, staleAgeSeconds: Int?): String =
            if (staleAgeSeconds == null) "${batteryLevel}%"
            else "${batteryLevel}% · ${StateCache.ageText(staleAgeSeconds)}"

        /** Age of a persisted snapshot at paint time. Pure: unit-tested. */
        internal fun snapshotAge(snapshotAtMs: Long, nowMs: Long): Int =
            ((nowMs - snapshotAtMs) / 1000).coerceAtLeast(0).toInt()

        fun updateAll(
            context: Context,
            activeDevice: String?,
            connectedDevices: Set<String> = emptySet(),
            batteryLevel: Int = -1,
            staleAgeSeconds: Int? = null,   // non-null = painting a cached snapshot
        ) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BoseWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)

            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString("active_device", activeDevice)
                .putStringSet("connected_devices", connectedDevices)
                .putBoolean(KEY_SNAPSHOT_STALE, staleAgeSeconds != null)
                // Store WHEN the data was true, not when we painted it, so a later
                // repaint recomputes a current age instead of replaying a frozen one.
                .putLong(KEY_SNAPSHOT_AT, System.currentTimeMillis() - (staleAgeSeconds ?: 0) * 1000L)
                .apply {
                    if (batteryLevel >= 0) putInt("battery_level", batteryLevel)
                }
                .apply()

            for (id in ids) {
                updateWidget(context, manager, id, activeDevice, connectedDevices, staleAgeSeconds)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            activeDevice: String?,
            connectedDevices: Set<String>,
            staleAgeSeconds: Int? = null,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_layout)

            // View IDs for the fixed 5-button widget layout. The device set is filtered
            // through the generated BoseDeviceMap.widgetDevices so a macOS-only device
            // (tv, widget=false) can never get a button — single source of truth.
            val viewIdByName = mapOf(
                "phone" to R.id.btn_phone,
                "mac" to R.id.btn_mac,
                "ipad" to R.id.btn_ipad,
                "iphone" to R.id.btn_iphone,
                "quest" to R.id.btn_quest,
            )
            val buttonIds = BoseDeviceMap.widgetDevices
                .mapNotNull { device -> viewIdByName[device.name]?.let { device.name to it } }
                .toMap()

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
                views.setTextViewText(R.id.txt_battery, batteryText(batteryLevel, staleAgeSeconds))
                views.setTextColor(R.id.txt_battery, when {
                    batteryLevel <= 15 -> COLOR_BATTERY_LOW
                    batteryLevel <= 30 -> COLOR_BATTERY_MID
                    else -> COLOR_BATTERY_OK
                })
            }

            manager.updateAppWidget(widgetId, views)
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val activeDevice = prefs.getString("active_device", null)
        val connectedDevices = prefs.getStringSet("connected_devices", emptySet()) ?: emptySet()
        // The persisted snapshot was either live or cached when it was written; if cached,
        // re-age it now rather than repainting it as if it were fresh.
        val staleAgeSeconds = if (prefs.getBoolean(KEY_SNAPSHOT_STALE, false)) {
            snapshotAge(prefs.getLong(KEY_SNAPSHOT_AT, System.currentTimeMillis()), System.currentTimeMillis())
        } else null

        for (id in widgetIds) {
            updateWidget(context, manager, id, activeDevice, connectedDevices, staleAgeSeconds)
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
