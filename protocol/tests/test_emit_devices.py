import pathlib
import tomllib

from codegen.emit_devices import emit_devices_swift

SPEC = tomllib.loads(
    (pathlib.Path(__file__).parent.parent / "spec" / "devices.toml").read_text()
)


def test_emits_headphone_mac_and_name():
    src = emit_devices_swift(SPEC)
    # Headphone MAC in IOBluetooth dash format + colon format.
    assert 'static let mac = "E4:58:BC:C0:2F:72"' in src
    assert 'static let dashMac = "E4-58-BC-C0-2F-72"' in src
    assert 'static let name = "verBosita"' in src


def test_emits_device_list_with_mac_bytes():
    src = emit_devices_swift(SPEC)
    # The known-devices list carries name + 6-byte MAC arrays.
    assert "struct BoseDevice" in src
    assert "let knownDevices: [BoseDevice]" in src
    # mac device bytes BC:D0:74:11:DB:27 -> [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27]
    assert "0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27" in src
    assert '"mac"' in src


def test_emits_cycle_order():
    src = emit_devices_swift(SPEC)
    # mac -> quest -> ipad -> iphone -> tv -> appletv -> phone
    assert (
        'static let cycleOrder = ["mac", "quest", "ipad", "iphone", "tv", "appletv", "phone"]'
        in src
    )


def test_emits_optional_label_field():
    src = emit_devices_swift(SPEC)
    # BoseDevice carries an optional friendly label.
    assert "let label: String?" in src
    # appletv has a friendly label; devices without one emit nil.
    assert 'label: "Katrina\'s Apple TV"' in src
    assert "label: nil" in src


def test_emits_priority_field():
    src = emit_devices_swift(SPEC)
    assert "let priority: Int" in src
    assert "priority: 1)" in src  # mac — highest priority
    assert "priority: 2)" in src  # phone
