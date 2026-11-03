"""Meta Model API adapters. Base URL, model ids and the realtime ASR handshake follow Meta's published docs (verify with scripts/smoke_test.py)."""
import asyncio, base64, json, uuid
from openai import AsyncOpenAI, APIConnectionError, APIStatusError, APITimeoutError
from ..config import Settings, assert_model_allowed
from .base import ProviderError, Usage


class MetaModels:
    """Entitlement check via GET /v1/models (docs /docs/models). Cheap: proves
    which model ids this key may call, without spending a generation."""
    def __init__(self, s: Settings):
        self.s = s
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=15, max_retries=0)

    async def list_ids(self, api_key=None) -> list:
        client, family = self.client, bool(api_key and api_key != self.s.model_api_key)
        if family:
            client = AsyncOpenAI(base_url=self.s.meta_base_url, api_key=api_key, timeout=15, max_retries=0)
        try:
            page = await client.models.list()
            return sorted({m.id for m in page.data if getattr(m, "id", "")})
        except APITimeoutError:
            raise ProviderError("timeout", 504)
        except APIStatusError as e:
            if family and e.status_code in (401, 403):
                raise ProviderError("family_key_rejected", 502)
            raise ProviderError("auth_failed" if e.status_code in (401, 403) else "provider_error", 503)
        except APIConnectionError:
            raise ProviderError("unreachable", 503)


class MetaReasoning:
    def __init__(self, s: Settings, model: str | None = None):
        self.s = s
        self.model = model or s.spark_model
        if self.model not in (s.spark_model, getattr(s, "wonder_model", None)):
            raise ProviderError("model_not_found", 502)
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=30, max_retries=1)

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=900, api_key=None):
        assert_model_allowed(self.s, self.model)
        client, family = self.client, bool(api_key and api_key != self.s.model_api_key)
        if family:  # BYOK: this turn is billed to the family's key, never constructed with the deployer key
            client = AsyncOpenAI(base_url=self.s.meta_base_url, api_key=api_key, timeout=30, max_retries=1)
        kw = dict(model=self.model, messages=messages, stream=True, max_completion_tokens=max_tokens,
                  reasoning_effort=effort, stream_options={"include_usage": True})
        if schema:
            kw["response_format"] = {"type": "json_schema", "json_schema": {"name": "milo_turn", "schema": schema}}
        usage = Usage()
        try:
            stream = await client.chat.completions.create(**kw)
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
            if family and e.status_code in (401, 403):
                raise ProviderError("family_key_rejected", 502)
            raise ProviderError("rate_limited" if e.status_code == 429 else "provider_error", 503)
        except APIConnectionError:
            raise ProviderError("unreachable", 503)
        yield usage


class MetaImage:
    def __init__(self, s: Settings):
        self.s = s
        assert_model_allowed(s, s.image_model)
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=45, max_retries=1)

    async def generate(self, prompt: str, size: str = "1024x1024", api_key=None) -> bytes:
        client = self.client
        if api_key and api_key != self.s.model_api_key:
            client = AsyncOpenAI(base_url=self.s.meta_base_url, api_key=api_key, timeout=45, max_retries=1)
        try:  # agentic tools off: no web/image search or shell for child-facing pictures
            r = await client.images.generate(model=self.s.image_model, prompt=prompt, n=1, size=size,
                                             extra_body={"reasoning_strength": "low", "tool_enablement": {"enable_image_search": False, "enable_web_search": False, "enable_shell": False}})
            return base64.b64decode(r.data[0].b64_json)
        except (APIStatusError, APIConnectionError, APITimeoutError, TypeError, IndexError):
            raise ProviderError("image_failed", 503)


