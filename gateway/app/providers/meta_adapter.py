"""Protocol wrapper over MetaReasoning/MetaImage/MetaVoice with NO behaviour
change: the existing classes are untouched; this only translates the
protocol's (creds, model) into their api_key + configured-model shape.
The `meta` module (openai SDK) is imported lazily so unit tests can import
this module without the web stack.
"""
import os

from .base import ProviderError, MODEL_NOT_FOUND, UNSUPPORTED_CAPABILITY
from .capabilities import ProbeResult

# Back-compat probe flag (tests and ops scripts read it): the authoritative
# gate is Settings.sam_verified below; this mirrors the process env default.
SAM_KEYED_PROBE_PENDING = os.environ.get("SAM_VERIFIED", "") != "true"


def sam_probe_pending(settings) -> bool:
    """SAM app path gate: True until the keyed probe_sam.py run passes.

    The switch lives in Settings (SAM_VERIFIED env / server secret) so the
    deployed value is visible in one place and testable without import-time
    env reads. The probe reports sam_entitled either way; a health check or
    entitlement alone never enables the app path."""
    if settings is None:
        return True
    return not bool(getattr(settings, "sam_verified", False))


class MetaAdapter:
    id = "meta"
    display_name = "Meta"

    def __init__(self, settings, reasoning=None, image=None, voice=None, models=None, wonder=None, ground=None):
        from . import meta as meta_mod  # lazy: needs the openai package (CI/prod)
        self.s = settings
        self.reasoning = reasoning if reasoning is not None else meta_mod.MetaReasoning(settings)
        self.image = image if image is not None else meta_mod.MetaImage(settings)
        self.voice = voice if voice is not None else meta_mod.MetaVoice(settings)
        self.models = models if models is not None else meta_mod.MetaModels(settings)
        self.ground_impl = ground if ground is not None else meta_mod.MetaGround(settings)
        w = getattr(settings, "wonder_model", None) or settings.spark_model
        self.wonder = wonder if wonder is not None else meta_mod.MetaReasoning(settings, model=w)

    def _key(self, creds):
        return getattr(creds, "api_key", None) or self.s.model_api_key

    def _require_key(self, creds):
        """Distinct, honest failure when no Meta credential exists at all
        (demo secret not set, no BYOK key): callers word this as 'not set
        up on the server yet', never as a generic provider outage."""
        key = self._key(creds)
        if not key:
            raise ProviderError("not_configured", 503)
        return key

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=None, creds=None, model=None):
        want = model or self.s.spark_model
        if want == self.s.spark_model:
            engine = self.reasoning
        elif want == getattr(self.s, "wonder_model", None):
            engine = self.wonder  # long-form only (stories/plan): explicit route, never default turns
        else:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        kw = {} if max_tokens is None else {"max_tokens": max_tokens}  # None keeps the wrapped default (meta: 900)
        async for piece in engine.stream(messages, schema=schema, effort=effort, api_key=self._require_key(creds), **kw):
            yield piece

    async def generate_image(self, prompt, creds=None, model=None):
        want = model or self.s.image_model
        if want != self.s.image_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        return await self.image.generate(prompt, api_key=self._require_key(creds))

    async def ground(self, image_b64, phrase, creds=None, model=None):
        if getattr(self, "s", None) is not None:
            self._require_key(creds)
        if sam_probe_pending(getattr(self, "s", None)):
            raise ProviderError(UNSUPPORTED_CAPABILITY, 502)
        want = model or self.s.sam_model
        if want != self.s.sam_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        return await self.ground_impl.ground(image_b64, phrase, api_key=self._key(creds))

    async def open_voice(self, language_bias=None, keywords=None, creds=None, model=None):
        want = model or self.s.voice_model
        if want != self.s.voice_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        return await self.voice.open(language_bias, keywords, api_key=self._require_key(creds))

    async def discover_models(self, creds=None):
        # The full one-key suite: one family Meta key funds all five. Order is
        # the picker's order (Spark first: it stays the recommended default).
        s = self.s
        return [m for m in (s.spark_model, getattr(s, "wonder_model", None), s.image_model,
                            s.voice_model, getattr(s, "sam_model", None)) if m]

    async def _entitlements(self, creds):
        """One cheap /v1/models call: which Meta ids this key may use. Never
        spends a generation; entitled != verified-working (live runs prove)."""
        try:
            ids = set(await self.models.list_ids(api_key=self._key(creds)))
        except ProviderError as e:
            return {k: f"skipped:{e.code}" for k in ("image_entitled", "voice_entitled", "sam_entitled", "wonder_entitled")}
        s = self.s
        return {
            "image_entitled": "pass" if s.image_model in ids else "fail:not_entitled",
            "voice_entitled": "pass" if s.voice_model in ids else "fail:not_entitled",
            "sam_entitled": "pass" if getattr(s, "sam_model", None) in ids else "fail:not_entitled",
            "wonder_entitled": "pass" if getattr(s, "wonder_model", None) in ids else "fail:not_entitled",
        }

    async def _probe_entitlement(self, creds, want):
        ent = await self._entitlements(creds)
        s = self.s
        key = ("image_entitled" if want == s.image_model else "voice_entitled" if want == s.voice_model
               else "sam_entitled" if want == getattr(s, "sam_model", None) else "wonder_entitled")
        return ProbeResult(self.id, want, ent[key] == "pass", -1, "lines", ent)

    async def probe(self, creds=None, model=None):
        import json
        import time
        want = model or self.s.spark_model
        checks, t0, ttfb = {}, time.monotonic(), -1
        if want in (self.s.image_model, self.s.voice_model) or want in (getattr(self.s, "wonder_model", None), getattr(self.s, "sam_model", None)):
            return await self._probe_entitlement(creds, want)  # non-chat members: list check, no generation spend
        if want != self.s.spark_model:
            return ProbeResult(self.id, want, False, ttfb, "lines", {"chat": "fail:model_not_found"})
        try:
            first = True
            async for piece in self.stream([{"role": "user", "content": "Reply with exactly: ok"}], creds=creds, model=want, max_tokens=8):
                if first and isinstance(piece, str):
                    ttfb = int((time.monotonic() - t0) * 1000)
                    first = False
            checks["chat"] = "pass"
        except ProviderError as e:
            checks["chat"] = f"fail:{e.code}"
            return ProbeResult(self.id, want, False, ttfb, "lines", checks)
        schema = {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}
        try:
            buf = ""
            async for piece in self.stream([{"role": "user", "content": "Reply {\"ok\": true}."}], schema=schema, creds=creds, model=want, max_tokens=32):
                if isinstance(piece, str):
                    buf += piece
            json.loads(buf.strip())
            checks["json_schema"] = "pass"
        except (ProviderError, ValueError) as e:
            checks["json_schema"] = f"fail:{getattr(e, 'code', 'bad_json')}"
        checks["vision"] = "skipped:meta vision is exercised by the understand smoke test, not the 1x1 probe"
        checks["visual_ground"] = "skipped:SAM app path gated on a keyed probe_sam.py run"
        for k, v in (await self._entitlements(creds)).items():
            checks[k] = v
        strategy = "json_schema" if checks.get("json_schema") == "pass" else "lines"
        return ProbeResult(self.id, want, True, ttfb, strategy, checks)
