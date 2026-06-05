"""Codegen driver: render the Swift + Kotlin BMAP wire layers from bmap.toml.

Usage:
    uv run python -m codegen.generate

Writes:
    generated/BMAP.generated.swift
    generated/BMAP.generated.kt

Both files carry a DO-NOT-EDIT banner. The committed files must stay in sync
with the spec — `make check` (git diff --exit-code) enforces that.
"""

import pathlib
import tomllib

from codegen.emit_kotlin import emit_kotlin
from codegen.emit_swift import emit_swift

_HERE = pathlib.Path(__file__).parent
_SPEC_PATH = _HERE.parent / "spec" / "bmap.toml"
_DEFAULT_OUT = _HERE.parent / "generated"

BANNER_TEXT = "DO NOT EDIT — generated from bmap.toml"

_COMMENT = {"swift": "//", "kotlin": "//"}


def load_spec() -> dict:
    return tomllib.loads(_SPEC_PATH.read_text())


def with_banner(src: str, lang: str) -> str:
    c = _COMMENT[lang]
    banner = (
        f"{c} {BANNER_TEXT}\n"
        f"{c} Source of truth: protocol/spec/bmap.toml — regenerate with `make gen`.\n"
        f"{c} Composite commands (cnc_level, connected_devices) are hand-written.\n\n"
    )
    return banner + src


def run(out_dir: pathlib.Path | None = None) -> tuple[pathlib.Path, pathlib.Path]:
    out_dir = pathlib.Path(out_dir) if out_dir else _DEFAULT_OUT
    out_dir.mkdir(parents=True, exist_ok=True)
    spec = load_spec()

    swift_path = out_dir / "BMAP.generated.swift"
    kotlin_path = out_dir / "BMAP.generated.kt"
    swift_path.write_text(with_banner(emit_swift(spec), "swift"))
    kotlin_path.write_text(with_banner(emit_kotlin(spec), "kotlin"))
    return swift_path, kotlin_path


def main() -> None:
    swift_path, kotlin_path = run()
    print(f"wrote {swift_path}")
    print(f"wrote {kotlin_path}")


if __name__ == "__main__":
    main()
