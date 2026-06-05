from codegen.model import build_frame, Operator


def test_frame_anc_set_quiet():
    # ANC set quiet: block=1F func=03 op=START(05) len=02 payload=[mode=0, 01]
    frame = build_frame(block=0x1F, function=0x03, operator=Operator.START,
                        payload=[0x00, 0x01])
    assert frame == [0x1F, 0x03, 0x05, 0x02, 0x00, 0x01]


def test_frame_get_zero_payload():
    frame = build_frame(block=0x1F, function=0x03, operator=Operator.GET, payload=[])
    assert frame == [0x1F, 0x03, 0x01, 0x00]
