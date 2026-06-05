import pathlib

from codegen import generate

GEN_DIR = pathlib.Path(__file__).parent.parent / "generated"
BANNER = "DO NOT EDIT — generated from bmap.toml"
DEVICES_BANNER = "DO NOT EDIT — generated from devices.toml"


def test_generate_writes_all_files(tmp_path):
    swift, kotlin, devices, devices_kt = generate.run(out_dir=tmp_path)
    assert swift.exists() and kotlin.exists()
    assert devices.exists() and devices_kt.exists()
    assert swift.read_text().strip()
    assert kotlin.read_text().strip()
    assert devices.read_text().strip()
    assert devices_kt.read_text().strip()


def test_generated_files_carry_banner(tmp_path):
    swift, kotlin, devices, devices_kt = generate.run(out_dir=tmp_path)
    assert BANNER in swift.read_text()
    assert BANNER in kotlin.read_text()
    assert DEVICES_BANNER in devices.read_text()
    assert DEVICES_BANNER in devices_kt.read_text()


def test_generated_files_contain_known_symbols(tmp_path):
    swift, kotlin, devices, devices_kt = generate.run(out_dir=tmp_path)
    s, k, d, dk = (
        swift.read_text(),
        kotlin.read_text(),
        devices.read_text(),
        devices_kt.read_text(),
    )
    assert "static func setVolume(" in s
    assert "enum AncMode: UInt8" in s
    assert "fun setVolume(" in k
    assert "object BMAP {" in k
    assert "enum BoseDeviceMap {" in d
    assert 'static let mac = "E4:58:BC:C0:2F:72"' in d
    assert "object BoseDeviceMap {" in dk
    assert 'const val MAC = "E4:58:BC:C0:2F:72"' in dk
    assert "package au.com.jd.bose" in dk


def test_committed_generated_files_are_in_sync():
    # The checked-in generated/ must match a fresh render of the current spec.
    spec = generate.load_spec()
    devices = generate.load_devices()
    from codegen.emit_devices import emit_devices_kotlin, emit_devices_swift
    from codegen.emit_kotlin import emit_kotlin
    from codegen.emit_swift import emit_swift

    swift_path = GEN_DIR / "BMAP.generated.swift"
    kotlin_path = GEN_DIR / "BMAP.generated.kt"
    devices_path = GEN_DIR / "Devices.generated.swift"
    devices_kt_path = GEN_DIR / "Devices.generated.kt"
    assert swift_path.read_text() == generate.with_banner(emit_swift(spec), "swift")
    assert kotlin_path.read_text() == generate.with_banner(emit_kotlin(spec), "kotlin")
    assert devices_path.read_text() == generate.with_devices_banner(
        emit_devices_swift(devices), "swift"
    )
    assert devices_kt_path.read_text() == generate.with_devices_banner(
        emit_devices_kotlin(devices), "kotlin"
    )
