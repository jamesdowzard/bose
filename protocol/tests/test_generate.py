import pathlib

from codegen import generate

GEN_DIR = pathlib.Path(__file__).parent.parent / "generated"
BANNER = "DO NOT EDIT — generated from bmap.toml"


def test_generate_writes_both_files(tmp_path):
    swift, kotlin = generate.run(out_dir=tmp_path)
    assert swift.exists() and kotlin.exists()
    assert swift.read_text().strip()
    assert kotlin.read_text().strip()


def test_generated_files_carry_banner(tmp_path):
    swift, kotlin = generate.run(out_dir=tmp_path)
    assert BANNER in swift.read_text()
    assert BANNER in kotlin.read_text()


def test_generated_files_contain_known_symbols(tmp_path):
    swift, kotlin = generate.run(out_dir=tmp_path)
    s, k = swift.read_text(), kotlin.read_text()
    assert "static func setVolume(" in s
    assert "enum AncMode: UInt8" in s
    assert "fun setVolume(" in k
    assert "object BMAP {" in k


def test_committed_generated_files_are_in_sync():
    # The checked-in generated/ must match a fresh render of the current spec.
    spec = generate.load_spec()
    from codegen.emit_kotlin import emit_kotlin
    from codegen.emit_swift import emit_swift

    swift_path = GEN_DIR / "BMAP.generated.swift"
    kotlin_path = GEN_DIR / "BMAP.generated.kt"
    assert swift_path.read_text() == generate.with_banner(emit_swift(spec), "swift")
    assert kotlin_path.read_text() == generate.with_banner(emit_kotlin(spec), "kotlin")
