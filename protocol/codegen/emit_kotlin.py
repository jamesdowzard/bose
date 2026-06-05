"""Emit the Kotlin BMAP wire layer from the parsed bmap.toml spec.

Mirrors emit_swift. Produces:
  - `enum class BMAPOperator(val v: Int)`     — operator codes
  - `enum class <Name>(val v: Int)`           — one per value enum
  - `object BMAP { fun ...(): IntArray }`     — a builder per non-composite action

Composites (`composite = true`) are skipped — hand-written per-platform.
"""

from codegen.model import Operator, named_args, parse_token, payload_len

_OP_CASE = {
    "GET": "GET",
    "SET_GET": "SET_GET",
    "RESP": "RESP",
    "ERROR": "ERROR",
    "START": "START",
    "SET": "SET",
    "ACK": "ACK",
}

# Encoder type -> Kotlin parameter type. u8/i8 take Int (callers pass 0..255 /
# -128..127); mac takes a 6-element IntArray.
_KT_TYPE = {"u8": "Int", "i8": "Int", "mac": "IntArray"}


def _hex(b: int) -> str:
    return f"0x{b:02X}"


def _camel(*parts: str) -> str:
    words: list[str] = []
    for p in parts:
        words.extend(p.split("_"))
    head, *tail = [w for w in words if w]
    return head + "".join(w[:1].upper() + w[1:] for w in tail)


def _func_name(action: str, cmd_name: str) -> str:
    verbs = {"set": "set", "get": "get", "media": "media"}
    verb = verbs.get(action, action)
    if cmd_name == verb or cmd_name.startswith(verb + "_"):
        return _camel(cmd_name)
    return _camel(verb, cmd_name)


def _emit_operator_enum() -> str:
    cases = ", ".join(f"{_OP_CASE[op.name]}({_hex(int(op))})" for op in Operator)
    return f"enum class BMAPOperator(val v: Int) {{ {cases} }}"


def _emit_value_enum(name: str, members: dict) -> str:
    cases = ", ".join(f"{case.upper()}({val})" for case, val in members.items())
    return f"enum class {name}(val v: Int) {{ {cases} }}"


def _emit_action(cmd_name: str, cmd: dict, action: str, spec: dict) -> str:
    block = cmd["block"]
    func = cmd["function"]
    op = Operator[spec["operator"]]
    tokens = spec.get("payload", [])
    args = named_args(tokens)
    plen = payload_len(tokens)

    params = ", ".join(f"{name}: {_KT_TYPE[typ]}" for name, typ in args)
    sig = f"    fun {_func_name(action, cmd_name)}({params}): IntArray {{"

    prefix = [block, func, int(op), plen]
    parts = [", ".join(_hex(b) for b in prefix)]

    for tok in tokens:
        name, typ, lit = parse_token(tok)
        if lit is not None:
            parts.append(_hex(lit))
        elif typ == "mac":
            parts.append(f") + {name} + intArrayOf(")
        elif typ == "i8":
            parts.append(f"({name} and 0xFF)")  # two's-complement byte
        else:  # u8
            parts.append(f"({name} and 0xFF)")

    body = ", ".join(parts)
    body = body.replace(", ) + ", ") + ").replace(" + intArrayOf(, ", " + intArrayOf(")
    expr = f"intArrayOf({body})"
    expr = expr.replace("intArrayOf() + ", "").replace(" + intArrayOf()", "")
    return f"{sig}\n        return {expr}\n    }}"


def emit_kotlin(spec: dict) -> str:
    out: list[str] = []
    out.append("package au.com.jd.bose")
    out.append("")
    out.append(_emit_operator_enum())
    out.append("")

    for name, members in spec.get("enums", {}).items():
        out.append(_emit_value_enum(name, members))
    out.append("")

    out.append("object BMAP {")
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
