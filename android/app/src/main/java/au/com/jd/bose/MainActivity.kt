package au.com.jd.bose

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* permissions granted or denied */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkPermissions()

        // Start foreground service
        val serviceIntent = Intent(this, BoseService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        setContent {
            BoseTheme {
                BoseApp()
            }
        }
    }

    private fun checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val needed = listOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
            ).filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (needed.isNotEmpty()) {
                permissionLauncher.launch(needed.toTypedArray())
            }
        }
    }
}

// ======================================================================
// Theme
// ======================================================================

val BoseGreen = Color(0xFF00FF88)
val BoseOrange = Color(0xFFFF9500)
val BoseBg = Color(0xFF0D0D0D)
val BoseCardBg = Color(0xFF1A1A1A)
val BoseText = Color(0xFFE0E0E0)
val BoseDim = Color(0xFF666666)
val BoseActiveBg = Color(0xFF002211)

private val BoseDarkScheme = darkColorScheme(
    primary = BoseGreen,
    secondary = BoseOrange,
    background = BoseBg,
    surface = BoseCardBg,
    onPrimary = BoseBg,
    onSecondary = BoseBg,
    onBackground = BoseText,
    onSurface = BoseText,
    error = Color(0xFFFF4444),
)

@Composable
fun BoseTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = BoseDarkScheme,
        content = content,
    )
}

// ======================================================================
// Main app composable
// ======================================================================

@Composable
fun BoseApp(vm: BoseViewModel = viewModel()) {
    val state by vm.state.collectAsState()

    LaunchedEffect(Unit) {
        vm.refreshAll()
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = BoseBg,
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 48.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // Header
                Text(
                    text = "BoseCtl",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = BoseGreen,
                )
                Text(
                    text = "QC Ultra Controller",
                    fontSize = 14.sp,
                    color = BoseDim,
                )
                Spacer(modifier = Modifier.height(24.dp))

                // Loading indicator
                if (state.loading) {
                    CircularProgressIndicator(
                        color = BoseGreen,
                        modifier = Modifier.size(24.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                }

                // 1. Dashboard card
                DashboardCard(state)
                Spacer(modifier = Modifier.height(16.dp))

                // 2. Devices section
                SectionHeader("Devices")
                DevicesSection(state, onSwitch = { vm.switchDevice(it) })
                Spacer(modifier = Modifier.height(16.dp))

                // 3. ANC section
                SectionHeader("Noise Control")
                AncSection(state, onSetAnc = { vm.setAncMode(it) })
                Spacer(modifier = Modifier.height(16.dp))

                // 4. Volume section
                SectionHeader("Volume")
                VolumeSection(state, onSetVolume = { vm.setVolume(it) })
                Spacer(modifier = Modifier.height(16.dp))

                // 5. Settings section (expandable)
                ExpandableSection(
                    title = "Settings",
                    expanded = state.settingsExpanded,
                    onToggle = { vm.toggleSettings() },
                ) {
                    SettingsSection(
                        state = state,
                        onSetName = { vm.setDeviceName(it) },
                        onSetMultipoint = { vm.setMultipoint(it) },
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))

                // 6. Info section (expandable)
                ExpandableSection(
                    title = "Info",
                    expanded = state.infoExpanded,
                    onToggle = { vm.toggleInfo() },
                ) {
                    InfoSection(state)
                }
                Spacer(modifier = Modifier.height(16.dp))

                // Refresh button
                TextButton(onClick = { vm.refreshAll() }) {
                    Text("Refresh", color = BoseDim, fontSize = 14.sp)
                }

                Spacer(modifier = Modifier.height(48.dp))
            }

            // Error snackbar
            state.error?.let { error ->
                Snackbar(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(16.dp),
                    action = {
                        TextButton(onClick = { vm.clearError() }) {
                            Text("Dismiss", color = BoseGreen)
                        }
                    },
                    containerColor = Color(0xFF2A1A1A),
                    contentColor = Color(0xFFFF4444),
                ) {
                    Text(error)
                }
            }
        }
    }
}

// ======================================================================
// Section header
// ======================================================================

@Composable
fun SectionHeader(title: String) {
    Text(
        text = title,
        fontSize = 13.sp,
        fontWeight = FontWeight.Bold,
        color = BoseDim,
        letterSpacing = 1.sp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 8.dp),
    )
}

