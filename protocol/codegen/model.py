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
