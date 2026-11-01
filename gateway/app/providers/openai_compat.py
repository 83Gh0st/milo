"""OpenAI-compatible chat adapter: OpenAI, Meta's OpenAI-compatible endpoint,
and other OpenAI-compatible providers or local servers (Ollama, LM Studio,
vLLM). Dependency-free module; HTTP goes through an injected transport.

API-shape note: request/response shapes follow the published OpenAI Chat
Completions + Models API. Endpoint shapes verified live 2026-10-29 via
no-auth probes (api.openai.com/v1/models returns the documented 401
invalid_request_error envelope; api.meta.ai/v1/models returns an
OpenAI-compatible 401). Full keyed inference still needs a vendor key
(the in-app Test connection performs it). Terms recorded in datapolicy.py.
"""
import json
import time
from dataclasses import dataclass

from .base import ProviderError, Usage, raise_for_status, TIMEOUT, UNREACHABLE
from .capabilities import Capabilities, ProbeResult

_CHAT_PATH = "/chat/completions"
_MODELS_PATH = "/models"
# Models that accept reasoning parameters (conservative list: unknown
# prefixes simply omit the parameter, which every model accepts).
_REASONING_PREFIXES = ("o1", "o3", "o4", "gpt-5")
# 1x1 red JPEG for the vision probe (no image library needed).
_PIXEL_JPEG = ("data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP////////////////////////////////////////////////////////////////////////////////////"
               "//////////////////////////////////////////////////////////////wgARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQE"
               "AAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AVQA//9k=")


@dataclass(frozen=True)
class Creds:
    base_url: str
    api_key: str
    model: str = ""


def _vision_messages(messages, image_b64_or_url):
    """Rewrites the last user message into OpenAI vision content blocks."""
    out = [dict(m) for m in messages]
    for m in reversed(out):
        if m.get("role") == "user":
            url = image_b64_or_url if str(image_b64_or_url).startswith("data:") else f"data:image/jpeg;base64,{image_b64_or_url}"
            m["content"] = [{"type": "text", "text": m.get("content", "") if isinstance(m.get("content"), str) else ""},
                            {"type": "image_url", "image_url": {"url": url}}]
            return out
    return out


def _sse_texts(buf):
    """Yields (content, usage_dict) from one SSE byte chunk (stdlib parser)."""
    for line in buf.decode("utf-8", "replace").split("\n"):
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            d = json.loads(data)
        except ValueError:
            continue
        ch = (d.get("choices") or [{}])[0]
        delta = ch.get("delta") or {}
        if delta.get("content"):
            yield delta["content"], None
        if d.get("usage"):
            yield None, d["usage"]


