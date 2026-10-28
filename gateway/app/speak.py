"""Neural voice endpoint (Phase 4B): POST /v1/speak synthesises ONE sentence
(the phone pipelines sentences for gapless playback) and returns the voicecore
wire format: one sideband JSON line + raw PCM16 mono 24 kHz.

Ledger-before-send is client-side (the app writes the entry before calling,
like beginVoice). TTS engine choice reuses the Phase 3 vault tts routes +
credentials; hosted synthesis on the deployer path is metered once the human
prices it (speak_price_per_1k, default 0 = unmetered).
"""
import logging
import time

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from .models import SpeakReq
from .providers.base import ProviderError
from .routes import budget_guard
from .security import auth
from .sync import vault_ctx
from .voicecore import VOICE_PROFILES, frame, resolve_engine

router = APIRouter(prefix="/v1")
log = logging.getLogger("milo")


@router.post("/speak")
async def speak(req: SpeakReq, request: Request, dev: str = Depends(auth), _b: None = Depends(budget_guard)):
    st = request.app.state
    t0 = time.monotonic()
    ctx = await vault_ctx(request)  # None on the deployer path; 401/409 on bad vault headers
    prof = VOICE_PROFILES.get(req.profile) or VOICE_PROFILES["milo_warm_en"]
    voice = req.voice_id.strip() or prof["voice"]
    try:
        engine = resolve_engine(st.settings, (ctx.routes.get("tts") or []) if ctx else [], ctx.creds if ctx else {})
        sideband, pcm = await engine.synth(req.text, req.lang, voice, req.style)
    except ProviderError as e:
        log.info("speak refused", extra={"kind": "speak", "err": e.code, "chars": len(req.text)})
        raise HTTPException(e.status, {"error": e.code})
    sideband["sentence_id"] = req.sentence_id
    if ctx is None and engine.id in ("openai",):
        await st.budget.add(len(req.text) / 1000 * st.settings.speak_price_per_1k)
    log.info("speak", extra={"kind": "speak", "ms": int((time.monotonic() - t0) * 1000),
                             "chars": len(req.text), "engine": engine.id})
    return Response(frame(sideband, pcm), media_type="application/octet-stream")
