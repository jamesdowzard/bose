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
