package au.com.jd.bose

import android.Manifest
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
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
import androidx.compose.material3.lightColorScheme
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

    companion object {
        private const val TAG = "BoseMain"
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (results.values.all { it }) {
            // Permissions granted — now set up companion + service
            ensureCompanionDevice()
        }
    }

    private lateinit var companionLauncher: ActivityResultLauncher<IntentSenderRequest>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Register companion launcher BEFORE setContent/lifecycle starts
        companionLauncher = registerForActivityResult(
            ActivityResultContracts.StartIntentSenderForResult()
        ) { result ->
            if (result.resultCode == RESULT_OK) {
                Log.i(TAG, "Companion device confirmed by user")
            } else {
                Log.w(TAG, "Companion device association declined")
            }
            // Start service regardless — companion is nice-to-have
            startBoseService()
        }

        if (hasBluetoothPermissions()) {
            ensureCompanionDevice()
        } else {
            requestBluetoothPermissions()
        }

        setContent {
            BoseTheme {
                BoseApp()
            }
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
                && checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestBluetoothPermissions() {
        permissionLauncher.launch(arrayOf(
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_SCAN,
        ))
    }

    /**
     * Register as companion app for the Bose headphones.
     * Grants: background FGS starts, battery optimization exemption,
     * wake on BT connect/disconnect. Prompts user once.
     */
    private fun ensureCompanionDevice() {
        try {
            val cdm = getSystemService(CompanionDeviceManager::class.java)
            if (cdm == null) {
                Log.w(TAG, "CompanionDeviceManager not available")
                startBoseService()
                return
            }

            // Check if already associated (API 33+ returns List<AssociationInfo>)
            if (isAlreadyAssociated(cdm)) {
                Log.d(TAG, "Already associated with Bose headphones")
                startBoseService()
                return
            }

            Log.i(TAG, "Requesting companion association for ${Headphone.MAC}")
            val filter = BluetoothDeviceFilter.Builder()
                .setAddress(Headphone.MAC)
                .build()
            val request = AssociationRequest.Builder()
                .addDeviceFilter(filter)
                .setSingleDevice(true)
                .build()

            // API 33+ uses Executor-based callback with different methods
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                cdm.associate(request, mainExecutor, object : CompanionDeviceManager.Callback() {
                    override fun onAssociationCreated(associationInfo: AssociationInfo) {
                        Log.i(TAG, "Companion association created: ${associationInfo.id}")
                        startBoseService()
                    }

                    override fun onAssociationPending(intentSender: IntentSender) {
                        Log.i(TAG, "Companion association pending — showing chooser")
                        try {
                            companionLauncher.launch(
                                IntentSenderRequest.Builder(intentSender).build()
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to launch companion chooser: ${e.message}")
                            startBoseService()
                        }
                    }

                    override fun onFailure(error: CharSequence?) {
                        Log.e(TAG, "Companion association failed: $error")
                        startBoseService()
                    }
                })
            } else {
                // API 31-32 legacy path
                @Suppress("DEPRECATION")
                cdm.associate(request, object : CompanionDeviceManager.Callback() {
                    @Deprecated("Deprecated in API 33")
                    override fun onDeviceFound(chooserLauncher: IntentSender) {
                        try {
                            companionLauncher.launch(
                                IntentSenderRequest.Builder(chooserLauncher).build()
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to launch companion chooser: ${e.message}")
                            startBoseService()
                        }
                    }

                    override fun onFailure(error: CharSequence?) {
                        Log.e(TAG, "Companion association failed: $error")
                        startBoseService()
                    }
                }, null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Companion setup error: ${e.message}", e)
            startBoseService()
        }
    }

    private fun isAlreadyAssociated(cdm: CompanionDeviceManager): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                cdm.myAssociations.any { info ->
                    info.deviceMacAddress?.toString()?.equals(Headphone.MAC, ignoreCase = true) == true
                }
            } else {
                @Suppress("DEPRECATION")
                cdm.associations.any { it.equals(Headphone.MAC, ignoreCase = true) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error checking associations: ${e.message}")
            false
        }
    }

    private fun startBoseService() {
        try {
            val serviceIntent = Intent(this, BoseService::class.java)
            startForegroundService(serviceIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service: ${e.message}")
        }
    }
}

// ======================================================================
// Theme
// ======================================================================

// Palette — Midterm "paper-hc" inspired: warm paper, burnt-orange accent, earthy neutrals.
val BoseAccent = Color(0xFFAF3A03)      // burnt orange — primary accent (was neon green)
val BoseAccentSoft = Color(0xFFF3E4D5)  // soft accent tint (active/selected fills)
val BoseConnected = Color(0xFF1B4A82)   // calm blue — connected-but-not-active (was orange)
val BoseBg = Color(0xFFF4EEDE)          // warm paper background
val BoseCardBg = Color(0xFFFCFAF4)      // warm near-white card
val BoseText = Color(0xFF21201C)        // warm near-black primary text
val BoseDim = Color(0xFF6E6A5E)         // secondary text
val BoseFaint = Color(0xFFA8A18E)       // tertiary text / disabled
val BoseHair = Color(0xFFE6DCC6)        // hairline border / slider track
val BoseActiveBg = Color(0xFFF6EADC)    // active device fill (subtle warm tint)
val BoseError = Color(0xFFA82E2E)       // warm red

private val BoseLightScheme = lightColorScheme(
    primary = BoseAccent,
    secondary = BoseConnected,
    background = BoseBg,
    surface = BoseCardBg,
    onPrimary = Color(0xFFFFFFFF),      // white text on the orange fill
    onSecondary = Color(0xFFFFFFFF),
    onBackground = BoseText,
    onSurface = BoseText,
    error = BoseError,
)

@Composable
fun BoseTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = BoseLightScheme,
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
                    text = "Bose",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = BoseAccent,
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
                        color = BoseAccent,
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

                // 4.5. EQ section
                SectionHeader("Equalizer")
                EqSection(state, onSetEq = { b, m, t -> vm.setEq(b, m, t) })
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
                        onSetNoiseLevel = { vm.setNoiseLevel(it) },
                        onSetSpatial = { vm.setSpatial(it) },
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
                            Text("Dismiss", color = BoseAccent)
                        }
                    },
                    containerColor = Color(0xFFF6E3E0),
                    contentColor = BoseError,
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
                        tint = BoseAccent,
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
                                state.batteryLevel <= 15 -> BoseError
                                state.batteryLevel <= 30 -> BoseConnected
                                else -> BoseAccent
                            },
                        )
                        if (state.batteryCharging) {
                            Text(
                                text = " +",
                                fontSize = 18.sp,
                                color = BoseAccent,
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
    // Wrap into rows of 4 so 7 devices don't get cramped on the S21. The last
    // row is padded with invisible weight spacers to keep tile widths uniform.
    val perRow = 4
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (rowItems in state.deviceStates.toList().chunked(perRow)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for ((name, deviceState) in rowItems) {
                    val (bgColor, textColor, borderColor) = when (deviceState) {
                        BoseViewModel.DeviceState.ACTIVE ->
                            Triple(BoseActiveBg, BoseAccent, BoseAccent)
                        BoseViewModel.DeviceState.CONNECTED ->
                            Triple(Color(0xFFE9EFF6), BoseConnected, BoseConnected)
                        BoseViewModel.DeviceState.OFFLINE ->
                            Triple(BoseCardBg, BoseDim, BoseHair)
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
                                    // friendly label from the device map; fall back to the key
                                    text = BoseDeviceMap.byName[name]?.label ?: name,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = textColor,
                                    textAlign = TextAlign.Center,
                                    maxLines = 2,
                                    lineHeight = 13.sp,
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
                // Pad the short final row so tiles keep a consistent width.
                repeat(perRow - rowItems.size) { Spacer(modifier = Modifier.weight(1f)) }
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
    // Six hardware slots (Quiet/Aware/Immersion/Cinema fixed, C1/C2 adjustable) laid out
    // 3-per-row so the longer labels fit on a phone. The customs (slots 4/5) are what the
    // Noise Level slider needs — they were unreachable while this enum mislabelled 2/3.
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        BoseProtocol.AncMode.entries.chunked(3).forEach { rowModes ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (mode in rowModes) {
                    val isActive = state.ancMode == mode
                    Surface(
                        modifier = Modifier
                            .weight(1f)
                            .height(44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .border(1.dp, if (isActive) BoseAccent else BoseHair, RoundedCornerShape(10.dp))
                            .clickable { onSetAnc(mode) },
                        color = if (isActive) BoseAccent else BoseCardBg,
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(
                                text = mode.label,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                color = if (isActive) Color.White else BoseDim,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
                repeat(3 - rowModes.size) { Spacer(modifier = Modifier.weight(1f)) }
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
                    color = BoseAccent,
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
                    thumbColor = BoseAccent,
                    activeTrackColor = BoseAccent,
                    inactiveTrackColor = BoseHair,
                ),
            )
        }
    }
}

// ======================================================================
// 4.5. EQ section
// ======================================================================

data class EqPreset(val name: String, val bass: Int, val mid: Int, val treble: Int)

private val EQ_PRESETS = listOf(
    EqPreset("Flat", 0, 0, 0),
    EqPreset("Bass+", 6, 0, -2),
    EqPreset("Treble+", -2, 0, 6),
    EqPreset("Vocal", -2, 4, 2),
)

@Composable
fun EqSection(
    state: BoseViewModel.UiState,
    onSetEq: (Int, Int, Int) -> Unit,
) {
    var bass by remember(state.eqBass) { mutableStateOf(state.eqBass.toFloat()) }
    var mid by remember(state.eqMid) { mutableStateOf(state.eqMid.toFloat()) }
    var treble by remember(state.eqTreble) { mutableStateOf(state.eqTreble.toFloat()) }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = BoseCardBg,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Presets
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                EQ_PRESETS.forEach { preset ->
                    val selected = state.eqBass == preset.bass &&
                        state.eqMid == preset.mid && state.eqTreble == preset.treble
                    Surface(
                        modifier = Modifier
                            .weight(1f)
                            .border(1.dp, if (selected) BoseAccent else BoseHair, RoundedCornerShape(8.dp)),
                        shape = RoundedCornerShape(8.dp),
                        color = if (selected) BoseAccent else BoseCardBg,
                        onClick = {
                            bass = preset.bass.toFloat()
                            mid = preset.mid.toFloat()
                            treble = preset.treble.toFloat()
                            onSetEq(preset.bass, preset.mid, preset.treble)
                        },
                    ) {
                        Text(
                            preset.name,
                            modifier = Modifier.padding(vertical = 8.dp),
                            fontSize = 12.sp,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                            color = if (selected) Color.White else BoseDim,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.height(12.dp))

            // Sliders
            EqBandSlider("Bass", bass, onValueChange = { bass = it },
                onFinished = { onSetEq(bass.toInt(), mid.toInt(), treble.toInt()) })
            EqBandSlider("Mid", mid, onValueChange = { mid = it },
                onFinished = { onSetEq(bass.toInt(), mid.toInt(), treble.toInt()) })
            EqBandSlider("Treble", treble, onValueChange = { treble = it },
                onFinished = { onSetEq(bass.toInt(), mid.toInt(), treble.toInt()) })
        }
    }
}

@Composable
private fun EqBandSlider(
    label: String,
    value: Float,
    onValueChange: (Float) -> Unit,
    onFinished: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 12.sp, color = BoseDim, modifier = Modifier.width(48.dp))
        Slider(
            value = value,
            onValueChange = onValueChange,
            onValueChangeFinished = onFinished,
            valueRange = -10f..10f,
            steps = 19,
            modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(
                thumbColor = BoseAccent,
                activeTrackColor = BoseAccent,
                inactiveTrackColor = BoseHair,
            ),
        )
        Text(
            "${value.toInt()}",
            fontSize = 12.sp,
            color = BoseText,
            modifier = Modifier.width(28.dp),
            textAlign = TextAlign.End,
        )
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
    onSetNoiseLevel: (Int) -> Unit = {},
    onSetSpatial: (Int) -> Unit = {},
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
                cursorBrush = SolidColor(BoseAccent),
                modifier = Modifier
                    .weight(1f)
                    .background(BoseHair, RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            TextButton(onClick = {
                onSetName(nameText)
                editingName = false
            }) {
                Text("Save", color = BoseAccent, fontSize = 12.sp)
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
            color = if (state.multipointEnabled) BoseAccent else BoseDim,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = state.multipointEnabled,
            onCheckedChange = { onSetMultipoint(it) },
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color(0xFFFFFFFF),
                checkedTrackColor = BoseAccent,
                uncheckedThumbColor = BoseDim,
                uncheckedTrackColor = BoseHair,
            ),
        )
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Noise level (1F,06) — adjustable ONLY on custom modes (firmware cncMutable);
    // greys out on Quiet/Aware/Immersion/Cinema. Drives anc-level, NEVER the 1F,0A depth
    // (that disables ANC, #83). 0 = max cancellation … 10 = transparency.
    var noiseValue by remember(state.noiseLevel) { mutableStateOf(state.noiseLevel.toFloat()) }
    SettingRow("Noise Level") {
        Slider(
            value = noiseValue,
            onValueChange = { noiseValue = it },
            onValueChangeFinished = { onSetNoiseLevel(noiseValue.toInt()) },
            valueRange = 0f..10f,
            steps = 9,
            enabled = state.noiseAdjustable,
            modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(
                thumbColor = BoseAccent,
                activeTrackColor = BoseAccent,
                inactiveTrackColor = BoseHair,
                disabledThumbColor = BoseFaint,
                disabledActiveTrackColor = BoseFaint,
                disabledInactiveTrackColor = BoseHair,
            ),
        )
        Text(
            if (state.noiseAdjustable) "${noiseValue.toInt()}" else "—",
            fontSize = 14.sp,
            color = if (state.noiseAdjustable) BoseAccent else BoseDim,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.width(28.dp),
            textAlign = TextAlign.End,
        )
    }
    if (!state.noiseAdjustable) {
        Text(
            text = "${state.modeName.ifEmpty { "This mode" }}'s level is fixed — pick a custom mode",
            fontSize = 11.sp,
            color = BoseDim,
            modifier = Modifier.padding(top = 2.dp),
        )
    }

    Spacer(modifier = Modifier.height(12.dp))

    // Immersive Audio (1F,06 spatial byte): Off / Still / Motion. Settable ONLY on the
    // custom modes (firmware spatialMutable); named modes carry it fixed (Immersion = Motion,
    // Cinema = Still) so this greys out on them, like the Noise Level slider. The global
    // 05,0F path is FuncNotSupp — this per-mode RMW is the only working path.
    Text("Immersive Audio", fontSize = 14.sp, color = BoseText)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        listOf("Off" to 0, "Still" to 1, "Motion" to 2).forEach { (label, value) ->
            val isActive = state.spatial == value
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .height(40.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .border(1.dp, if (isActive) BoseAccent else BoseHair, RoundedCornerShape(10.dp))
                    .then(if (state.spatialAdjustable) Modifier.clickable { onSetSpatial(value) } else Modifier),
                color = if (isActive) BoseAccent else BoseCardBg,
                shape = RoundedCornerShape(10.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        text = label,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        color = if (isActive) Color.White else BoseDim,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
    if (!state.spatialAdjustable) {
        Text(
            text = "${state.modeName.ifEmpty { "This mode" }}'s spatial mode is fixed — pick a custom mode",
            fontSize = 11.sp,
            color = BoseDim,
            modifier = Modifier.padding(top = 2.dp),
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
