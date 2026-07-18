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
        // Auto-pause (01,18) — pause when removed; Auto-answer (01,1B) — answer call when donned.
        val autoPlayPause: Boolean = false,
        val autoAnswer: Boolean = false,
        // Favourited mode slots (1F,08) — display-only, mirroring the Mac app.
        val favorites: List<Int> = emptyList(),
        // Noise level (1F,06) — the active mode's CNC level + whether it's adjustable
        // (firmware cncMutable: only the custom slots 4/5). modeName labels the hint.
        val noiseLevel: Int = 0,
        val noiseAdjustable: Boolean = false,
        val modeName: String = "",
        // Immersive Audio (1F,06 spatial byte): 0 = off, 1 = Still, 2 = Motion. Adjustable
        // only where the firmware spatialMutable bit is set (the custom slots 4/5); named
        // modes carry it fixed (Immersion = Motion, Cinema = Still).
        val spatial: Int = 0,
        val spatialAdjustable: Boolean = false,
        // Stored names of the two custom slots (set via the CLI `mode-name`). Empty when
        // unset ("None") — the C1/C2 buttons fall back to "C1"/"C2".
        val custom1Name: String = "",
        val custom2Name: String = "",
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

        // Cached-first (#148 parity): reachable = this phone holds a multipoint
        // slot right now; false while painting the StateCache snapshot (drives the
        // staleness banner). stateAgeSeconds = the painted snapshot's age.
        val reachable: Boolean = true,
        val stateAgeSeconds: Int? = null,

        // UI
        val loading: Boolean = false,
        val error: String? = null,
        val settingsExpanded: Boolean = false,
        val infoExpanded: Boolean = false,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    fun refreshAll(forceLive: Boolean = false) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            // Cached-first: with neither slot held, an RFCOMM read would page the
            // headphones — paint the cached snapshot instead (instant, zero radio).
            // The banner's Read-live button passes forceLive; an unknown gate (null,
            // proxy not bound) falls through to live, matching pre-gate behaviour.
            if (!forceLive && SlotGate.awaitHoldsSlot(getApplication()) == false) {
                val cached = StateCache.load(getApplication())
                val cur = _state.value
                _state.value = cur.copy(
                    loading = false,
                    reachable = false,
                    stateAgeSeconds = cached?.ageSeconds(),
                    batteryLevel = cached?.battery?.takeIf { it >= 0 } ?: cur.batteryLevel,
                    batteryCharging = cached?.charging ?: cur.batteryCharging,
                    deviceStates = if (cached == null) cur.deviceStates
                    else BoseDeviceMap.knownDevices.associate { device ->
                        device.name to when {
                            device.name == cached.active -> DeviceState.ACTIVE
                            cached.connected.contains(device.name) -> DeviceState.CONNECTED
                            else -> DeviceState.OFFLINE
                        }
                    },
                )
                return@launch
            }
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
                    BoseProtocol.getAutoPlayPause()?.let { s = s.copy(autoPlayPause = it) }
                    BoseProtocol.getAutoAnswer()?.let { s = s.copy(autoAnswer = it) }
                    BoseProtocol.getFavorites()?.let { s = s.copy(favorites = it) }
                    Composites.readActiveModeConfig()?.let {
                        s = s.copy(noiseLevel = it.cncLevel, noiseAdjustable = it.cncMutable, modeName = it.displayName,
                            spatial = it.spatial, spatialAdjustable = it.spatialMutable)
                    }
                    Composites.readCustomModeNames().let { names ->
                        fun clean(n: String?) = n?.takeIf { it != "None" } ?: ""
                        s = s.copy(custom1Name = clean(names[4]), custom2Name = clean(names[5]))
                    }
                    BoseProtocol.getAutoOffTimer()?.let { s = s.copy(autoOffTimer = BoseProtocol.autoOffTimerDescription(it)) }
                    BoseProtocol.getSerialNumber()?.let { s = s.copy(serialNumber = it) }
                    BoseProtocol.getPlatform()?.let { s = s.copy(platform = it) }
                    BoseProtocol.getCodename()?.let { s = s.copy(codename = it) }
                    BoseProtocol.getAudioCodec()?.let { s = s.copy(codecName = BoseProtocol.codecName(it.codecId), codecBitrate = it.bitrate) }
                    BoseProtocol.getProductName()?.let { s = s.copy(productName = it) }
                    BoseProtocol.getEq()?.let { s = s.copy(eqBass = it.bass.value, eqMid = it.mid.value, eqTreble = it.treble.value) }
                    BoseProtocol.getImmersionLevel()?.let { s = s.copy(immersionLevel = it) }

                    // Live read landed: persist the snapshot for the gated path
                    // (widget + next no-slot open paint from it).
                    val active = s.deviceStates.entries.firstOrNull { it.value == DeviceState.ACTIVE }?.key
                    val held = s.deviceStates.filterValues { it == DeviceState.CONNECTED }.keys
                    StateCache.save(getApplication(), active, held, s.batteryLevel, s.batteryCharging)

                    // Single emission — one recomposition instead of 18
                    _state.value = s.copy(loading = false, reachable = true, stateAgeSeconds = null)
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
                        spatial = cfg.spatial,
                        spatialAdjustable = cfg.spatialMutable,
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

    /** Pause playback when the headphones are removed (01,18, SET_GET). Optimistic + refresh. */
    fun setAutoPlayPause(enabled: Boolean) = command("Failed to set auto-pause",
        action = { BoseProtocol.setAutoPlayPause(enabled) },
        onSuccess = { _state.value = _state.value.copy(autoPlayPause = enabled) },
    )

    /** Answer an incoming call when the headphones are donned (01,1B, SET_GET). Optimistic + refresh. */
    fun setAutoAnswer(enabled: Boolean) = command("Failed to set auto-answer",
        action = { BoseProtocol.setAutoAnswer(enabled) },
        onSuccess = { _state.value = _state.value.copy(autoAnswer = enabled) },
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

    /**
     * Set the active mode's Immersive Audio (spatial) mode via the 1F,06 RMW. No-op on a
     * fixed mode (the control is disabled there anyway, and `setActiveModeSpatial` refuses).
     * spatial: 0 = off, 1 = Still, 2 = Motion.
     */
    fun setSpatial(spatial: Int) {
        if (!_state.value.spatialAdjustable) return
        command("Failed to set Immersive Audio",
            action = { Composites.setActiveModeSpatial(spatial) },
            onSuccess = { _state.value = _state.value.copy(spatial = spatial) },
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
