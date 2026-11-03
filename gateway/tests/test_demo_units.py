"""Competition demo mode: per-installation quotas, image-byte honesty, SAM
mask metadata, voice-input hygiene, and the SAM gate in Settings. Pure sync
except the health probe, which runs against the mock app (no key, no spend).
"""
import struct
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from conftest import mk


def _lim(**kw):
    from app.security import DemoLimiter
    d = dict(requests_per_day=3, image_per_day=1, segment_per_day=2, voice_minutes_per_day=1.0, max_concurrent=1)
    d.update(kw)
    return DemoLimiter(**d)


def test_demo_limiter_overall_and_per_capability():
    lim = _lim()
    lim.check("dev1", "chat")
    lim.check("dev1", "image")  # image cap is 1: this spends it
    with pytest.raises(HTTPException) as e:
        lim.check("dev1", "image")
    assert e.value.status_code == 429 and e.value.detail["error"] == "demo_quota_exceeded"
    lim.check("dev2", "image")  # other installations unaffected
    with pytest.raises(HTTPException):
        lim.check("dev1", "chat")  # overall cap (3) now spent too
        lim.check("dev1", "chat")


def test_demo_limiter_concurrency_and_voice_bytes():
    lim = _lim()
    lim.acquire()
    with pytest.raises(HTTPException) as e:
        lim.acquire()
    assert e.value.detail["error"] == "demo_busy"
    lim.release()
    lim.acquire()
    lim.check_voice_bytes("dev1", 60 * 48000)  # exactly one minute: allowed
    with pytest.raises(HTTPException) as e:
        lim.check_voice_bytes("dev1", 48000)
    assert e.value.detail["capability"] == "voice"


def test_image_bytes_magic():
    meta = pytest.importorskip("app.providers.meta")
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 20
    jpg = b"\xff\xd8\xff\xe0" + b"\x00" * 20
    assert meta.is_image_bytes(png) and meta.is_image_bytes(jpg)
    assert not meta.is_image_bytes(b"<html>not an image</html>")
    assert not meta.is_image_bytes(b"") and not meta.is_image_bytes(b"\x89PNG")


def test_summarize_masks_metadata_only():
    meta = pytest.importorskip("app.providers.meta")
    mask = SimpleNamespace(width=640, height=480, encoding="rle")
    recs = [SimpleNamespace(kind="mask", object_id="7", mask=mask),
            SimpleNamespace(kind="box", object_id="7", left=0, top=0, right=10, bottom=10),
            SimpleNamespace(kind="text", text="hi")]
    assert meta.summarize_masks(recs) == [{"object_id": "7", "width": 640, "height": 480, "encoding": "rle"}]


def test_sam_gate_follows_settings_not_import_env():
    from app.providers.meta_adapter import sam_probe_pending
    assert sam_probe_pending(SimpleNamespace(sam_verified=False)) is True
    assert sam_probe_pending(SimpleNamespace(sam_verified=True)) is False
    assert sam_probe_pending(None) is True


def test_voice_input_wav_strip_and_too_short():
    from app.voice_input import is_too_short, strip_wav_header
    pcm = b"\x01\x00" * 100
    wav = (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16)
           + b"data" + struct.pack("<I", len(pcm)) + pcm)
    assert strip_wav_header(wav) == pcm
    assert strip_wav_header(pcm) == pcm  # raw PCM passes through untouched
    assert is_too_short(100) and not is_too_short(48000)


def test_health_reports_demo_and_capabilities(tmp_path):
    # Sync TestClient: in-process, no event-loop socketpair (sandbox-safe).
    from starlette.testclient import TestClient
    app = mk(tmp_path)  # mock provider: practice mode, still reports honestly
    with TestClient(app) as c:
        r = c.get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["capabilities"]["chat"]["status"] == "available"
    assert "demo" in body and body["demo"]["offline_still_works"] is True
    # No credential material may ever appear in health output.
    assert "api_key" not in r.text and "MODEL_API_KEY" not in r.text


def test_demo_disabled_blocks_hosted_not_mock(tmp_path):
    # Mock is the offline practice provider, not the hosted credential: the
    # admin demo switch must not break it. The meta-path block is covered by
    # budget_guard's provider check (meta + DEMO off -> demo_disabled).
    from starlette.testclient import TestClient
    app = mk(tmp_path, demo_enabled=False)
    with TestClient(app) as c:
        s = c.post("/v1/session", json={"install_id": "a" * 20, "app_version": "1.0.0", "platform": "android"})
        h = {"Authorization": "Bearer " + s.json()["token"]}
        r = c.post("/v1/image", json={"prompt": "a red kite"}, headers=h)
    assert r.status_code == 200  # mock still draws; switch gates hosted only
