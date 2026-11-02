"""Anthropic Messages API adapter (streaming). Dependency-free module; HTTP
goes through an injected transport.

API-shape note: shapes follow the published Anthropic Messages +
streaming API. Endpoint shape verified live 2026-10-29 via a no-auth probe
(api.anthropic.com/v1/messages returns the documented 401
authentication_error envelope). Full keyed inference still needs a vendor
key (the in-app Test connection performs it). Terms in datapolicy.py.
"""
import json
import time

from .base import ProviderError, Usage, raise_for_status, TIMEOUT, UNREACHABLE, QUOTA
from .capabilities import ProbeResult

_MSG_PATH = "/v1/messages"
_VERSION = "2023-06-01"
_TOOL_NAME = "milo_turn"
_PIXEL_JPEG_B64 = ("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP////////////////////////////////////////////////////////////////////////////////////"
                   "//////////////////////////////////////////////////////////////wgARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQE"
                   "AAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AVQA//9k=")


def _split_system(messages):
    system, rest = [], []
    for m in messages:
        (system if m.get("role") == "system" else rest).append(m.get("content", "") if isinstance(m.get("content"), str) else "")
    return "\n".join(s for s in system if s), [{"role": "user" if m.get("role") != "assistant" else "assistant",
                                                "content": m.get("content", "")} for m in messages if m.get("role") != "system"] or [{"role": "user", "content": ""}]


def _vision_messages(messages, image_b64):
    out = [dict(m) for m in messages]
    for m in reversed(out):
        if m.get("role") == "user":
            text = m.get("content", "") if isinstance(m.get("content"), str) else ""
            m["content"] = [{"type": "text", "text": text},
                            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image_b64}}]
            return out
    return out


def _sse_events(buf):
    """Yields (kind, data) for Anthropic SSE: text deltas, tool-json deltas, usage."""
    event = None
    for line in buf.decode("utf-8", "replace").split("\n"):
        line = line.rstrip("\r")
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data = line[5:].strip()
            if not data:
                continue
            try:
                yield event, json.loads(data)
            except ValueError:
                pass
            event = None


class AnthropicAdapter:
    id = "anthropic"
    display_name = "Anthropic"

    def __init__(self, transport=None):
        from .http import default_transport
        self._http = transport or default_transport()

    def _headers(self, api_key):
        return {"x-api-key": api_key, "anthropic-version": _VERSION, "Content-Type": "application/json"}

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=None, creds, model, timeout=30):
        system, rest = _split_system(messages)
        payload = {"model": model, "max_tokens": max_tokens or 900, "messages": rest, "stream": True}
        if system:
            payload["system"] = system
        if schema:  # JSON via a tool schema (Anthropic has no response_format)
            payload["tools"] = [{"name": _TOOL_NAME, "description": "Milo's structured turn.", "input_schema": schema}]
            payload["tool_choice"] = {"type": "tool", "name": _TOOL_NAME}
        try:
            resp = await self._http.post_stream(creds.base_url + _MSG_PATH, self._headers(creds.api_key), payload, timeout)
        except TimeoutError:
            raise ProviderError(TIMEOUT, 504)
        except (ConnectionError, OSError):
            raise ProviderError(UNREACHABLE, 503)
        if resp.status != 200:
            body = b""
            async for c in resp:
                body += c
                if len(body) > 2000:
                    break
            txt = body.decode("utf-8", "replace")
            if resp.status == 400 and ("credit" in txt.lower() or "billing" in txt.lower()):
                raise ProviderError(QUOTA, 503)
            raise_for_status(self.id, resp.status, txt)
        usage = Usage()
        async for chunk in resp:
            for event, d in _sse_events(chunk):
                if event == "content_block_delta":
                    delta = d.get("delta", {})
                    if delta.get("type") == "text_delta" and delta.get("text"):
                        yield delta["text"]
                    elif delta.get("type") == "input_json_delta" and delta.get("partial_json"):
                        yield delta["partial_json"]
                elif event == "message_start":
                    u = (d.get("message") or {}).get("usage") or {}
                    usage = Usage(u.get("input_tokens") or 0, 0, usage.completion)
                elif event == "message_delta":
                    u = d.get("usage") or {}
                    usage = Usage(usage.prompt, 0, u.get("output_tokens") or usage.completion)
        yield usage

    async def discover_models(self, creds):
        # Documented GET /v1/models (same auth headers as messages). Shape per
        # the published API; keyed listing is exercised by the family's own
        # Find models (no vendor key here to live-verify against).
        try:
            status, data = await self._http.get_json(creds.base_url + "/v1/models", self._headers(creds.api_key))
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
            async for piece in self.stream([{"role": "user", "content": "Call the tool."}], schema=schema, creds=creds, model=model, max_tokens=64, timeout=20):
                if isinstance(piece, str):
                    buf += piece
            json.loads(buf.strip())
            checks["tool_schema"] = "pass"
        except (ProviderError, ValueError) as e:
            checks["tool_schema"] = f"fail:{getattr(e, 'code', 'bad_json')}"
        try:
            msgs = _vision_messages([{"role": "user", "content": "What is this?"}], _PIXEL_JPEG_B64)
            async for _ in self.stream(msgs, creds=creds, model=model, max_tokens=8, timeout=20):
                pass
            checks["vision"] = "pass"
        except ProviderError as e:
            checks["vision"] = f"skipped:{e.code}" if e.code in ("provider_error", "model_not_found") else f"fail:{e.code}"
        strategy = "tool_schema" if checks.get("tool_schema") == "pass" else "lines"
        return ProbeResult(self.id, model, True, ttfb, strategy, checks)