// ======================================================================
// 1. Dashboard card
// ======================================================================

@Composable
fun DashboardCard(state: BoseViewModel.UiState) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        color = BoseCardBg,
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
        ) {
            // Battery row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        painter = painterResource(id = R.drawable.ic_headphones),
                        contentDescription = "Headphones",
                        tint = BoseGreen,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = state.deviceName.ifEmpty { "verBosita" },
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = BoseText,
                    )
                }
                if (state.batteryLevel >= 0) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "${state.batteryLevel}%",
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            color = when {
                                state.batteryLevel <= 15 -> Color(0xFFFF4444)
                                state.batteryLevel <= 30 -> BoseOrange
                                else -> BoseGreen
                            },
                        )
                        if (state.batteryCharging) {
                            Text(
                                text = " +",
                                fontSize = 18.sp,
                                color = BoseGreen,
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Info row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                InfoChip("ANC", state.ancMode.label)
                if (state.firmwareVersion.isNotEmpty()) {
                    InfoChip("FW", state.firmwareVersion)
                }
                // Active device
                val active = state.deviceStates.entries
                    .firstOrNull { it.value == BoseViewModel.DeviceState.ACTIVE }
                if (active != null) {
                    InfoChip("Source", active.key)
                }
            }
        }
    }
}

@Composable
fun InfoChip(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = label,
            fontSize = 10.sp,
            color = BoseDim,
            letterSpacing = 0.5.sp,
        )
        Text(
            text = value,
            fontSize = 14.sp,
            color = BoseText,
            fontWeight = FontWeight.Medium,
        )
    }
}

// ======================================================================
// 2. Devices section
// ======================================================================

@Composable
fun DevicesSection(
    state: BoseViewModel.UiState,
    onSwitch: (String) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for ((name, deviceState) in state.deviceStates) {
            val (bgColor, textColor, borderColor) = when (deviceState) {
                BoseViewModel.DeviceState.ACTIVE ->
                    Triple(BoseActiveBg, BoseGreen, BoseGreen)
                BoseViewModel.DeviceState.CONNECTED ->
                    Triple(Color(0xFF1A1500), BoseOrange, BoseOrange)
                BoseViewModel.DeviceState.OFFLINE ->
                    Triple(BoseCardBg, BoseDim, Color(0xFF333333))
            }

            Surface(
                modifier = Modifier
                    .weight(1f)
                    .height(56.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .border(1.dp, borderColor, RoundedCornerShape(12.dp))
                    .clickable { onSwitch(name) },
                color = bgColor,
                shape = RoundedCornerShape(12.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = name,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = textColor,
                            textAlign = TextAlign.Center,
                        )
                        // State dot
                        Box(
                            modifier = Modifier
                                .padding(top = 4.dp)
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(borderColor),
                        )
                    }
                }
            }
        }
    }
}

// ======================================================================
// 3. ANC section
// ======================================================================

@Composable
fun AncSection(
    state: BoseViewModel.UiState,
    onSetAnc: (BoseProtocol.AncMode) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (mode in BoseProtocol.AncMode.entries) {
            val isActive = state.ancMode == mode
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .height(44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .clickable { onSetAnc(mode) },
                color = if (isActive) BoseGreen else BoseCardBg,
                shape = RoundedCornerShape(10.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        text = mode.label,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isActive) BoseBg else BoseDim,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

// ======================================================================
// 4. Volume section
// ======================================================================

@Composable
fun VolumeSection(
    state: BoseViewModel.UiState,
    onSetVolume: (Int) -> Unit,
) {
    var sliderValue by remember(state.volume) { mutableStateOf(state.volume.toFloat()) }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = BoseCardBg,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Volume", fontSize = 14.sp, color = BoseText)
                Text(
                    "${sliderValue.toInt()}/${state.volumeMax}",
                    fontSize = 14.sp,
                    color = BoseGreen,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            Slider(
                value = sliderValue,
                onValueChange = { sliderValue = it },
                onValueChangeFinished = { onSetVolume(sliderValue.toInt()) },
                valueRange = 0f..state.volumeMax.toFloat(),
                steps = state.volumeMax - 1,
                modifier = Modifier.fillMaxWidth(),
                colors = SliderDefaults.colors(
                    thumbColor = BoseGreen,
                    activeTrackColor = BoseGreen,
                    inactiveTrackColor = Color(0xFF333333),
                ),
            )
        }
    }
}

// ======================================================================
// 5. Settings section
// ======================================================================

@Composable
fun ExpandableSection(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable { onToggle() },
        shape = RoundedCornerShape(12.dp),
        color = BoseCardBg,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = BoseText,
                )
                Text(
                    text = if (expanded) "^" else "v",
                    fontSize = 14.sp,
                    color = BoseDim,
                )
            }
            AnimatedVisibility(visible = expanded) {
                Column(modifier = Modifier.padding(top = 12.dp)) {
                    content()
                }
            }
        }
    }
}

