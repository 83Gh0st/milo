"""SAM helpers: stdlib image sizing + parser-record normalization. Pure sync
tests (no openai stream, no key): the wire path is proven by probe_sam.py."""
import struct
import sys
from types import SimpleNamespace

import pytest

meta = pytest.importorskip("app.providers.meta")


def _png(w, h):
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", w, h) + b"\x08\x02\x00\x00\x00" + b"\x00" * 20


def _jpg(w, h):
    sof = b"\xff\xc0" + struct.pack(">H", 11) + b"\x08" + struct.pack(">HH", h, w) + b"\x01\x11\x00"
    return b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9 + sof + b"\xff\xd9"


def test_image_size_png_and_jpeg():
    assert meta.image_size(_png(320, 200)) == (320, 200)
    assert meta.image_size(_jpg(640, 480)) == (640, 480)


def test_image_size_rejects_garbage():
    assert meta.image_size(b"GIF89a" + b"\x00" * 100) is None
    assert meta.image_size(b"\xff\xd8\xff\xda" + b"\x00" * 100) is None  # SOS before any SOF
    assert meta.image_size(b"short") is None
    assert meta.image_size(_png(0, 10)) is None


def test_norm_boxes_normalizes_clamps_drops():
    recs = [SimpleNamespace(kind="box", object_id="0", left=32, top=20, right=96, bottom=60),  # -> .1,.1,.2,.2 on 320x200
            SimpleNamespace(kind="mask", object_id="0"),  # masks ignored: overlay draws boxes
            SimpleNamespace(kind="box", object_id="1", left=0, top=0, right=1, bottom=1),  # degenerate
            SimpleNamespace(kind="box", object_id="2", left=900, top=0, right=950, bottom=50),  # off-frame
            SimpleNamespace(kind="text", order=0, text="hi")]  # prose ignored
    out = meta.norm_boxes(recs, 320, 200)
    assert out == [{"x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2, "object_id": "0"}]


def test_norm_boxes_caps_count():
    recs = [SimpleNamespace(kind="box", object_id=str(i), left=0, top=0, right=100, bottom=100) for i in range(30)]
    assert len(meta.norm_boxes(recs, 200, 200)) == 20


async def test_ground_says_so_when_parser_missing(monkeypatch):
    g = meta.MetaGround.__new__(meta.MetaGround)  # skip SDK construction: unit slice only
    g.s = SimpleNamespace(sam_model="sam-3.1", model_api_key="k", meta_base_url="https://x.test/v1")
    monkeypatch.setitem(sys.modules, "meta_sam_parser", None)  # `from x import y` sees ImportError
    with pytest.raises(Exception) as e:
        await g.ground("aGk=", "duck")
    assert getattr(e.value, "code", "") == "sam_unavailable"
