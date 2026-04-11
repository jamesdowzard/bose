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
        val deviceStates: Map<String, DeviceState> = BoseProtocol.DEVICES.keys
            .associateWith { DeviceState.OFFLINE },

        // Settings
        val multipointEnabled: Boolean = false,
        val cncLevel: Int = 0,
        val autoOffTimer: String = "",
        val immersionLevel: ByteArray? = null,
        val wearDetected: Boolean = false,

        // Info
        val serialNumber: String = "",
        val platform: String = "",
        val codename: String = "",
        val codecName: String = "",
        val codecBitrate: Int = 0,
        val productName: String = "",
        val headphonesMac: String = BoseProtocol.BOSE_MAC,

        // EQ (read-only)
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
                    val audioNames = BoseProtocol.getConnectedDevices()
                        .map { BoseProtocol.nameForMac(it) }.toSet()
                    val aclNames = mutableSetOf<String>()
                    for ((name, mac) in BoseProtocol.DEVICES) {
                        val info = BoseProtocol.getDeviceInfo(mac)
                        if (info != null && info.connected) aclNames.add(name)
                    }
                    s = s.copy(deviceStates = BoseProtocol.DEVICES.keys.associateWith { name ->
                        when {
                            audioNames.contains(name) -> DeviceState.ACTIVE
                            aclNames.contains(name) -> DeviceState.CONNECTED
                            else -> DeviceState.OFFLINE
                        }
                    })

                    BoseProtocol.getFirmwareVersion()?.let { s = s.copy(firmwareVersion = it) }
                    BoseProtocol.getDeviceName()?.let { s = s.copy(deviceName = it) }
                    BoseProtocol.getMultipoint()?.let { s = s.copy(multipointEnabled = it) }
                    BoseProtocol.getCncLevel()?.let { s = s.copy(cncLevel = it) }
                    BoseProtocol.getAutoOffTimer()?.let { s = s.copy(autoOffTimer = BoseProtocol.autoOffTimerDescription(it)) }
                    BoseProtocol.getWearState()?.let { s = s.copy(wearDetected = it) }
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
                val mac = BoseProtocol.DEVICES[name] ?: run {
                    _state.value = _state.value.copy(loading = false)
                    return@launch
                }
                val result = BoseProtocol.withConnection {
                    BoseProtocol.connectDevice(mac)
                }
                if (result == BoseProtocol.SwitchResult.TARGET_OFFLINE) {
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

    fun setAncMode(mode: BoseProtocol.AncMode) = command("Failed to set ANC",
        action = { BoseProtocol.setAncMode(mode) },
        onSuccess = { _state.value = _state.value.copy(ancMode = mode) },
    )

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

    fun setCncLevel(level: Int) = command("Failed to set ANC depth",
        action = { BoseProtocol.setCncLevel(level) },
        onSuccess = { _state.value = _state.value.copy(cncLevel = level) },
    )

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
