from codegen.model import encode_payload


def test_literal_and_arg():
    out = encode_payload(["mode:u8", "0x01"], {"mode": 0})
    assert out == [0x00, 0x01]


def test_signed_arg():
    out = encode_payload(["value:i8", "band:u8"], {"value": -3, "band": 1})
    assert out == [0xFD, 0x01]  # -3 as two's complement byte


def test_mac_arg():
    out = encode_payload(["00", "mac:mac"], {"mac": "E4:58:BC:C0:2F:72"})
    assert out == [0x00, 0xE4, 0x58, 0xBC, 0xC0, 0x2F, 0x72]
