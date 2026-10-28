"""Capability routing with failover and circuit breakers. Dependency-free
(asyncio/time/dataclasses only); adapters are duck-typed.

- Each capability (brain, understand, plan, compose, visual, stt, tts) has an
  ordered route list of (provider, model). Entries whose probed capabilities
  lack the need are skipped honestly (never claimed).
- Failover retries the next entry only when nothing was yielded yet and the
  error code is failover-eligible (timeout, 429, 5xx, unreachable). Auth,
  content-filter and post-first-byte errors propagate immediately.
- Circuit breaker per (provider, model): opens after 3 failures in 60 s;
  half-open probe after the window. Clock is injectable for tests.
- Clients never choose providers; the server uses the saved routes.
"""
import asyncio
import time

from .providers.base import FAILOVER_CODES, ProviderError

WINDOW_S = 60
FAILURES_TO_OPEN = 3
_timeout = asyncio.timeout  # injectable: unit tests swap in a no-op (no event loop needed)


class Circuit:
    def __init__(self, clock=time.monotonic):
        self._clock, self._fails = clock, []

    def is_open(self) -> bool:
        now = self._clock()
        self._fails = [t for t in self._fails if now - t < WINDOW_S]
        return len(self._fails) >= FAILURES_TO_OPEN

    def record_ok(self):
        self._fails = []

    def record_fail(self):
        self._fails.append(self._clock())


class Router:
    def __init__(self, adapters: dict, default_routes: dict, clock=time.monotonic):
        self.adapters, self.default_routes, self._clock = adapters, default_routes, clock
        self._circuits: dict[tuple[str, str], Circuit] = {}
        self.last_route: tuple[str, str] | None = None  # (provider, model) of the latest attempt

    def _circuit(self, provider, model) -> Circuit:
        return self._circuits.setdefault((provider, model), Circuit(self._clock))

    def _entries(self, capability, routes):
        routes = routes or {}
        return list(routes.get(capability) or self.default_routes.get(capability) or [])

    def entries_for(self, capability, routes):
        """Public read of the route list (prompt building peeks at it)."""
        return self._entries(capability, routes)

    async def _first(self, agen, timeout):
        """Pulls the first item (or raises the entry's error) with a timeout."""
        try:
            async with _timeout(timeout):
                return await agen.__anext__()
        except StopAsyncIteration:
            return None

    async def select_and_stream(self, capability, routes, creds_map, messages, *, schema=None, effort="low",
                                max_tokens=None, timeout=30, caps_map=None, need=None, strategy_resolver=None):
        """Returns (provider, model, strategy, async-iterator). Failover
        happens before the first byte; afterwards errors stream to the caller.
        [need] overrides the capability's default need (understand-with-image
        requires vision). [strategy_resolver] maps (entry, probed) to the
        output strategy; the schema is sent only for json/tool strategies."""
        from .providers.registry import CAPABILITIES_NEEDED
        need = need or CAPABILITIES_NEEDED[capability]
        entries = self._entries(capability, routes)
        if not entries:
            raise ProviderError("unsupported_capability", 502)
        last_err = ProviderError("unsupported_capability", 502)
        for e in entries:
            provider, model = e.provider, e.model
            probed = (caps_map or {}).get((provider, model)) or {}
            if caps_map is not None and not probed.get(need, True):
                last_err = ProviderError("unsupported_capability", 502)
                continue
            adapter = self.adapters.get(provider)
            creds = (creds_map or {}).get(provider)
            if adapter is None or (creds is None and provider not in ("mock",)):
                last_err = ProviderError("unsupported_capability", 502)
                continue
            if self._circuit(provider, model).is_open():
                last_err = ProviderError("provider_error", 503)
                continue
            strategy = strategy_resolver(e, probed.get("strategy")) if strategy_resolver else "json_schema"
            use_schema = schema if strategy in ("json_schema", "tool_schema") else None
            self.last_route = (provider, model)
            try:
                agen = adapter.stream(messages, schema=use_schema, effort=effort, max_tokens=max_tokens, creds=creds, model=model)
                first = await self._first(agen.__aiter__() if hasattr(agen, "__aiter__") else agen, timeout)
            except TimeoutError:
                self._circuit(provider, model).record_fail()
                last_err = ProviderError("timeout", 504)
                continue
            except ProviderError as e:
                self._circuit(provider, model).record_fail()
                last_err = e
                if e.code not in FAILOVER_CODES:
                    raise
                continue
            except Exception:
                self._circuit(provider, model).record_fail()
                last_err = ProviderError("provider_error", 503)
                continue
            self._circuit(provider, model).record_ok()

            async def chained(first=first, agen=agen):
                if first is not None:
                    yield first
                async for piece in agen:
                    yield piece

            return provider, model, strategy, chained()
        raise last_err

    async def generate_image(self, routes, creds_map, prompt, timeout=60, caps_map=None):
        last_err = ProviderError("unsupported_capability", 502)
        for e in self._entries("visual", routes):
            provider, model = e.provider, e.model
            if caps_map is not None and not (caps_map.get((provider, model)) or {}).get("image_gen", True):
                continue
            adapter = self.adapters.get(provider)
            if adapter is None or not hasattr(adapter, "generate_image"):
                continue
            if self._circuit(provider, model).is_open():
                last_err = ProviderError("provider_error", 503)
                continue
            self.last_route = (provider, model)
            try:
                async with _timeout(timeout):
                    out = await adapter.generate_image(prompt, creds=(creds_map or {}).get(provider), model=model)
                self._circuit(provider, model).record_ok()
                return provider, model, out
            except TimeoutError:
                last_err = ProviderError("timeout", 504)
            except ProviderError as e:
                last_err = e
                if e.code not in FAILOVER_CODES:
                    raise
            except Exception:
                last_err = ProviderError("provider_error", 503)
            self._circuit(provider, model).record_fail()
        raise last_err

    async def open_voice(self, routes, creds_map, language_bias=None, keywords=None, timeout=15, caps_map=None):
        last_err = ProviderError("unsupported_capability", 502)
        for e in self._entries("stt", routes):
            provider, model = e.provider, e.model
            if caps_map is not None and not (caps_map.get((provider, model)) or {}).get("audio_in", True):
                continue
            adapter = self.adapters.get(provider)
            if adapter is None or not hasattr(adapter, "open_voice"):
                continue
            if self._circuit(provider, model).is_open():
                last_err = ProviderError("provider_error", 503)
                continue
            self.last_route = (provider, model)
            try:
                async with _timeout(timeout):
                    sess = await adapter.open_voice(language_bias, keywords, creds=(creds_map or {}).get(provider), model=model)
                self._circuit(provider, model).record_ok()
                return provider, model, sess
            except TimeoutError:
                last_err = ProviderError("timeout", 504)
            except ProviderError as e:
                last_err = e
                if e.code not in FAILOVER_CODES:
                    raise
            except Exception:
                last_err = ProviderError("provider_error", 503)
            self._circuit(provider, model).record_fail()
        raise last_err
