package au.com.jd.bose

/**
 * Bridges between the two byte representations used in this app:
 *  - `ByteArray`  — the canonical paired-device MAC identity (from the generated
 *    `BoseDeviceMap`) and what Android's Bluetooth APIs hand back.
 *  - `IntArray` (0..255) — the wire-frame representation the generated `BMAP`
 *    builders, `Transport`, and the pure `Parsers` operate on.
 */

/** ByteArray (signed) -> IntArray of unsigned 0..255 values. */
fun ByteArray.toIntArray(): IntArray = IntArray(size) { this[it].toInt() and 0xFF }

/** IntArray of 0..255 values -> ByteArray (signed two's-complement). */
fun IntArray.toByteArray(): ByteArray = ByteArray(size) { this[it].toByte() }
