package au.com.jd.bose

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The widget's pure paint seams. A cached snapshot must announce its age on the battery
 * chip — without the suffix an hours-old snapshot paints exactly like a live read.
 */
class BoseWidgetProviderTest {

    @Test fun liveReadHasNoSuffix() =
        assertEquals("82%", BoseWidgetProvider.batteryText(82, null))

    @Test fun cachedSnapshotCarriesAge() =
        assertEquals("82% · 12m", BoseWidgetProvider.batteryText(82, 750))

    /** Same vocabulary as the in-app banner — both go through StateCache.ageText. */
    @Test fun cachedSuffixUsesSharedAgeFormatter() {
        assertEquals("40% · 45s", BoseWidgetProvider.batteryText(40, 45))
        assertEquals("40% · 2h 5m", BoseWidgetProvider.batteryText(40, 7500))
    }

    @Test fun snapshotAgeIsWholeSecondsSinceCapture() =
        assertEquals(90, BoseWidgetProvider.snapshotAge(1_000_000L, 1_090_400L))

    /** A clock that went backwards must not produce a negative age. */
    @Test fun snapshotAgeNeverNegative() =
        assertEquals(0, BoseWidgetProvider.snapshotAge(2_000_000L, 1_000_000L))
}
