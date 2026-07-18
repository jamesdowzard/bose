package au.com.jd.bose

import org.junit.Assert.assertEquals
import org.junit.Test

/** ageText is the shared staleness formatter (widget battery suffix + app banner). */
class StateCacheTest {
    @Test fun secondsUnderAMinute() = assertEquals("45s", StateCache.ageText(45))
    @Test fun minutesUnderAnHour() = assertEquals("12m", StateCache.ageText(750))
    @Test fun hoursAndMinutes() = assertEquals("2h 5m", StateCache.ageText(7500))
    @Test fun zeroIsSeconds() = assertEquals("0s", StateCache.ageText(0))
}
