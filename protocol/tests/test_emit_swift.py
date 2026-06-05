import pathlib
import tomllib

from codegen.emit_swift import emit_swift

SPEC = tomllib.loads(
    (pathlib.Path(__file__).parent.parent / "spec/bmap.toml").read_text()
)


def test_emits_anc_enum_and_builder():
    src = emit_swift(SPEC)
    assert "enum AncMode: UInt8" in src
    assert "case quiet = 0" in src
    assert "static func setAncMode(" in src
    assert "[0x1F, 0x03, 0x05," in src  # frame prefix present


def test_emits_operator_enum():
    src = emit_swift(SPEC)
    assert "enum BMAPOperator: UInt8" in src
    assert "case setGet = 0x02" in src


def test_emits_volume_set_get_builder_with_correct_operator():
    src = emit_swift(SPEC)
    assert "static func setVolume(" in src
    # volume builder must carry the SET_GET (0x02) operator byte — v1-bug regression lock
    assert "[0x05, 0x05, 0x02," in src


def test_skips_composites():
    src = emit_swift(SPEC)
    # composites are hand-written per-platform — no generated builder
    assert "cncLevel" not in src
    assert "connectedDevices" not in src


def test_emits_namespace():
    src = emit_swift(SPEC)
    assert "enum BMAP {" in src
