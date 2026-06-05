"""Emit the Swift BMAP wire layer from the parsed bmap.toml spec.

Produces:
  - `enum BMAPOperator: UInt8`         — the operator codes
  - `enum <Name>: UInt8`               — one per value enum (AncMode, EqBand, ...)
  - `enum BMAP { static func ... }`    — a builder per non-composite command action

Composites (`composite = true`) are skipped — they're hand-written per-platform
read-modify-write / response-parse helpers that call these generated primitives.
"""

from codegen.model import Operator, named_args, parse_token, payload_len

# BMAP operator name (TOML) -> Swift enum case name (lowerCamel).
_OP_CASE = {
    "GET": "get",
    "SET_GET": "setGet",
    "RESP": "resp",
    "ERROR": "error",
    "START": "start",
    "SET": "set",
    "ACK": "ack",
}

# Encoder type -> Swift parameter type.
_SWIFT_TYPE = {"u8": "UInt8", "i8": "Int8", "mac": "[UInt8]"}


def _hex(b: int) -> str:
    return f"0x{b:02X}"


def _camel(*parts: str) -> str:
    """Join snake_case parts into lowerCamelCase: ('anc','mode') -> 'ancMode'."""
    words: list[str] = []
    for p in parts:
        words.extend(p.split("_"))
    head, *tail = [w for w in words if w]
    return head + "".join(w[:1].upper() + w[1:] for w in tail)


def _func_name(action: str, cmd_name: str) -> str:
    """Builder name: action verb + command name, avoiding a doubled verb.

    e.g. ('set','anc_mode') -> setAncMode; ('connect','connect_device') ->
    connectDevice (not connectConnectDevice); ('media','media_control') ->
    mediaControl.
    """
    verbs = {"set": "set", "get": "get", "media": "media"}
    verb = verbs.get(action, action)
    # If the command name already begins with this verb, don't repeat it.
    if cmd_name == verb or cmd_name.startswith(verb + "_"):
        return _camel(cmd_name)
    return _camel(verb, cmd_name)


def _emit_operator_enum() -> str:
    lines = ["enum BMAPOperator: UInt8 {"]
    for op in Operator:
        lines.append(f"    case {_OP_CASE[op.name]} = {_hex(int(op))}")
    lines.append("}")
    return "\n".join(lines)


def _emit_value_enum(name: str, members: dict) -> str:
    lines = [f"enum {name}: UInt8 {{"]
    for case, val in members.items():
        lines.append(f"    case {case} = {val}")
    lines.append("}")
    return "\n".join(lines)


def _emit_action(cmd_name: str, cmd: dict, action: str, spec: dict) -> str:
    block = cmd["block"]
    func = cmd["function"]
    op = Operator[spec["operator"]]
    tokens = spec.get("payload", [])
    args = named_args(tokens)
    plen = payload_len(tokens)

    params = ", ".join(f"{name}: {_SWIFT_TYPE[typ]}" for name, typ in args)
    sig = f"    static func {_func_name(action, cmd_name)}({params}) -> [UInt8] {{"

    # Frame prefix: [block, function, operator, length]
    prefix = [block, func, int(op), plen]
    parts = [", ".join(_hex(b) for b in prefix)]

    for tok in tokens:
        name, typ, lit = parse_token(tok)
        if lit is not None:
            parts.append(_hex(lit))
        elif typ == "mac":
            # caller passes a 6-byte [UInt8]; splat in order
            parts.append(f"] + {name} + [")
        elif typ == "i8":
            parts.append(f"UInt8(bitPattern: {name})")
        else:  # u8
            parts.append(name)

    body = ", ".join(parts)
    # Tidy the mac splice: `..., ] + mac + [, ...` -> `...] + mac + [...`.
    body = body.replace(", ] + ", "] + ").replace(" + [, ", " + [")
    expr = f"[{body}]"
    # Drop any stray empty arrays left when a mac token is first/last.
    expr = expr.replace("[] + ", "").replace(" + []", "")
    return f"{sig}\n        return {expr}\n    }}"


def emit_swift(spec: dict) -> str:
    out: list[str] = []
    out.append("import Foundation")
    out.append("")
    out.append(_emit_operator_enum())
    out.append("")

    for name, members in spec.get("enums", {}).items():
        out.append(_emit_value_enum(name, members))
        out.append("")

    out.append("enum BMAP {")
    actions = []
    for cmd_name, cmd in spec["commands"].items():
        if cmd.get("composite"):
            continue
        for key, val in cmd.items():
            if isinstance(val, dict) and "operator" in val:
                actions.append(_emit_action(cmd_name, cmd, key, val))
    out.append("\n\n".join(actions))
    out.append("}")
    return "\n".join(out) + "\n"
