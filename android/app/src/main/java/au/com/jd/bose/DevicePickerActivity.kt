package au.com.jd.bose

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle

/**
 * Transparent activity that shows a device picker dialog.
 * Used from the Quick Settings tile.
 */
class DevicePickerActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val currentDevice = intent.getStringExtra("current_device")
        val deviceNames = BoseDeviceMap.knownDevices.map { it.name }.toTypedArray()
        val labels = deviceNames.map { name ->
            if (name == currentDevice) "$name  (active)" else name
        }.toTypedArray()

        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog)
            .setTitle("Switch Bose Source")
            .setItems(labels) { _, which ->
                val selected = deviceNames[which]
                startForegroundService(Intent(this, BoseService::class.java).apply {
                    action = BoseService.ACTION_CONNECT_DEVICE
                    putExtra(BoseService.EXTRA_DEVICE_NAME, selected)
                })
                finish()
            }
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }
}