def image_size(raw: bytes):
    """Width/height from PNG or JPEG bytes, stdlib only (PIL stays out of the
    image so SAM can't drag in native deps). None when unparseable."""
    if raw[:8] == b"\x89PNG\r\n\x1a\n" and len(raw) >= 24:
        w, h = int.from_bytes(raw[16:20], "big"), int.from_bytes(raw[20:24], "big")
        return (w, h) if w and h else None
    if raw[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(raw):
            if raw[i] != 0xFF:
                i += 1
                continue
            m = raw[i + 1]
            if m == 0xFF:  # fill byte
                i += 1
                continue
            if m in (0xC0, 0xC1, 0xC2, 0xC3):  # SOF: height then width, big-endian
                h, w = int.from_bytes(raw[i + 5:i + 7], "big"), int.from_bytes(raw[i + 7:i + 9], "big")
                return (w, h) if w and h else None
            if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7 or m == 0x01:
                i += 2
                continue
            if m == 0xDA:  # SOS: compressed data follows, no more headers
                return None
            i += 2 + int.from_bytes(raw[i + 2:i + 4], "big")
    return None


def norm_boxes(records, w: int, h: int, limit: int = 20) -> list:
    """Parser box records (source-media coords) -> normalized overlay boxes.
    Pure: unit-tested without the API. Masks ignored (the overlay draws
    boxes); degenerate/off-frame records dropped, never clamped into lies."""
    out = []
    for r in records or []:
        if getattr(r, "kind", "") != "box":
            continue
        try:
            l, t, rr, b = float(r.left) / w, float(r.top) / h, float(r.right) / w, float(r.bottom) / h
        except (TypeError, ValueError, ZeroDivisionError):
            continue
        if not all(-0.05 < v < 1.05 for v in (l, t, rr, b)) or rr - l < 0.02 or b - t < 0.02:
            continue
        cl, ct, cr, cb = min(max(l, 0.0), 1.0), min(max(t, 0.0), 1.0), min(max(rr, 0.0), 1.0), min(max(b, 0.0), 1.0)
        out.append({"x": round(cl, 4), "y": round(ct, 4), "w": round(cr - cl, 4), "h": round(cb - ct, 4),
                    "object_id": str(getattr(r, "object_id", "") or "")})
        if len(out) >= limit:
            break
    return out


async def coerce_sam_events(stream):
    """Plain-dict events + synthesized output_text.done, mirroring
    scripts/probe_sam.py: the API streams content_part.done but not
    output_text.done, which is what closes a lane. Keep the two in sync."""
    done = set()
    async for ev in stream:
        d = ev.model_dump() if hasattr(ev, "model_dump") else dict(ev)
        lane = (d.get("item_id"), d.get("output_index"), d.get("content_index"))
        if d.get("type") == "response.output_text.done":
            if lane not in done:
                done.add(lane)
                yield d
            continue
        yield d
        part = d.get("part")
        if (d.get("type") == "response.content_part.done" and lane not in done
                and isinstance(part, dict) and part.get("type") == "output_text"
                and isinstance(part.get("text"), str)):
            done.add(lane)
            yield {"type": "response.output_text.done", "item_id": d.get("item_id"),
                   "output_index": d.get("output_index"),
                   "content_index": d.get("content_index"), "text": part["text"]}


class MetaGround:
    """SAM 3.1 visual grounding over the Responses API, exactly per Meta's
    cookbook (07_sam/01_api_basics): one noun phrase + image data URL,
    streamed, parsed ONLY with meta_sam_parser. Boxes only; video deferred
    (minutes-scale, needs the Files upload flow). Live-unverified until
    scripts/probe_sam.py passes with a real key."""

    def __init__(self, s: Settings):
        self.s = s
        assert_model_allowed(s, s.sam_model)
        self.client = AsyncOpenAI(base_url=s.meta_base_url, api_key=s.model_api_key, timeout=60, max_retries=1)

    async def ground(self, image_b64: str, phrase: str, api_key=None) -> dict:
        try:
            from meta_sam_parser import image_segmentation_format, parse_responses_stream
        except ImportError:
            raise ProviderError("sam_unavailable", 501)
        try:
            raw = base64.b64decode(image_b64, validate=True)
        except Exception:
            raise ProviderError("bad_image", 422)
        dims = image_size(raw)
        if dims is None:
            raise ProviderError("bad_image", 422)
        w, h = dims
        mime = "image/png" if raw[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
        client, family = self.client, bool(api_key and api_key != self.s.model_api_key)
        if family:  # BYOK: billed to the family's key
            client = AsyncOpenAI(base_url=self.s.meta_base_url, api_key=api_key, timeout=60, max_retries=1)
        try:
            stream = await client.responses.create(model=self.s.sam_model, stream=True, input=[{
                "type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": phrase.strip()},
                    {"type": "input_image", "image_url": f"data:{mime};base64,{image_b64}"}]}])
            result = await parse_responses_stream(coerce_sam_events(stream), image_segmentation_format()).final_result()
        except APITimeoutError:
            raise ProviderError("timeout", 504)
        except APIStatusError as e:
            if family and e.status_code in (401, 403):
                raise ProviderError("family_key_rejected", 502)
            raise ProviderError("auth_failed" if e.status_code in (401, 403) else "provider_error", 503)
        except APIConnectionError:
            raise ProviderError("unreachable", 503)
        except Exception as e:
            if type(e).__module__.startswith("meta_sam_parser"):
                raise ProviderError("bad_grounding", 502)  # the model spoke unparseable grammar
            raise ProviderError("provider_error", 503)
        if getattr(getattr(result, "outcome", None), "status", "") != "completed":
            raise ProviderError("bad_grounding", 502)
        return {"boxes": norm_boxes(getattr(result, "records", []), w, h), "model": self.s.sam_model}


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

    async def open(self, language_bias=None, keywords=None, api_key=None):
        import websockets
        key = api_key or self.s.model_api_key
        try:
            ws = await websockets.connect(f"{self.s.meta_asr_url}?sessionId=stream-{uuid.uuid4()}", max_size=2**20, open_timeout=10)
            hs = {"authorization": {"accessToken": f"Bearer {key}"}, "audioEncoding": "PCM_24KHZ", "model": self.s.voice_model,
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