class OpenAICompatAdapter:
    id = "openai"
    display_name = "OpenAI-compatible"

    def __init__(self, transport=None):
        from .http import default_transport
        self._http = transport or default_transport()

    def capabilities(self):
        return Capabilities(text_stream=True, json_schema=True, tool_calls=True, vision=True)

    def _headers(self, creds):
        return {"Authorization": f"Bearer {creds.api_key}", "Content-Type": "application/json"}

    def _payload_extra(self, model):
        """Vendor-specific payload additions. Base: none; subclasses (the
        Modal-hosted adapter) override without touching shared code."""
        return {}

    _default_max_tokens = 900

    def _payload(self, model, messages, *, schema, effort, max_tokens, use_legacy_tokens=False):
        max_tokens = max_tokens or self._default_max_tokens
        kw = {"model": model, "messages": messages, "stream": True, "stream_options": {"include_usage": True}}
        kw["max_tokens" if use_legacy_tokens else "max_completion_tokens"] = max_tokens
        if any(model.startswith(p) for p in _REASONING_PREFIXES):
            kw["reasoning_effort"] = effort
        if schema:
            kw["response_format"] = {"type": "json_schema", "json_schema": {"name": "milo_turn", "schema": schema, "strict": True}}
        kw.update(self._payload_extra(model))
        return kw

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=None, creds, model, timeout=30):
        payload = self._payload(model, messages, schema=schema, effort=effort, max_tokens=max_tokens)
        t0, connect_ms, ttft_ms = time.monotonic(), 0, 0
        for attempt in (False, True):  # new token param, then legacy on a 400 hint
            if attempt:
                payload = self._payload(model, messages, schema=schema, effort=effort, max_tokens=max_tokens, use_legacy_tokens=True)
            try:
                t_post = time.monotonic()
                resp = await self._http.post_stream(creds.base_url + _CHAT_PATH, self._headers(creds), payload, timeout)
                connect_ms = int((time.monotonic() - t_post) * 1000)
            except TimeoutError:
                raise ProviderError(TIMEOUT, 504)
            except (ConnectionError, OSError):
                raise ProviderError(UNREACHABLE, 503)
            if resp.status == 400 and not attempt:
                peek = b""
                async for c in resp:
                    peek += c
                    break
                if b"max_tokens" in peek.lower() or b"max_completion_tokens" in peek.lower():
                    continue
                raise_for_status(self.id, 400, peek.decode("utf-8", "replace"))
            if resp.status != 200:
                body = b""
                async for c in resp:
                    body += c
                    if len(body) > 2000:
                        break
                raise_for_status(self.id, resp.status, body.decode("utf-8", "replace"))
            usage = Usage()
            async for chunk in resp:
                for text, u in _sse_texts(chunk):
                    if text:
                        if not ttft_ms:
                            ttft_ms = int((time.monotonic() - t0) * 1000)
                        yield text
                    if u:
                        usage = Usage(u.get("prompt_tokens") or 0, (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0,
                                      u.get("completion_tokens") or 0, connect_ms, ttft_ms)
            usage.connect_ms, usage.ttft_ms = connect_ms, ttft_ms  # timing survives even without a usage chunk
            yield usage
            return

    async def discover_models(self, creds):
        try:
            status, data = await self._http.get_json(creds.base_url + _MODELS_PATH, self._headers(creds))
        except TimeoutError:
            raise ProviderError(TIMEOUT, 504)
        except (ConnectionError, OSError):
            raise ProviderError(UNREACHABLE, 503)
        if status != 200:
            raise_for_status(self.id, status, json.dumps(data)[:300])
        return sorted({m["id"] for m in data.get("data", []) if isinstance(m, dict) and m.get("id")}) or []

    async def probe(self, creds, model):
        checks, t0, ttfb = {}, time.monotonic(), -1
        try:
            first = True
            async for piece in self.stream([{"role": "user", "content": "Reply with exactly: ok"}], creds=creds, model=model, max_tokens=8, timeout=20):
                if first and isinstance(piece, str):
                    ttfb = int((time.monotonic() - t0) * 1000)
                    first = False
            checks["chat"] = "pass"
        except ProviderError as e:
            checks["chat"] = f"fail:{e.code}"
            return ProbeResult(self.id, model, False, ttfb, "lines", checks)
        schema = {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}
        try:
            buf = ""
            async for piece in self.stream([{"role": "user", "content": "Reply {\"ok\": true}."}], schema=schema, creds=creds, model=model, max_tokens=32, timeout=20):
                if isinstance(piece, str):
                    buf += piece
            json.loads(buf.strip())
            checks["json_schema"] = "pass"
        except (ProviderError, ValueError) as e:
            checks["json_schema"] = f"fail:{getattr(e, 'code', 'bad_json')}"
        try:
            msgs = _vision_messages([{"role": "user", "content": "What is this?"}], _PIXEL_JPEG)
            async for _ in self.stream(msgs, creds=creds, model=model, max_tokens=8, timeout=20):
                pass
            checks["vision"] = "pass"
        except ProviderError as e:
            checks["vision"] = f"skipped:{e.code}" if e.code in ("provider_error", "model_not_found") else f"fail:{e.code}"
        strategy = "json_schema" if checks.get("json_schema") == "pass" else "lines"
        return ProbeResult(self.id, model, True, ttfb, strategy, checks)
