package au.com.jd.bose

import android.content.Context

/**
 * Timestamped last-good status snapshot — the Android sibling of the Mac's
 * `~/.cache/bose/state-<MAC>.json` (#148). Written on every successful live
 * refresh; served (stamped with age) when the phone holds neither multipoint
 * slot, so the widget and app paint instantly and radio-silently instead of
 * paging the headphones. SharedPrefs-backed: this is presentation state, small
 * and flat, and prefs survive process death exactly as long as we need.
 */
object StateCache {
    private const val PREFS = "bose_state_cache"

    data class Cached(
        val active: String?,
        val connected: Set<String>,
        val battery: Int,          // -1 = unknown
        val charging: Boolean,
        val savedAtMs: Long,
    ) {
        fun ageSeconds(nowMs: Long = System.currentTimeMillis()): Int =
            ((nowMs - savedAtMs) / 1000).coerceAtLeast(0).toInt()
    }

    fun save(context: Context, active: String?, connected: Set<String>, battery: Int, charging: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("active", active)
            .putStringSet("connected", connected)
            .putInt("battery", battery)
            .putBoolean("charging", charging)
            .putLong("saved_at", System.currentTimeMillis())
            .apply()
    }

    fun load(context: Context): Cached? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val savedAt = p.getLong("saved_at", 0L)
        if (savedAt == 0L) return null
        return Cached(
            active = p.getString("active", null),
            connected = p.getStringSet("connected", emptySet()) ?: emptySet(),
            battery = p.getInt("battery", -1),
            charging = p.getBoolean("charging", false),
            savedAtMs = savedAt,
        )
    }

    /** "45s" / "12m" / "2h 5m" — pure (JVM-unit-tested), shared by widget + app. */
    fun ageText(ageSeconds: Int): String = when {
        ageSeconds < 60 -> "${ageSeconds}s"
        ageSeconds < 3600 -> "${ageSeconds / 60}m"
        else -> "${ageSeconds / 3600}h ${(ageSeconds % 3600) / 60}m"
    }
}
