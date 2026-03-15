package dev.bose.ctl

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * Main activity: grants permissions and provides manual control.
 * Minimal UI built programmatically — no XML layout needed.
 */
class MainActivity : Activity() {

    companion object {
        private const val PERM_REQUEST = 100
        private const val COLOR_BG = 0xFF0D0D0D.toInt()
        private const val COLOR_ACCENT = 0xFF00FF88.toInt()
        private const val COLOR_TEXT = 0xFFE0E0E0.toInt()
        private const val COLOR_DIM = 0xFF666666.toInt()
        private const val COLOR_BUTTON_BG = 0xFF1A1A1A.toInt()
        private const val COLOR_ACTIVE_BG = 0xFF002211.toInt()
    }

    private var activeDevice: String? = null
    private var statusText: TextView? = null
    private val deviceButtons = mutableMapOf<String, Button>()

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BoseService.BROADCAST_STATUS) {
                val success = intent.getBooleanExtra(BoseService.EXTRA_SUCCESS, false)
                if (success) {
                    activeDevice = intent.getStringExtra(BoseService.EXTRA_ACTIVE_DEVICE)
                    updateUI()
                } else {
                    val error = intent.getStringExtra(BoseService.EXTRA_ERROR)
                    statusText?.text = "Error: ${error ?: "unknown"}"
                    statusText?.setTextColor(Color.RED)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkPermissions()
        buildUI()
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(BoseService.BROADCAST_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, filter)
        }
        refreshStatus()
    }

    override fun onPause() {
        try { unregisterReceiver(statusReceiver) } catch (_: Exception) {}
        super.onPause()
    }

    private fun checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val perms = arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
            )
            val needed = perms.filter {
                checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
            }
            if (needed.isNotEmpty()) {
                requestPermissions(needed.toTypedArray(), PERM_REQUEST)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        if (requestCode == PERM_REQUEST) {
            if (grantResults.any { it != PackageManager.PERMISSION_GRANTED }) {
                Toast.makeText(this, "Bluetooth permissions required", Toast.LENGTH_LONG).show()
            }
        }
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics).toInt()

    @SuppressLint("SetTextI18n")
    private fun buildUI() {
        val root = ScrollView(this).apply {
            setBackgroundColor(COLOR_BG)
            setPadding(dp(24), dp(48), dp(24), dp(24))
        }

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        // Title
        layout.addView(TextView(this).apply {
            text = "BoseCtl"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            setTextColor(COLOR_ACCENT)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(8))
        })

        // Subtitle
        layout.addView(TextView(this).apply {
            text = "QC Ultra Source Switcher"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(COLOR_DIM)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(32))
        })

        // Status
        statusText = TextView(this).apply {
            text = "Checking..."
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(COLOR_DIM)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(24))
        }
        layout.addView(statusText)

        // Device buttons
        for ((name, _) in BoseProtocol.DEVICES) {
            val btn = Button(this).apply {
                text = name
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setTextColor(COLOR_TEXT)
                setBackgroundColor(COLOR_BUTTON_BG)
                isAllCaps = false
                typeface = Typeface.DEFAULT_BOLD

                val params = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    dp(56)
                ).apply {
                    setMargins(0, dp(4), 0, dp(4))
                }
                layoutParams = params

                setOnClickListener {
                    statusText?.text = "Switching to $name..."
                    statusText?.setTextColor(COLOR_ACCENT)
                    switchDevice(name)
                }
            }
            deviceButtons[name] = btn
            layout.addView(btn)
        }

        // Refresh button
        layout.addView(View(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(24)
            )
        })

        layout.addView(Button(this).apply {
            text = "Refresh"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(COLOR_DIM)
            setBackgroundColor(Color.TRANSPARENT)
            isAllCaps = false
            setOnClickListener { refreshStatus() }
        })

        root.addView(layout)
        setContentView(root)
    }

    @SuppressLint("SetTextI18n")
    private fun updateUI() {
        statusText?.text = "Active: ${activeDevice ?: "unknown"}"
        statusText?.setTextColor(COLOR_ACCENT)

        for ((name, btn) in deviceButtons) {
            if (name == activeDevice) {
                btn.setTextColor(COLOR_ACCENT)
                btn.setBackgroundColor(COLOR_ACTIVE_BG)
            } else {
                btn.setTextColor(COLOR_TEXT)
                btn.setBackgroundColor(COLOR_BUTTON_BG)
            }
        }

        // Also save and update widgets
        getSharedPreferences("bose_ctl", MODE_PRIVATE)
            .edit()
            .putString("active_device", activeDevice)
            .apply()
        BoseWidgetProvider.updateAll(this, activeDevice)
    }

    private fun switchDevice(name: String) {
        val intent = Intent(this, BoseService::class.java).apply {
            action = BoseService.ACTION_CONNECT_DEVICE
            putExtra(BoseService.EXTRA_DEVICE_NAME, name)
        }
        startService(intent)
    }

    private fun refreshStatus() {
        val intent = Intent(this, BoseService::class.java).apply {
            action = BoseService.ACTION_REFRESH
        }
        startService(intent)
    }
}
