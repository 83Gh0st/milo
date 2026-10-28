"""Dependency-free voice tests (Phase 4B): framing, envelopes, resampling,
mock determinism, engine resolution. No fastapi/httpx/numpy; async engines
are driven without an event loop (pure coroutines complete on first send)."""
import json
import math
import struct
import sys
import wave
from io import BytesIO
from types import SimpleNamespace

import pytest

sys.path.insert(0, ".")

from app import voicecore as V
from app.providers.base import ProviderError


def run(coro):
    try:
        coro.send(None)
    except StopIteration as e:
        return e.value
    raise AssertionError("coroutine suspended (needs a real loop)")


def sine(secs=1.0, hz=440.0, amp=0.8, rate=24000):
    return struct.pack(f"<{int(secs * rate)}h",
                       *[int(32767 * amp * math.sin(2 * math.pi * hz * i / rate)) for i in range(int(secs * rate))])


def settings(**kw):
    d = dict(env="dev", speak_engine="auto", speak_api_key="", speak_model="tts-x", piper_voice="")
    d.update(kw)
    return SimpleNamespace(**d)


def test_envelope_silence_is_zeros_and_mouth_stays_shut():
    env = V.envelope(bytes(48000))  # 1 s of silence @24k
    assert len(env) == 30 and set(env) == {0.0}
    assert V.envelope(b"") == []


def test_envelope_sine_normalises_to_one():
    env = V.envelope(sine())
    assert len(env) == 30 and all(abs(v - 1.0) < 0.05 for v in env)


def test_frame_round_trip():
    sb, out = V.parse_frame(V.frame({"a": 1, "s": "x"}, b"\x01\x02"))
    assert (sb, out) == ({"a": 1, "s": "x"}, b"\x01\x02")


def test_resample_ratio_and_identity():
    pcm = sine(secs=1.0, rate=22050)
    assert V.resample_linear(pcm, 22050) != pcm  # converted
    assert len(V.resample_linear(pcm, 22050)) // 2 == pytest.approx(24000, abs=2)
    assert V.resample_linear(pcm, 22050, 22050) == pcm  # same rate: untouched


def test_read_wav_folds_stereo_and_rejects_garbage():
    buf = BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(struct.pack("<4h", 1000, 3000, -1000, -3000))
    pcm, rate = V.read_wav_pcm(buf.getvalue())
    assert rate == 22050 and struct.unpack("<2h", pcm) == (2000, -2000)
    with pytest.raises(ValueError):
        V.read_wav_pcm(b"not a wav file at all...........")


def test_mock_is_deterministic_bounded_and_shaped():
    a = run(V.MockSpeakEngine().synth("Hello there friend", "en", "", {}))
    b = run(V.MockSpeakEngine().synth("Hello there friend", "en", "", {}))
    assert a == b and a[0]["engine"] == "mock" and a[0]["placeholder"] is True
    assert 500 <= a[0]["duration_ms"] <= 8000
    assert min(a[0]["envelope"]) < 0.4 and max(a[0]["envelope"]) == 1.0  # audible beats, normalised peak
    assert abs(len(a[1]) - a[0]["duration_ms"] * 48) < 96  # pcm16 @24k matches the header (±2 ms rounding)


def test_resolve_auto_dev_falls_back_to_mock():
    assert isinstance(V.resolve_engine(settings()), V.MockSpeakEngine)


def test_resolve_refuses_honestly_when_nothing_available():
    with pytest.raises(ProviderError) as e:
        V.resolve_engine(settings(env="prod"))
    assert e.value.code == "no_voice_engine" and e.value.status == 503
    with pytest.raises(ProviderError):
        V.resolve_engine(settings(speak_engine="piper"))  # no binary/model here
    with pytest.raises(ProviderError):
        V.resolve_engine(settings(speak_engine="openai"))  # no key anywhere


def test_resolve_tts_route_uses_family_creds_but_settings_model():
    from app.providers.registry import RouteEntry
    creds = {"openai": SimpleNamespace(api_key="sk-fam", base_url="")}
    eng = V.resolve_engine(settings(), [RouteEntry("openai", "gpt-chat-model")], creds)
    assert isinstance(eng, V.OpenAISpeakEngine) and eng.api_key == "sk-fam" and eng.model == "tts-x"


def test_voice_profiles_are_stable_and_brain_independent():
    assert set(V.VOICE_PROFILES) == {"milo_warm_en", "milo_warm_hi", "milo_warm_ml"}
    assert all("muse" not in json.dumps(p) and "gpt" not in json.dumps(p) for p in V.VOICE_PROFILES.values())
