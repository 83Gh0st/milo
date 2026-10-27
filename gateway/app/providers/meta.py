"""Meta Model API adapters. Base URL, model ids and the realtime ASR handshake follow Meta's published docs (verify with scripts/smoke_test.py)."""
import asyncio, base64, json, uuid
from openai import AsyncOpenAI, APIConnectionError, APIStatusError, APITimeoutError
from ..config import Settings, assert_model_allowed
from .base import ProviderError, Usage


class MetaReasoning:
    def __init__(self, s: Settings):
        self.s = s
        assert_model_allowed(s, s.spark_model)
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=30, max_retries=1)

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=900):
        assert_model_allowed(self.s, self.s.spark_model)
        kw = dict(model=self.s.spark_model, messages=messages, stream=True, max_completion_tokens=max_tokens,
                  reasoning_effort=effort, stream_options={"include_usage": True})
        if schema:
            kw["response_format"] = {"type": "json_schema", "json_schema": {"name": "milo_turn", "schema": schema}}
        usage = Usage()
        try:
            stream = await self.client.chat.completions.create(**kw)
            async for ch in stream:
                if ch.choices and ch.choices[0].delta.content:
                    yield ch.choices[0].delta.content
                u = getattr(ch, "usage", None)
                if u:
                    d = getattr(u, "prompt_tokens_details", None)
                    usage = Usage(u.prompt_tokens or 0, getattr(d, "cached_tokens", 0) or 0, u.completion_tokens or 0)
        except APITimeoutError:
            raise ProviderError("timeout", 504)
        except APIStatusError as e:
            raise ProviderError("rate_limited" if e.status_code == 429 else "provider_error", 503)
        except APIConnectionError:
            raise ProviderError("unreachable", 503)
        yield usage


class MetaImage:
    def __init__(self, s: Settings):
        self.s = s
        assert_model_allowed(s, s.image_model)
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=45, max_retries=1)

    async def generate(self, prompt: str, size: str = "1024x1024") -> bytes:
        try:  # agentic tools off: no web/image search or shell for child-facing pictures
            r = await self.client.images.generate(model=self.s.image_model, prompt=prompt, n=1, size=size,
                                                  extra_body={"reasoning_strength": "low", "tool_enablement": {"enable_image_search": False, "enable_web_search": False, "enable_shell": False}})
            return base64.b64decode(r.data[0].b64_json)
        except (APIStatusError, APIConnectionError, APITimeoutError, TypeError, IndexError):
            raise ProviderError("image_failed", 503)


class _MetaVoiceSession:
    def __init__(self, ws):
        self.ws = ws

    async def send(self, pcm: bytes):
        await self.ws.send(pcm)

    async def events(self):
        async for m in self.ws:
            if isinstance(m, bytes):
                continue
            d = json.loads(m)
            t = d.get("type")
            if t == "transcript" and d.get("transcript"):
                yield {"type": "partial", "text": d["transcript"]}
            elif t == "speechComplete":
                yield {"type": "final", "text": d.get("transcript", "")}
            elif t == "error":
                yield {"type": "error", "code": "asr_error"}

    async def close(self):
        try:
            await self.ws.send(json.dumps({"type": "endStream"}))
            await self.ws.close()
        except Exception:
            pass


class MetaVoice:
    def __init__(self, s: Settings):
        self.s = s
        assert_model_allowed(s, s.voice_model)

    async def open(self, language_bias=None, keywords=None):
        import websockets
        try:
            ws = await websockets.connect(f"{self.s.meta_asr_url}?sessionId=stream-{uuid.uuid4()}", max_size=2**20, open_timeout=10)
            hs = {"authorization": {"accessToken": f"Bearer {self.s.model_api_key}"}, "audioEncoding": "PCM_24KHZ", "model": self.s.voice_model,
                  "mode": "ENDPOINTING", "partialMode": "CUMULATIVE", "emitAudioProgress": False,
                  "zdrOverride": True}  # zero data retention: children's audio is never kept
            if language_bias:
                hs["languageBias"] = language_bias
            if keywords:
                hs["keywords"] = keywords[:20]
            await ws.send(json.dumps(hs))
            ack = json.loads(await asyncio.wait_for(ws.recv(), 10))
        except Exception:
            raise ProviderError("asr_unreachable", 503)
        if "sessionId" not in ack:
            await ws.close()
            raise ProviderError("asr_rejected", 503)
        return _MetaVoiceSession(ws)