@Composable
fun SettingsSection(
    state: BoseViewModel.UiState,
    onSetName: (String) -> Unit,
    onSetMultipoint: (Boolean) -> Unit,
) {
    // Device name
    var editingName by remember { mutableStateOf(false) }
    var nameText by remember(state.deviceName) { mutableStateOf(state.deviceName) }

    SettingRow("Device Name") {
        if (editingName) {
            BasicTextField(
                value = nameText,
                onValueChange = { nameText = it },
                textStyle = TextStyle(color = BoseText, fontSize = 14.sp),
                cursorBrush = SolidColor(BoseGreen),
                modifier = Modifier
                    .weight(1f)
                    .background(Color(0xFF222222), RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            TextButton(onClick = {
                onSetName(nameText)
                editingName = false
            }) {
                Text("Save", color = BoseGreen, fontSize = 12.sp)
            }
        } else {
            Text(
                text = state.deviceName.ifEmpty { "-" },
                fontSize = 14.sp,
                color = BoseText,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { editingName = true }) {
                Text("Edit", color = BoseDim, fontSize = 12.sp)
            }
        }
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Multipoint
    SettingRow("Multipoint") {
        Text(
            text = if (state.multipointEnabled) "On" else "Off",
            fontSize = 14.sp,
            color = if (state.multipointEnabled) BoseGreen else BoseDim,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = state.multipointEnabled,
            onCheckedChange = { onSetMultipoint(it) },
            colors = SwitchDefaults.colors(
                checkedThumbColor = BoseGreen,
                checkedTrackColor = Color(0xFF003322),
                uncheckedThumbColor = BoseDim,
                uncheckedTrackColor = Color(0xFF333333),
            ),
        )
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Auto-off timer (read-only for now)
    SettingRow("Auto-Off Timer") {
        Text(
            text = state.autoOffTimer.ifEmpty { "-" },
            fontSize = 14.sp,
            color = BoseText,
        )
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Immersion level (raw display)
    SettingRow("Immersion") {
        Text(
            text = state.immersionLevel?.let {
                it.joinToString(" ") { b -> String.format("%02X", b) }
            } ?: "-",
            fontSize = 14.sp,
            color = BoseText,
        )
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Wear detection
    SettingRow("Wear Detection") {
        Text(
            text = if (state.wearDetected) "On Head" else "Off Head",
            fontSize = 14.sp,
            color = if (state.wearDetected) BoseGreen else BoseDim,
        )
    }
}

@Composable
fun SettingRow(
    label: String,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            fontSize = 13.sp,
            color = BoseDim,
            modifier = Modifier.width(110.dp),
        )
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

// ======================================================================
// 6. Info section
// ======================================================================

@Composable
fun InfoSection(state: BoseViewModel.UiState) {
    val items = listOf(
        "Product" to (state.productName.ifEmpty { "-" }),
        "Firmware" to (state.firmwareVersion.ifEmpty { "-" }),
        "Serial" to (state.serialNumber.ifEmpty { "-" }),
        "Platform" to (state.platform.ifEmpty { "-" }),
        "Codename" to (state.codename.ifEmpty { "-" }),
        "Codec" to buildString {
            append(state.codecName.ifEmpty { "-" })
            if (state.codecBitrate > 0) append(" (${state.codecBitrate} kbps)")
        },
        "MAC" to state.headphonesMac,
        "EQ Bass" to state.eqBass.toString(),
        "EQ Mid" to state.eqMid.toString(),
        "EQ Treble" to state.eqTreble.toString(),
    )

    for ((label, value) in items) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(label, fontSize = 13.sp, color = BoseDim)
            Text(
                value,
                fontSize = 13.sp,
                color = BoseText,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f).padding(start = 16.dp),
            )
        }
    }
}
