import pathlib
import tomllib

from codegen.emit_kotlin import emit_kotlin

SPEC = tomllib.loads(
    (pathlib.Path(__file__).parent.parent / "spec/bmap.toml").read_text()
)


def test_emits_anc_enum_and_builder():
    src = emit_kotlin(SPEC)
    assert "enum class AncMode(val v: Int)" in src
    assert "QUIET(0)" in src
    assert "fun setAncMode(" in src
    assert "0x1F, 0x03, 0x05," in src  # frame prefix present


def test_emits_operator_enum():
    src = emit_kotlin(SPEC)
    assert "enum class BMAPOperator(val v: Int)" in src
    assert "SET_GET(0x02)" in src


def test_emits_volume_set_get_builder_with_correct_operator():
    src = emit_kotlin(SPEC)
    assert "fun setVolume(" in src
    assert "0x05, 0x05, 0x02," in src  # SET_GET operator byte — v1-bug regression lock


def test_skips_composites():
    src = emit_kotlin(SPEC)
    assert "cncLevel" not in src
    assert "connectedDevices" not in src


def test_emits_object_namespace():
    src = emit_kotlin(SPEC)
    assert "object BMAP {" in src
