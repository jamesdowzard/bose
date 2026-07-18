package au.com.jd.bose

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context

/**
 * Does THIS phone currently hold one of the headphones' two multipoint slots?
 *
 * Public-API check via the A2DP profile proxy's connected-device list — zero
 * radio, the Android sibling of the Mac CLI's `Transport.isHeadphoneConnected()`
 * (#148). A held (idle) slot still reports the A2DP profile "connected", so this
 * is true for both the active sink and the held device — exactly the set for
 * which an RFCOMM read is cheap and safe. When false, an RFCOMM read would PAGE
 * the headphones over BT Classic (slow + the audio-glitch probe class the
 * transport rules warn about) — callers serve `StateCache` instead.
 *
 * The proxy binds asynchronously; `awaitHoldsSlot()` bounds the cold-start wait
 * and returns null when genuinely unknown (adapter off / proxy unavailable /
 * permission denied) — callers treat null as "allow live" so behaviour is never
 * worse than before the gate existed.
 */
object SlotGate {
    @Volatile private var proxy: BluetoothA2dp? = null
    @Volatile private var requested = false

    fun ensureInit(context: Context) {
        if (requested) return
        requested = true
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        adapter.getProfileProxy(
            context.applicationContext,
            object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, p: BluetoothProfile) {
                    if (profile == BluetoothProfile.A2DP) proxy = p as BluetoothA2dp
                }
                override fun onServiceDisconnected(profile: Int) {
                    if (profile == BluetoothProfile.A2DP) { proxy = null; requested = false }
                }
            },
            BluetoothProfile.A2DP,
        )
    }

    /** null = unknown (proxy not bound / permission missing). */
    fun holdsSlot(): Boolean? = try {
        proxy?.connectedDevices?.any { it.address.equals(Headphone.MAC, ignoreCase = true) }
    } catch (_: SecurityException) {
        null
    }

    /** Bounded wait for the async proxy bind (typically <100 ms after first init). */
    fun awaitHoldsSlot(context: Context, timeoutMs: Long = 700): Boolean? {
        ensureInit(context)
        val deadline = System.currentTimeMillis() + timeoutMs
        while (proxy == null && System.currentTimeMillis() < deadline) Thread.sleep(25)
        return holdsSlot()
    }
}
