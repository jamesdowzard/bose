from enum import IntEnum


class Operator(IntEnum):
    GET = 0x01
    SET_GET = 0x02
    RESP = 0x03
    ERROR = 0x04
    START = 0x05
    SET = 0x06
    ACK = 0x07


def build_frame(block: int, function: int, operator: Operator, payload: list[int]) -> list[int]:
    return [block, function, int(operator), len(payload), *payload]


def _mac_bytes(s: str) -> list[int]:
    return [int(b, 16) for b in s.replace("-", ":").split(":")]


def parse_token(tok: str) -> tuple[str | None, str | None, int | None]:
    """Classify a payload token.

    Returns (name, typ, literal):
      - named arg "x:u8"   -> ("x", "u8", None)
      - hex literal "0x01" -> (None, None, 0x01)
    """
    if ":" in tok:
        name, typ = tok.split(":")
        return name, typ, None
    return None, None, int(tok, 16)


def token_byte_len(tok: str) -> int:
    """Static byte length a token contributes to the payload."""
    _, typ, _ = parse_token(tok)
    return 6 if typ == "mac" else 1


def payload_len(tokens: list[str]) -> int:
    return sum(token_byte_len(t) for t in tokens)


def named_args(tokens: list[str]) -> list[tuple[str, str]]:
    """Ordered (name, type) for each named-arg token in a payload."""
    out: list[tuple[str, str]] = []
    for tok in tokens:
        name, typ, _ = parse_token(tok)
        if name is not None:
            assert typ is not None  # a named-arg token always has a type
            out.append((name, typ))
    return out


def encode_payload(tokens: list[str], args: dict) -> list[int]:
    out: list[int] = []
    for tok in tokens:
        if ":" in tok:                       # named arg "name:type"
            name, typ = tok.split(":")
            val = args[name]
            if typ == "u8":
                out.append(val & 0xFF)
            elif typ == "i8":
                out.append(val & 0xFF)        # two's complement in a byte
            elif typ == "mac":
                out.extend(_mac_bytes(val))
            else:
                raise ValueError(f"unknown type {typ}")
        else:                                 # hex literal "0x01" / "00"
            out.append(int(tok, 16))
    return out
