"""Bind the EMITTED Swift/Kotlin builders to the verified_bytes captures.

Why this file exists
--------------------
`test_golden.py` proves the SPEC is self-consistent: it rebuilds each frame with
`codegen.model.build_frame` + `encode_payload` and compares to `verified_bytes`. But the
emitters do NOT call those helpers — `emit_swift.py` / `emit_kotlin.py` construct the
literal array themselves (their own prefix list, their own length byte, plus string
surgery to splice a trailing MAC, e.g. `.replace(", ] + ", "] + ")`). So the two paths
are independent implementations of the same framing, and nothing compared them.

A regression in that surgery, or a wrong `plen` in `_emit_action`, would ship a malformed
connect frame with every existing test green. This closes that: it parses the CONSTANT
bytes out of each generated builder and asserts them against the same live capture the
spec is checked against.

Constants only, deliberately: block, function, operator and the length byte are baked in
by the emitter and are exactly what can silently rot. Value bytes (mode, level, band, the
MAC) are supplied by the caller at runtime, so they can't be wrong *in the emitter* —
they're covered by `test_golden.py`. A `+ mac` tail is checked for arity instead (the
capture must have exactly 6 bytes left), which is what the splice would break.
"""

import pathlib
import re

import tomllib

from codegen.emit_swift import _func_name

ROOT = pathlib.Path(__file__).parent.parent
SPEC = tomllib.loads((ROOT / "spec/bmap.toml").read_text())

SWIFT = (ROOT / "generated/BMAP.generated.swift").read_text()
KOTLIN = (ROOT / "generated/BMAP.generated.kt").read_text()

# Swift emits `return [0x1F, ...]`; Kotlin `return intArrayOf(0x1F, ...)`. Kotlin wraps
# value args in parens — `(mode and 0xFF)` — so the element list can't be matched with a
# naive `[^)]*`; it's extracted with a balanced scan below.
_SWIFT = ("static func {fn}(", "return [", "[", "]")
_KOTLIN = ("fun {fn}(", "return intArrayOf(", "(", ")")


def _capture(hex_str):
    return [int(x, 16) for x in hex_str.split()]


def _split_top_level(s):
    """Split on commas that are NOT inside brackets/parens."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return [t for t in out if t]


def _emitted(source, lang, fn):
    sig, ret, opener, closer = lang
    i = source.find(sig.format(fn=fn))
    assert i != -1, f"no generated builder named {fn}"
    j = source.find(ret, i)
    assert j != -1, f"{fn}: no return expression found"
    k = j + len(ret)                      # first char after the opening delimiter
    depth, start = 1, k
    while depth:                          # balanced scan to the matching close
        assert k < len(source), f"{fn}: unbalanced return expression"
        if source[k] == opener:
            depth += 1
        elif source[k] == closer:
            depth -= 1
        k += 1
    body = source[start:k - 1]
    tail = source[k:source.find("\n", k)]
    return _split_top_level(body), "+ mac" in tail.replace("  ", " ")


def _labels():
    """(command, label, expected_bytes, builder_name) for every verified capture."""
    for name, cmd in SPEC["commands"].items():
        if cmd.get("composite"):
            continue  # composites emit no builder by design
        for label, hex_str in cmd.get("verified_bytes", {}).items():
            action = label.split("_", 1)[0]
            if action not in cmd:
                continue
            yield name, label, _capture(hex_str), _func_name(action, name)


def _assert_constants(source, lang_spec, lang):
    checked = 0
    for name, label, expected, fn in _labels():
        tokens, has_mac_tail = _emitted(source, lang_spec, fn)
        where = f"{lang} {fn} ({name}.{label})"

        if has_mac_tail:
            # inline tokens are the header; the capture's remainder must be exactly a MAC
            assert len(expected) - len(tokens) == 6, (
                f"{where}: '+ mac' tail but capture leaves "
                f"{len(expected) - len(tokens)} bytes, expected 6"
            )
        else:
            assert len(tokens) == len(expected), (
                f"{where}: emits {len(tokens)} bytes, capture has {len(expected)}"
            )

        for i, tok in enumerate(tokens):
            if re.fullmatch(r"0x[0-9A-Fa-f]{2}", tok):
                assert int(tok, 16) == expected[i], (
                    f"{where}: byte {i} is {tok}, capture says 0x{expected[i]:02X}"
                )
                checked += 1
    assert checked > 0, f"{lang}: no constant bytes checked — pattern likely stale"
    return checked


def test_swift_constants_match_captures():
    assert _assert_constants(SWIFT, _SWIFT, "swift") > 0


def test_kotlin_constants_match_captures():
    assert _assert_constants(KOTLIN, _KOTLIN, "kotlin") > 0


def test_swift_and_kotlin_emit_identical_constants():
    """The two clients must not drift on any baked-in byte."""
    for _name, _label, _expected, fn in _labels():
        s_tokens, s_mac = _emitted(SWIFT, _SWIFT, fn)
        k_tokens, k_mac = _emitted(KOTLIN, _KOTLIN, fn)
        assert s_mac == k_mac, f"{fn}: '+ mac' tail differs between Swift and Kotlin"
        s_const = [t for t in s_tokens if re.fullmatch(r"0x[0-9A-Fa-f]{2}", t)]
        k_const = [t for t in k_tokens if re.fullmatch(r"0x[0-9A-Fa-f]{2}", t)]
        assert [x.upper() for x in s_const] == [x.upper() for x in k_const], (
            f"{fn}: constant bytes differ — swift {s_const} vs kotlin {k_const}"
        )
