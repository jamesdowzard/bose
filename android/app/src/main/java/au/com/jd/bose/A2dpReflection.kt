package au.com.jd.bose

import android.annotation.SuppressLint
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.util.Log

/**
 * The single, isolated home for the hidden-API A2DP `connect()` reflection hack.
 *
 * `BluetoothA2dp.connect(BluetoothDevice)` is a hidden/@SystemApi method with no
 * public equivalent. Samsung's BT stack sometimes leaves A2DP un-connected after a
 * BMAP `connectDevice` routes audio to the phone, so we reflectively poke it to
 * force the profile up. This is OEM-fragile and deliberately quarantined here:
 *
 *   - It is invoked from EXACTLY ONE place: BoseService's "switch to phone" path.
 *   - Do NOT expand its use to other devices or other profiles (HFP is forbidden —
 *     SCO blocks A2DP streaming; see CLAUDE.md "HFP blocks A2DP").
 *   - Do NOT call it on every ACL reconnect — that fought user switches (#61-#64)
 *     and the old aclReceiver was removed for exactly that reason.
 *
 * Failure is non-fatal and swallowed: if the hidden method vanishes on a future
 * Android, audio still routes (just without the insurance nudge).
 */
object A2dpReflection {

    private const val TAG = "A2dpReflection"

    /**
     * Reflectively call `BluetoothA2dp.connect(device)` on the given proxy.
     * Returns the method's Boolean result, or false if reflection failed.
     */
    @SuppressLint("MissingPermission")
    fun connect(proxy: BluetoothA2dp, device: BluetoothDevice): Boolean {
        return try {
            val method = BluetoothA2dp::class.java
                .getMethod("connect", BluetoothDevice::class.java)
            val result = method.invoke(proxy, device) as? Boolean ?: false
            Log.i(TAG, "A2DP connect (hidden API) result: $result")
            result
        } catch (e: Exception) {
            Log.w(TAG, "A2DP connect reflection failed (non-fatal): ${e.message}")
            false
        }
    }
}
