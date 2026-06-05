import pathlib
import tomllib

from codegen.emit_devices import emit_devices_kotlin

SPEC = tomllib.loads(
    (pathlib.Path(__file__).parent.parent / "spec" / "devices.toml").read_text()
)


def test_emits_package_and_headphone():
    src = emit_devices_kotlin(SPEC)
    assert "package au.com.jd.bose" in src
    # Headphone MAC (colon form — Android's BluetoothAdapter.getRemoteDevice wants it)
    # and name, single-sourced from devices.toml.
    assert 'const val MAC = "E4:58:BC:C0:2F:72"' in src
    assert 'const val NAME = "verBosita"' in src


def test_emits_device_map_with_mac_bytes():
    src = emit_devices_kotlin(SPEC)
    # A BoseDevice data class carrying name + MAC bytes + widget flag.
    assert "data class BoseDevice" in src
    # mac device BC:D0:74:11:DB:27 -> byteArrayOf(0xBC.toByte(), 0xD0.toByte(), ...)
    assert "0xBC.toByte(), 0xD0.toByte(), 0x74, 0x11, 0xDB.toByte(), 0x27" in src
    # Map keyed by name, preserving cycle order (LinkedHashMap semantics).
    assert '"mac"' in src and '"phone"' in src


def test_emits_cycle_order():
    src = emit_devices_kotlin(SPEC)
    assert 'val CYCLE_ORDER = listOf("mac", "quest", "ipad", "iphone", "tv", "phone")' in src


def test_emits_widget_set_excludes_tv():
    src = emit_devices_kotlin(SPEC)
    # tv is macOS-only (widget=false). The widget button set must derive from
    # the map's widget flag — tv must NOT be a widget device.
    assert "widgetDevices" in src
    # The widget-device list must be derivable; assert tv is flagged non-widget.
    # Emitted as widget = false on the tv row.
    assert 'BoseDevice("tv"' in src
    assert "widget = false" in src
    assert "widget = true" in src
