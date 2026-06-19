// DO NOT EDIT — generated from bmap.toml
// Source of truth: protocol/spec/bmap.toml — regenerate with `make gen`.
// Composite commands (cnc_level, connected_devices) are hand-written.

package au.com.jd.bose

enum class BMAPOperator(val v: Int) { GET(0x01), SET_GET(0x02), RESP(0x03), ERROR(0x04), START(0x05), SET(0x06), ACK(0x07) }

enum class AncMode(val v: Int) { QUIET(0), AWARE(1), IMMERSION(2), CINEMA(3), CUSTOM1(4), CUSTOM2(5), OFF(255) }
enum class EqBand(val v: Int) { BASS(0), MID(1), TREBLE(2) }
enum class MediaAction(val v: Int) { PLAY(1), PAUSE(2), NEXT(3), PREV(4) }

object BMAP {
    fun setAncMode(mode: Int): IntArray {
        return intArrayOf(0x1F, 0x03, 0x05, 0x02, (mode and 0xFF), 0x01)
    }

    fun getAncMode(): IntArray {
        return intArrayOf(0x1F, 0x03, 0x01, 0x00)
    }

    fun getFavorites(): IntArray {
        return intArrayOf(0x1F, 0x08, 0x01, 0x00)
    }

    fun setDeviceName(): IntArray {
        return intArrayOf(0x01, 0x02, 0x06, 0x00)
    }

    fun setEqBand(value: Int, band: Int): IntArray {
        return intArrayOf(0x01, 0x07, 0x02, 0x02, (value and 0xFF), (band and 0xFF))
    }

    fun getEqBand(): IntArray {
        return intArrayOf(0x01, 0x07, 0x01, 0x00)
    }

    fun setMultipoint(state: Int): IntArray {
        return intArrayOf(0x01, 0x0A, 0x02, 0x01, (state and 0xFF))
    }

    fun getMultipoint(): IntArray {
        return intArrayOf(0x01, 0x0A, 0x01, 0x00)
    }

    fun setAutoPlayPause(enabled: Int): IntArray {
        return intArrayOf(0x01, 0x18, 0x02, 0x01, (enabled and 0xFF))
    }

    fun getAutoPlayPause(): IntArray {
        return intArrayOf(0x01, 0x18, 0x01, 0x00)
    }

    fun setAutoAnswer(enabled: Int): IntArray {
        return intArrayOf(0x01, 0x1B, 0x02, 0x01, (enabled and 0xFF))
    }

    fun getAutoAnswer(): IntArray {
        return intArrayOf(0x01, 0x1B, 0x01, 0x00)
    }

    fun connectDevice(mac: IntArray): IntArray {
        return intArrayOf(0x04, 0x01, 0x05, 0x07, 0x00) + mac
    }

    fun disconnectDevice(mac: IntArray): IntArray {
        return intArrayOf(0x04, 0x02, 0x05, 0x06) + mac
    }

    fun getDeviceInfo(mac: IntArray): IntArray {
        return intArrayOf(0x04, 0x05, 0x01, 0x06) + mac
    }

    fun mediaControl(action: Int): IntArray {
        return intArrayOf(0x05, 0x03, 0x05, 0x01, (action and 0xFF))
    }

    fun getAudioCodec(): IntArray {
        return intArrayOf(0x05, 0x04, 0x01, 0x00)
    }

    fun setVolume(level: Int): IntArray {
        return intArrayOf(0x05, 0x05, 0x02, 0x01, (level and 0xFF))
    }

    fun getVolume(): IntArray {
        return intArrayOf(0x05, 0x05, 0x01, 0x00)
    }

    fun getFirmware(): IntArray {
        return intArrayOf(0x00, 0x05, 0x01, 0x00)
    }

    fun getBattery(): IntArray {
        return intArrayOf(0x02, 0x02, 0x01, 0x00)
    }
}
