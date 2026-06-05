import pathlib
import tomllib

from codegen.model import Operator, build_frame, encode_payload

SPEC = tomllib.loads(
    (pathlib.Path(__file__).parent.parent / "spec/bmap.toml").read_text()
)


def _bytes(s):
    return [int(x, 16) for x in s.split()]


def test_every_verified_capture_matches():
    checked = 0
    for name, cmd in SPEC["commands"].items():
        for label, expected_hex in cmd.get("verified_bytes", {}).items():
            # label like "set_quiet" -> action "set"; "get" -> action "get"
            action, *_ = label.split("_", 1)
            block, func = cmd["block"], cmd["function"]
            spec_action = cmd[action]
            op = Operator[spec_action["operator"]]
            args = cmd.get("test_args", {}).get(label, {})
            frame = build_frame(
                block, func, op, encode_payload(spec_action.get("payload", []), args)
            )
            assert frame == _bytes(expected_hex), f"{name}.{label}"
            checked += 1
    assert checked > 0


def test_volume_uses_set_get_not_set():
    # Regression lock for the v1 bug: setVolume must emit SET_GET (0x02), never SET (0x06).
    vol = SPEC["commands"]["volume"]
    assert vol["set"]["operator"] == "SET_GET"
    frame = build_frame(
        vol["block"],
        vol["function"],
        Operator[vol["set"]["operator"]],
        encode_payload(vol["set"]["payload"], {"level": 15}),
    )
    assert frame[2] == 0x02  # operator byte is SET_GET, not 0x06


def test_composites_have_no_builder_actions_required():
    # Composites are hand-written per-platform; they may omit action sub-tables.
    composites = [n for n, c in SPEC["commands"].items() if c.get("composite")]
    assert "cnc_level" in composites
    assert "connected_devices" in composites
