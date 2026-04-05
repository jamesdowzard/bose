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
                    // Battery
                    BoseProtocol.getBattery()?.let { bat ->
                        _state.value = _state.value.copy(
                            batteryLevel = bat.level,
                            batteryCharging = bat.charging,
                        )
                    }

                    // ANC
                    BoseProtocol.getAncMode()?.let { mode ->
                        _state.value = _state.value.copy(ancMode = mode)
                    }

                    // Volume
                    BoseProtocol.getVolume()?.let { vol ->
                        _state.value = _state.value.copy(
                            volume = vol.current,
                            volumeMax = vol.max,
                        )
                    }

                    // Connected devices (ground truth) + active device
                    val connectedMacs = BoseProtocol.getConnectedDevices()
                    val connectedNames = connectedMacs.map { BoseProtocol.nameForMac(it) }.toSet()
                    val activeMac = BoseProtocol.getActiveDevice()
                    val activeName = activeMac?.let { BoseProtocol.nameForMac(it) }

                    val deviceStates = BoseProtocol.DEVICES.keys.associateWith { name ->
                        when {
                            name == activeName -> DeviceState.ACTIVE
                            connectedNames.contains(name) -> DeviceState.CONNECTED
                            else -> DeviceState.OFFLINE
                        }
                    }
                    _state.value = _state.value.copy(deviceStates = deviceStates)

                    // Firmware
                    BoseProtocol.getFirmwareVersion()?.let { fw ->
                        _state.value = _state.value.copy(firmwareVersion = fw)
                    }

                    // Device name
                    BoseProtocol.getDeviceName()?.let { name ->
                        _state.value = _state.value.copy(deviceName = name)
                    }

                    // Multipoint
                    BoseProtocol.getMultipoint()?.let { mp ->
                        _state.value = _state.value.copy(multipointEnabled = mp)
                    }

                    // Auto-off
                    BoseProtocol.getAutoOffTimer()?.let { timer ->
                        _state.value = _state.value.copy(
                            autoOffTimer = BoseProtocol.autoOffTimerDescription(timer)
                        )
                    }

                    // Wear state
                    BoseProtocol.getWearState()?.let { wearing ->
                        _state.value = _state.value.copy(wearDetected = wearing)
                    }

                    // Serial
                    BoseProtocol.getSerialNumber()?.let { serial ->
                        _state.value = _state.value.copy(serialNumber = serial)
                    }

                    // Platform
                    BoseProtocol.getPlatform()?.let { plat ->
                        _state.value = _state.value.copy(platform = plat)
                    }

                    // Codename
                    BoseProtocol.getCodename()?.let { cn ->
                        _state.value = _state.value.copy(codename = cn)
                    }

                    // Codec
                    BoseProtocol.getAudioCodec()?.let { codec ->
                        _state.value = _state.value.copy(
                            codecName = BoseProtocol.codecName(codec.codecId),
                            codecBitrate = codec.bitrate,
                        )
                    }

                    // Product name
                    BoseProtocol.getProductName()?.let { pn ->
                        _state.value = _state.value.copy(productName = pn)
                    }

                    // EQ
                    BoseProtocol.getEq()?.let { eq ->
                        _state.value = _state.value.copy(
                            eqBass = eq.bass.value,
                            eqMid = eq.mid.value,
                            eqTreble = eq.treble.value,
                        )
                    }

                    // Immersion
                    BoseProtocol.getImmersionLevel()?.let { imm ->
                        _state.value = _state.value.copy(immersionLevel = imm)
                    }
                }
                _state.value = _state.value.copy(loading = false)
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
                val mac = BoseProtocol.DEVICES[name] ?: return@launch
                BoseProtocol.withConnection {
                    BoseProtocol.connectDevice(mac)
                }
                // Refresh to get updated state
                refreshAll()
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    loading = false,
                    error = "Failed to switch to $name: ${e.message}",
                )
            }
        }
    }

    fun setAncMode(mode: BoseProtocol.AncMode) {
        viewModelScope.launch {
            try {
                BoseProtocol.withConnection {
                    BoseProtocol.setAncMode(mode)
                }
                _state.value = _state.value.copy(ancMode = mode)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "Failed to set ANC: ${e.message}",
                )
            }
        }
    }

    fun setVolume(level: Int) {
        viewModelScope.launch {
            try {
                BoseProtocol.withConnection {
                    BoseProtocol.setVolume(level)
                }
                _state.value = _state.value.copy(volume = level)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "Failed to set volume: ${e.message}",
                )
            }
        }
    }

    fun setDeviceName(name: String) {
        viewModelScope.launch {
            try {
                BoseProtocol.withConnection {
                    BoseProtocol.setDeviceName(name)
                }
                _state.value = _state.value.copy(deviceName = name)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "Failed to set name: ${e.message}",
                )
            }
        }
    }

    fun setMultipoint(enabled: Boolean) {
        viewModelScope.launch {
            try {
                BoseProtocol.withConnection {
                    BoseProtocol.setMultipoint(enabled)
                }
                _state.value = _state.value.copy(multipointEnabled = enabled)
            } catch (e: Exception) {
                _state.value = _state.value.copy(
                    error = "Failed to set multipoint: ${e.message}",
                )
            }
        }
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
