package au.com.jd.bose

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * ViewModel for Bose headphone state.
 * All protocol commands run via on-demand RFCOMM connections on IO dispatcher.
 */
class BoseViewModel(application: Application) : AndroidViewModel(application) {

    // Device connection states
    enum class DeviceState { ACTIVE, CONNECTED, OFFLINE }

    data class UiState(
        // Dashboard
        val batteryLevel: Int = -1,
        val batteryCharging: Boolean = false,
        val ancMode: BoseProtocol.AncMode = BoseProtocol.AncMode.QUIET,
        val firmwareVersion: String = "",
        val deviceName: String = "",

        // Volume
        val volume: Int = 0,
        val volumeMax: Int = 31,

        // Devices
        val deviceStates: Map<String, DeviceState> = BoseDeviceMap.knownDevices
            .associate { it.name to DeviceState.OFFLINE },

        // Settings
        val multipointEnabled: Boolean = false,
        // Noise level (1F,06) — the active mode's CNC level + whether it's adjustable
        // (firmware cncMutable: only the custom slots 4/5). modeName labels the hint.
        val noiseLevel: Int = 0,
        val noiseAdjustable: Boolean = false,
        val modeName: String = "",
        val autoOffTimer: String = "",
        val immersionLevel: IntArray? = null,

        // Info
        val serialNumber: String = "",
        val platform: String = "",
        val codename: String = "",
        val codecName: String = "",
        val codecBitrate: Int = 0,
        val productName: String = "",
        val headphonesMac: String = Headphone.MAC,

        // EQ (3-band, writable via setEq)
        val eqBass: Int = 0,
        val eqMid: Int = 0,
        val eqTreble: Int = 0,

        // UI
        val loading: Boolean = false,
        val error: String? = null,
        val settingsExpanded: Boolean = false,
        val infoExpanded: Boolean = false,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    fun refreshAll() {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            try {
                BoseProtocol.withConnection {
                    // Collect all results into a local copy, emit once at end
                    var s = _state.value

                    BoseProtocol.getBattery()?.let { s = s.copy(batteryLevel = it.level, batteryCharging = it.charging) }
                    BoseProtocol.getAncMode()?.let { s = s.copy(ancMode = it) }
                    BoseProtocol.getVolume()?.let { s = s.copy(volume = it.current, volumeMax = it.max) }

                    // Device connection states
                    val audioNames = Composites.getConnectedDevices()
                        .map { BoseDeviceMap.nameForMac(it.toByteArray()) }.toSet()
                    val aclNames = mutableSetOf<String>()
                    for (device in BoseDeviceMap.knownDevices) {
                        val info = BoseProtocol.getDeviceInfo(device.mac.toIntArray())
                        if (info != null && info.connected) aclNames.add(device.name)
                    }
                    s = s.copy(deviceStates = BoseDeviceMap.knownDevices.associate { device ->
                        device.name to when {
                            audioNames.contains(device.name) -> DeviceState.ACTIVE
                            aclNames.contains(device.name) -> DeviceState.CONNECTED
                            else -> DeviceState.OFFLINE
                        }
                    })

                    BoseProtocol.getFirmwareVersion()?.let { s = s.copy(firmwareVersion = it) }
                    BoseProtocol.getDeviceName()?.let { s = s.copy(deviceName = it) }
                    BoseProtocol.getMultipoint()?.let { s = s.copy(multipointEnabled = it) }
                    Composites.readActiveModeConfig()?.let {
                        s = s.copy(noiseLevel = it.cncLevel, noiseAdjustable = it.cncMutable, modeName = it.displayName)
                    }
                    BoseProtocol.getAutoOffTimer()?.let { s = s.copy(autoOffTimer = BoseProtocol.autoOffTimerDescription(it)) }
                    BoseProtocol.getSerialNumber()?.let { s = s.copy(serialNumber = it) }
                    BoseProtocol.getPlatform()?.let { s = s.copy(platform = it) }
                    BoseProtocol.getCodename()?.let { s = s.copy(codename = it) }
                    BoseProtocol.getAudioCodec()?.let { s = s.copy(codecName = BoseProtocol.codecName(it.codecId), codecBitrate = it.bitrate) }
                    BoseProtocol.getProductName()?.let { s = s.copy(productName = it) }
                    BoseProtocol.getEq()?.let { s = s.copy(eqBass = it.bass.value, eqMid = it.mid.value, eqTreble = it.treble.value) }
                    BoseProtocol.getImmersionLevel()?.let { s = s.copy(immersionLevel = it) }

                    // Single emission — one recomposition instead of 18
                    _state.value = s.copy(loading = false)
                }
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    loading = false,
                    error = e.message ?: "Connection failed",
                )
            }
        }
    }

    fun switchDevice(name: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            try {
                val mac = BoseDeviceMap.mac(name)?.toIntArray() ?: run {
                    _state.value = _state.value.copy(loading = false)
                    return@launch
                }
                val result = BoseProtocol.withConnection {
                    Composites.connectDevice(mac)
                }
                if (result == Composites.SwitchResult.TARGET_OFFLINE) {
                    _state.value = _state.value.copy(
                        loading = false,
                        error = "$name is offline — connect it to Bose first",
                    )
                    return@launch
                }
                refreshAll()
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    loading = false,
                    error = "Failed to switch to $name: ${e.message}",
                )
            }
        }
    }

    /** Send a command to headphones with error handling. */
    private fun command(
        errorPrefix: String,
        action: suspend () -> Unit,
        onSuccess: () -> Unit = {},
    ) {
        viewModelScope.launch {
            try {
                BoseProtocol.withConnection { action() }
                onSuccess()
            } catch (e: Exception) {
                _state.value = _state.value.copy(error = "$errorPrefix: ${e.message}")
            }
        }
    }

    /**
     * Set the ANC mode, then re-read the active mode's config in the SAME warm session
     * so the noise slider's enabled state + level update immediately. A mode change can
     * flip `cncMutable`/`cncLevel` (e.g. quiet → custom1), and without this re-read the
     * slider stayed stale until a manual Refresh (#96). Falls back to the optimistic
     * `ancMode` copy if the config read is unreachable.
     */
    fun setAncMode(mode: BoseProtocol.AncMode) {
        viewModelScope.launch {
            try {
                val cfg = BoseProtocol.withConnection {
                    BoseProtocol.setAncMode(mode)
                    Composites.readActiveModeConfig()
                }
                _state.value = if (cfg != null) {
                    _state.value.copy(
                        ancMode = mode,
                        noiseLevel = cfg.cncLevel,
                        noiseAdjustable = cfg.cncMutable,
                        modeName = cfg.displayName,
                    )
                } else {
                    _state.value.copy(ancMode = mode)
                }
            } catch (e: Exception) {
                _state.value = _state.value.copy(error = "Failed to set ANC: ${e.message}")
            }
        }
    }

    fun setVolume(level: Int) = command("Failed to set volume",
        action = { BoseProtocol.setVolume(level) },
        onSuccess = { _state.value = _state.value.copy(volume = level) },
    )

    fun setDeviceName(name: String) = command("Failed to set name",
        action = { BoseProtocol.setDeviceName(name) },
        onSuccess = { _state.value = _state.value.copy(deviceName = name) },
    )

    fun setMultipoint(enabled: Boolean) = command("Failed to set multipoint",
        action = { BoseProtocol.setMultipoint(enabled) },
        onSuccess = { _state.value = _state.value.copy(multipointEnabled = enabled) },
    )

    fun setEq(bass: Int, mid: Int, treble: Int) = command("Failed to set EQ",
        action = { BoseProtocol.setEq(bass, mid, treble) },
        onSuccess = { _state.value = _state.value.copy(eqBass = bass, eqMid = mid, eqTreble = treble) },
    )

    /**
     * Set the active mode's noise level via the 1F,06 RMW. No-op on a fixed mode (the
     * slider is disabled there anyway, and `setActiveModeLevel` refuses) so it can never
     * disable ANC (#83).
     */
    fun setNoiseLevel(level: Int) {
        if (!_state.value.noiseAdjustable) return
        command("Failed to set noise level",
            action = { Composites.setActiveModeLevel(level) },
            onSuccess = { _state.value = _state.value.copy(noiseLevel = level) },
        )
    }

    fun toggleSettings() {
        _state.value = _state.value.copy(
            settingsExpanded = !_state.value.settingsExpanded,
        )
    }

    fun toggleInfo() {
        _state.value = _state.value.copy(
            infoExpanded = !_state.value.infoExpanded,
        )
    }

    fun clearError() {
        _state.value = _state.value.copy(error = null)
    }
}
