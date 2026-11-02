"""Neural voice synthesis core (Phase 4B). Dependency-free (stdlib only):
PCM framing, amplitude envelopes, resampling, and the speak engines. The
FastAPI endpoint lives in `speak.py`; unit tests import only this module.

Wire format: one sideband JSON line + b"\\n" + raw PCM16 mono 24 kHz. The
envelope rides up front so the phone can lip-sync without waiting, and so a
proxy that buffers chunked bodies only delays audio, never breaks framing.
"""
import io
import json
import math
import shutil
import struct
import subprocess
import wave

RATE = 24000  # Hz, mono, int16
ENVELOPE_HZ = 30

# Stable voice identities: changing the BRAIN provider never changes these;
# changing the voice engine is a separate Voice setting. Voices are filled by
# the Phase 4A bake-off winner (human ears); until then the mock/piper
# engines render them with clearly-labelled placeholder audio in dev.
VOICE_PROFILES = {
    "milo_warm_en": {"engine": "auto", "lang": "en", "voice": "", "pace": 1.0},
    "milo_warm_hi": {"engine": "auto", "lang": "hi", "voice": "", "pace": 1.0},
    "milo_warm_ml": {"engine": "auto", "lang": "ml", "voice": "", "pace": 1.0},
}


def envelope(pcm: bytes, rate: int = RATE, hz: int = ENVELOPE_HZ) -> list[float]:
    """RMS amplitude per window, normalised so the loudest window is 1.0.
    Silence (or empty input) yields all zeros - the mouth stays shut."""
    if len(pcm) < 2:
        return []
    n = len(pcm) // 2
    win = max(1, rate // hz)
    samps = struct.unpack(f"<{n}h", pcm[:n * 2])
    out, peak = [], 0.0
    for i in range(0, n, win):
        seg = samps[i:i + win]
        rms = math.sqrt(sum(s * s for s in seg) / len(seg)) / 32768
        out.append(rms)
        peak = max(peak, rms)
    if peak <= 0:
        return [0.0] * len(out)
    return [round(v / peak, 3) for v in out]


def resample_linear(pcm: bytes, src_rate: int, dst_rate: int = RATE) -> bytes:
    """Naive linear resample for engine outputs that are not 24 kHz (e.g. a
    22050 Hz Piper voice). Good enough for speech; no numpy needed."""
    if src_rate == dst_rate or len(pcm) < 4:
        return pcm
    n = len(pcm) // 2
    samps = struct.unpack(f"<{n}h", pcm[:n * 2])
    m = max(1, round(n * dst_rate / src_rate))
    out = []
    for i in range(m):
        pos = i * (n - 1) / max(1, m - 1)
        j, frac = int(pos), pos - int(pos)
        out.append(round(samps[j] * (1 - frac) + samps[min(j + 1, n - 1)] * frac))
    return struct.pack(f"<{m}h", *out)


def read_wav_pcm(blob: bytes) -> tuple[bytes, int]:
    """Extracts mono int16 PCM + sample rate from a WAV blob. Stereo is
    folded to mono; non-PCM WAVs raise ValueError (honest failure)."""
    try:
        with wave.open(io.BytesIO(blob), "rb") as w:
            if w.getsampwidth() != 2 or w.getcomptype() != "NONE":
                raise ValueError("not PCM16 wav")
            raw, rate, ch = w.readframes(w.getnframes()), w.getframerate(), w.getnchannels()
    except (wave.Error, EOFError) as e:
        raise ValueError(f"bad wav: {e}")
    if ch == 1:
        return raw, rate
    n = len(raw) // 2
    samps = struct.unpack(f"<{n}h", raw[:n * 2])
    mono = [round((samps[i] + samps[i + 1]) / 2) for i in range(0, n - ch + 1, ch)]
    return struct.pack(f"<{len(mono)}h", *mono), rate


def frame(sideband: dict, pcm: bytes) -> bytes:
    return json.dumps(sideband).encode() + b"\n" + pcm


def parse_frame(blob: bytes) -> tuple[dict, bytes]:
    head, _, pcm = blob.partition(b"\n")
    return json.loads(head), pcm


class SpeakEngine:
    id = "?"

    async def synth(self, text: str, lang: str, voice: str, style: dict) -> tuple[dict, bytes]:
        """Returns (sideband, pcm24k). Sideband always carries engine,
        duration_ms and envelope; callers add sentence/ledger fields."""
        raise NotImplementedError


class MockSpeakEngine(SpeakEngine):
    """Deterministic clearly-synthetic placeholder (a soft 196 Hz hum gated
    into syllable-ish beats) so the whole speak→cache→lip-sync→barge-in
    pipeline is testable with no model, no key, no network. NEVER presented
    as Milo's voice: the sideband says engine=mock, and prod auto-resolution
    refuses it (see resolve_engine)."""
    id = "mock"

    async def synth(self, text: str, lang: str, voice: str, style: dict) -> tuple[dict, bytes]:
        secs = min(8.0, max(0.5, 0.4 + 0.055 * len(text)))
        n = int(secs * RATE)
        beats = max(1, len(text) // 4)
        out = []
        for i in range(n):
            t = i / RATE
            gate = 0.55 + 0.45 * math.sin(2 * math.pi * beats * t / secs)
            v = (0.28 * math.sin(2 * math.pi * 196 * t) + 0.1 * math.sin(2 * math.pi * 392 * t)) * gate
            fade = min(1.0, i / (0.02 * RATE), (n - i) / (0.05 * RATE))
            out.append(int(32767 * v * max(0.0, fade)))
        pcm = struct.pack(f"<{n}h", *out)
        return {"engine": "mock", "duration_ms": int(secs * 1000), "sample_rate": RATE,
                "envelope": envelope(pcm), "placeholder": True}, pcm


class PiperSpeakEngine(SpeakEngine):
    """Local Piper TTS (open source, no key, no network): the sensible dev
    default when the binary + a voice model are installed. Each voice file
    carries its own licence - record it before release. CLI shape is the
    standard `piper --model X --output_file Y` (UNVERIFIED here: no binary
    on this machine; first run with Piper installed confirms)."""
    id = "piper"

    def __init__(self, model_path: str):
        self.model_path = model_path

    @staticmethod
    def available(model_path: str) -> bool:
        import os
        return bool(model_path) and shutil.which("piper") is not None and os.path.exists(model_path)

    async def synth(self, text: str, lang: str, voice: str, style: dict) -> tuple[dict, bytes]:
        import os
        import tempfile
        out = tempfile.mktemp(suffix=".wav")
        try:
            p = subprocess.run(["piper", "--model", self.model_path, "--output_file", out],
                               input=text.encode(), capture_output=True, timeout=60)
            if p.returncode != 0 or not os.path.exists(out):
                raise _speak_error("provider_error", "piper failed: " + p.stderr.decode()[-200:])
            with open(out, "rb") as f:
                pcm, rate = read_wav_pcm(f.read())
        except subprocess.TimeoutExpired:
            raise _speak_error("timeout", "piper timed out")
        finally:
            try:
                os.remove(out)
            except OSError:
                pass
        pcm = resample_linear(pcm, rate)
        return {"engine": "piper", "duration_ms": len(pcm) // 2 * 1000 // RATE,
                "sample_rate": RATE, "envelope": envelope(pcm)}, pcm


class OpenAISpeakEngine(SpeakEngine):
    """Hosted OpenAI-compatible TTS (family key or deployer key). Request
    shape is a first hypothesis (UNVERIFIED: no network 28 Oct 2026) -
    isolated here; the first keyed run confirms or corrects it."""
    id = "openai"

    def __init__(self, api_key: str, base_url: str = "https://api.openai.com/v1", model: str = "gpt-4o-mini-tts"):
        self.api_key, self.base_url, self.model = api_key, base_url.rstrip("/"), model

    async def synth(self, text: str, lang: str, voice: str, style: dict) -> tuple[dict, bytes]:
        import httpx
        from .providers.base import ProviderError, raise_for_status
        try:
            async with httpx.AsyncClient(timeout=60, follow_redirects=False) as c:
                r = await c.post(self.base_url + "/audio/speech",
                                 headers={"Authorization": "Bearer " + self.api_key},
                                 json={"model": self.model, "input": text,
                                       "voice": voice or "alloy", "response_format": "wav"})
        except httpx.TimeoutException:
            raise ProviderError("timeout", 504)
        except httpx.ConnectError:
            raise ProviderError("unreachable", 503)
        if r.status_code != 200:
            raise_for_status("openai", r.status_code, r.text[:300])
        try:
            pcm, rate = read_wav_pcm(r.content)
        except ValueError:
            raise ProviderError("provider_error", 503)
        pcm = resample_linear(pcm, rate)
        return {"engine": "openai", "duration_ms": len(pcm) // 2 * 1000 // RATE,
                "sample_rate": RATE, "envelope": envelope(pcm)}, pcm


def _speak_error(code: str, detail: str = ""):
    from .providers.base import ProviderError
    status = {"timeout": 504, "unreachable": 503}.get(code, 503)
    return ProviderError(code, status)


def resolve_engine(settings, tts_entries: list | None = None, creds: dict | None = None) -> SpeakEngine:
    """Picks the TTS engine. Vault tts routes come first (family credentials
    for hosted engines); then the deployer key; then local Piper; then the
    mock placeholder in dev only. Raises ProviderError(code 503) with
    no_voice_engine when nothing honest is available - the APP then falls
    back to platform TTS, never silence."""
    from .providers.base import ProviderError
    entries, creds = tts_entries or [], creds or {}
    if settings.speak_engine not in ("auto", ""):
        want = settings.speak_engine
        if want == "mock" and settings.env == "dev":
            return MockSpeakEngine()
        if want == "piper" and PiperSpeakEngine.available(settings.piper_voice):
            return PiperSpeakEngine(settings.piper_voice)
        if want == "openai":
            key = (creds.get("openai").api_key if creds.get("openai") else "") or settings.speak_api_key
            if key:
                base = (creds.get("openai").base_url if creds.get("openai") else "") or "https://api.openai.com/v1"
                return OpenAISpeakEngine(key, base, settings.speak_model)
        raise ProviderError("no_voice_engine", 503)
    for e in entries:  # family tts routes, in order (entry picks the CREDENTIALS; the TTS model is settings-level, never a chat model id)
        c = creds.get(e.provider)
        if e.provider in ("openai", "custom") and c is not None and (c.api_key or e.provider == "custom"):
            return OpenAISpeakEngine(c.api_key, c.base_url or "https://api.openai.com/v1", settings.speak_model)
        if e.provider == "mock" and settings.env == "dev":
            return MockSpeakEngine()
    if settings.speak_api_key:
        return OpenAISpeakEngine(settings.speak_api_key, "https://api.openai.com/v1", settings.speak_model)
    if PiperSpeakEngine.available(settings.piper_voice):
        return PiperSpeakEngine(settings.piper_voice)
    if settings.env == "dev":
        return MockSpeakEngine()
    raise ProviderError("no_voice_engine", 503)
