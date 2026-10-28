"""Protocol wrapper over the deterministic mock classes. Dependency-free."""
from .base import Usage
from .capabilities import ProbeResult
from .mock import MockImage, MockReasoning, MockVoice


class MockAdapter:
    id = "mock"
    display_name = "Mock (offline demo)"

    def __init__(self, reasoning=None, image=None, voice=None, delay: float = 0.0):
        self.reasoning = reasoning if reasoning is not None else MockReasoning(delay)
        self.image = image if image is not None else MockImage()
        self.voice = voice if voice is not None else MockVoice()

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=None, creds=None, model="mock"):
        kw = {} if max_tokens is None else {"max_tokens": max_tokens}  # None keeps the wrapped default (mock: 50)
        async for piece in self.reasoning.stream(messages, schema=schema, effort=effort, api_key=getattr(creds, "api_key", None), **kw):
            yield piece

    async def generate_image(self, prompt, creds=None, model="mock"):
        return await self.image.generate(prompt, api_key=getattr(creds, "api_key", None))

    async def open_voice(self, language_bias=None, keywords=None, creds=None, model="mock"):
        return await self.voice.open(language_bias, keywords, api_key=getattr(creds, "api_key", None))

    async def discover_models(self, creds=None):
        return ["mock"]

    async def probe(self, creds=None, model="mock"):
        async for _ in self.stream([{"role": "user", "content": "hi"}], creds=creds, model=model):
            pass
        return ProbeResult(self.id, model, True, 0, "json_schema",
                           {"chat": "pass", "json_schema": "pass", "vision": "pass"})
