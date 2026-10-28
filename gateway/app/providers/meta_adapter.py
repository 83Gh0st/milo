"""Protocol wrapper over MetaReasoning/MetaImage/MetaVoice with NO behaviour
change: the existing classes are untouched; this only translates the
protocol's (creds, model) into their api_key + configured-model shape.
The `meta` module (openai SDK) is imported lazily so unit tests can import
this module without the web stack.
"""
from .base import ProviderError, MODEL_NOT_FOUND
from .capabilities import ProbeResult


class MetaAdapter:
    id = "meta"
    display_name = "Meta"

    def __init__(self, settings, reasoning=None, image=None, voice=None):
        from . import meta as meta_mod  # lazy: needs the openai package (CI/prod)
        self.s = settings
        self.reasoning = reasoning if reasoning is not None else meta_mod.MetaReasoning(settings)
        self.image = image if image is not None else meta_mod.MetaImage(settings)
        self.voice = voice if voice is not None else meta_mod.MetaVoice(settings)

    def _key(self, creds):
        return getattr(creds, "api_key", None) or self.s.model_api_key

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=None, creds=None, model=None):
        want = model or self.s.spark_model
        if want != self.s.spark_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        kw = {} if max_tokens is None else {"max_tokens": max_tokens}  # None keeps the wrapped default (meta: 900)
        async for piece in self.reasoning.stream(messages, schema=schema, effort=effort, api_key=self._key(creds), **kw):
            yield piece

    async def generate_image(self, prompt, creds=None, model=None):
        want = model or self.s.image_model
        if want != self.s.image_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        return await self.image.generate(prompt, api_key=self._key(creds))

    async def open_voice(self, language_bias=None, keywords=None, creds=None, model=None):
        want = model or self.s.voice_model
        if want != self.s.voice_model:
            raise ProviderError(MODEL_NOT_FOUND, 502)
        return await self.voice.open(language_bias, keywords, api_key=self._key(creds))

    async def discover_models(self, creds=None):
        return [self.s.spark_model, self.s.voice_model, self.s.image_model]

    async def probe(self, creds=None, model=None):
        import json
        import time
        want = model or self.s.spark_model
        checks, t0, ttfb = {}, time.monotonic(), -1
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
        strategy = "json_schema" if checks.get("json_schema") == "pass" else "lines"
        return ProbeResult(self.id, want, True, ttfb, strategy, checks)
