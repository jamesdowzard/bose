package dev.bose.ctl

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * Quick Settings tile for Bose source switching.
 *
 * - Shows current active source as subtitle
 * - Tapping opens DevicePickerActivity dialog
 * - Long-press refreshes status
 */
class BoseTileService : TileService() {

    companion object {
        private const val TAG = "BoseTile"
    }

    private var activeDevice: String? = null

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BoseService.BROADCAST_STATUS) {
                val success = intent.getBooleanExtra(BoseService.EXTRA_SUCCESS, false)
                if (success) {
                    activeDevice = intent.getStringExtra(BoseService.EXTRA_ACTIVE_DEVICE)
                    updateTile()
                }
            }
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun onStartListening() {
        super.onStartListening()
        val filter = IntentFilter(BoseService.BROADCAST_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, filter)
        }
        // Refresh status when tile becomes visible
        refreshStatus()
    }

    override fun onStopListening() {
        try {
            unregisterReceiver(statusReceiver)
        } catch (_: Exception) {}
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        // Open device picker dialog
        val intent = Intent(this, DevicePickerActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activeDevice?.let { putExtra("current_device", it) }
        }
        startActivityAndCollapse(intent)
    }

    private fun refreshStatus() {
        val intent = Intent(this, BoseService::class.java).apply {
            action = BoseService.ACTION_REFRESH
        }
        startService(intent)
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = if (activeDevice != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Bose"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = activeDevice ?: "..."
        }
        tile.icon = Icon.createWithResource(this, R.drawable.ic_headphones)
        tile.updateTile()
    }
}
