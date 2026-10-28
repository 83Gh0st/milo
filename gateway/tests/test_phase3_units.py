"""Phase 3 unit tests. Dependency-free: no fastapi/httpx/sqlalchemy/openai.
Run: python -m pytest tests/test_phase3_units.py --noconftest -p no:cacheprovider -o addopts='' -q -W ignore"""
import asyncio
import json
import sys

import pytest

sys.path.insert(0, ".")

from app.providers.base import FAILOVER_CODES, ProviderError, Usage, raise_for_status, redact
from app.providers.capabilities import DECLARED, Capabilities, ProbeResult
from app import datapolicy, egress
from app.providers import registry
from app.providers.registry import RouteEntry
from app import routing


class _NoTimeout:
    """No-op timeout context: the sandboxed runner cannot create an event
    loop (sockets blocked), so async tests drive coroutines directly and
    swap this in for routing._timeout. Real TimeoutErrors are still tested
    by having fakes raise them; only stdlib's own timer is untested."""

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


@pytest.fixture(autouse=True)
def _no_loop_timeout(monkeypatch):
    monkeypatch.setattr(routing, "_timeout", _NoTimeout)


def run(coro):
    """Drives a coroutine to completion with no event loop. Works because the
    tested paths await only plain coroutines/async-generators (no I/O, no
    sleeps, no futures); anything that truly suspends fails loudly."""
    try:
        coro.send(None)
    except StopIteration as e:
        return e.value
    raise RuntimeError("test coroutine suspended: needs a real event loop")


# ---------- error codes + redaction ----------

def test_raise_for_status_mapping():
    cases = [(401, "", "auth_failed", 502), (403, "", "auth_failed", 502), (404, "", "model_not_found", 502),
             (429, "", "rate_limited", 503), (429, "quota exceeded", "quota", 503), (429, "billing hard limit", "quota", 503),
             (422, "moderation flagged", "content_filtered", 502), (500, "", "provider_error", 503),
             (529, "", "provider_error", 503), (400, "", "provider_error", 502)]
    for status, body, code, http in cases:
        with pytest.raises(ProviderError) as e:
            raise_for_status("x", status, body)
        assert (e.value.code, e.value.status) == (code, http), status
    raise_for_status("x", 200)  # no raise


def test_failover_codes_never_include_auth_or_filter():
    assert "timeout" in FAILOVER_CODES and "rate_limited" in FAILOVER_CODES and "unreachable" in FAILOVER_CODES
    assert "auth_failed" not in FAILOVER_CODES and "content_filtered" not in FAILOVER_CODES


def test_redact():
    assert redact("key sk-abcdefgh1234 here", ["sk-abcdefgh1234"]) == "key [redacted] here"
    assert redact("short abc here", ["abc"]) == "short abc here"  # too short to be a secret
    assert redact("nothing", ["sk-abcdefgh1234"]) == "nothing"


# ---------- capabilities ----------

def test_capabilities_shape():
    assert set(Capabilities().as_dict()) == {"text_stream", "json_schema", "tool_calls", "vision", "audio_in", "tts", "image_gen", "realtime"}
    assert set(DECLARED) == {"meta", "openai", "anthropic", "custom", "mock"}
    assert DECLARED["mock"].text_stream and DECLARED["anthropic"].tool_calls and not DECLARED["anthropic"].tts


# ---------- egress ----------

def test_egress_allows_public_https():
    assert egress.check_base_url("https://api.example.com/v1/", env="prod", resolve=lambda h: ["93.184.216.34"]) == "https://api.example.com/v1"


def test_egress_rejects():
    with pytest.raises(ValueError):
        egress.check_base_url("http://api.example.com", env="prod", resolve=lambda h: ["93.184.216.34"])
    with pytest.raises(ValueError):  # private range in prod
        egress.check_base_url("https://x.test", env="prod", resolve=lambda h: ["192.168.1.5"])
    with pytest.raises(ValueError):  # cloud metadata
        egress.check_base_url("https://m.test", env="prod", resolve=lambda h: ["169.254.169.254"])
    with pytest.raises(ValueError):  # credentials embedded
        egress.check_base_url("https://user:pass@api.example.com", env="prod", resolve=lambda h: ["93.184.216.34"])
    with pytest.raises(ValueError):  # unresolvable
        egress.check_base_url("https://nope.invalid", env="prod", resolve=lambda h: [])
    with pytest.raises(ValueError):  # dev http still needs the explicit flag
        egress.check_base_url("http://127.0.0.1:11434", env="dev", resolve=lambda h: ["127.0.0.1"])


def test_egress_dev_lan_opt_in():
    assert egress.check_base_url("http://127.0.0.1:11434", env="dev", allow_lan=True, resolve=lambda h: ["127.0.0.1"])
    assert egress.check_base_url("http://192.168.1.9:1234/v1", env="dev", allow_lan=True, resolve=lambda h: ["192.168.1.9"])


# ---------- data policy ----------

def test_policies_require_ack_until_reviewed():
    for pid in ("meta", "openai", "anthropic"):
        p = datapolicy.POLICIES[pid]
        assert datapolicy.needs_ack(p) and p.checked_on == "unverified" and "NOT YET CHECKED" in p.source_url
    assert not datapolicy.needs_ack(datapolicy.POLICIES["mock"])


# ---------- registry ----------

def test_registry_ids_and_model_rules():
    assert registry.adapter_ids() == ["anthropic", "custom", "meta", "mock", "openai"]
    with pytest.raises(ValueError):
        registry.get_adapter("nope")
    assert registry.deny_model("x-contributor") is not None
    assert registry.deny_model("") is not None
    assert registry.deny_model("gpt-4o") is None
    with pytest.raises(ValueError):
        registry.check_model("openai", "gpt-4o-contributor")
    assert registry.resolve_strategy("auto", "tool_schema") == "tool_schema"
    assert registry.resolve_strategy("lines", "json_schema") == "lines"
    assert registry.resolve_strategy("auto", None) == "lines"


def test_adapters_import_without_web_stack():
    for pid in ("mock", "openai", "anthropic", "custom"):
        registry.get_adapter(pid)
    assert "httpx" not in sys.modules and "openai" not in sys.modules and "fastapi" not in sys.modules
    assert registry.get_adapter("custom").id == "custom"
    try:
        import openai  # noqa: F401
        from types import SimpleNamespace
        s = SimpleNamespace(spark_model="muse-spark", voice_model="muse-voice", image_model="muse-image",
                            model_api_key="x", meta_base_url="https://x.test/v1",
                            allowed_models={"muse-spark", "muse-voice", "muse-image"})
        assert registry.get_adapter("meta", s).id == "meta"
    except ImportError:
        import importlib
        mod = importlib.import_module("app.providers.meta_adapter")  # the module itself is dependency-free
        with pytest.raises(ImportError):  # documented: meta needs the openai package (CI/prod)
            mod.MetaAdapter(object())


# ---------- fake transport ----------

class FakeStream:
    def __init__(self, status, chunks):
        self.status, self._chunks, self.headers = status, chunks, {}

    async def __aiter__(self):
        for c in self._chunks:
            yield c


class FakeTransport:
    """Scripted transport: each post_stream pops the next (status, chunks)."""

    def __init__(self, script):
        self.script, self.posts, self.gets = list(script), [], []

    async def post_stream(self, url, headers, payload, timeout=30):
        self.posts.append({"url": url, "headers": headers, "payload": payload})
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        status, chunks = item
        return FakeStream(status, chunks)

    async def post_json(self, url, headers, payload, timeout=30):
        self.posts.append({"url": url, "headers": headers, "payload": payload})
        return self.script.pop(0)

    async def get_json(self, url, headers, timeout=15):
        self.gets.append(url)
        return self.script.pop(0)


def oai_chunk(text=None, usage=None):
    d = {"choices": [{"delta": {"content": text} if text else {}}]}
    if usage:
        d["usage"] = usage
    return ("data: " + json.dumps(d) + "\n\n").encode()


def anth_chunk(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


# ---------- openai_compat ----------

def test_openai_stream_and_usage():
    from app.providers.openai_compat import Creds, OpenAICompatAdapter
    t = FakeTransport([(200, [oai_chunk("Hel"), oai_chunk("lo"), oai_chunk(None, {"prompt_tokens": 10, "completion_tokens": 3, "prompt_tokens_details": {"cached_tokens": 4}}), b"data: [DONE]\n\n"])])
    a = OpenAICompatAdapter(transport=t)
    out = run(_collect(a.stream([{"role": "user", "content": "hi"}], creds=Creds("https://x.test/v1", "k"), model="gpt-x")))
    assert out == ["Hel", "lo", Usage(10, 4, 3)]
    assert "reasoning_effort" not in t.posts[0]["payload"]  # only reasoning models get it
    assert t.posts[0]["payload"]["max_completion_tokens"] == 900


def test_openai_legacy_token_retry_and_reasoning_flag():
    from app.providers.openai_compat import Creds, OpenAICompatAdapter
    t = FakeTransport([(400, [b"Invalid max_completion_tokens, use max_tokens"]), (200, [oai_chunk("ok"), b"data: [DONE]\n\n"])])
    a = OpenAICompatAdapter(transport=t)
    out = run(_collect(a.stream([{"role": "user", "content": "hi"}], creds=Creds("https://x.test/v1", "k"), model="o3-mini")))
    assert out[0] == "ok"
    assert "max_tokens" in t.posts[1]["payload"] and "max_completion_tokens" not in t.posts[1]["payload"]
    assert t.posts[1]["payload"]["reasoning_effort"] == "low"


def test_openai_errors_and_discovery():
    from app.providers.openai_compat import Creds, OpenAICompatAdapter
    a = OpenAICompatAdapter(transport=FakeTransport([(401, [b"bad key"])]))
    with pytest.raises(ProviderError) as e:
        run(_collect(a.stream([{"role": "user", "content": "hi"}], creds=Creds("https://x", "k"), model="m")))
    assert e.value.code == "auth_failed"
    a = OpenAICompatAdapter(transport=FakeTransport([(TimeoutError("t"))]))
    with pytest.raises(ProviderError) as e:
        run(_collect(a.stream([{"role": "user", "content": "hi"}], creds=Creds("https://x", "k"), model="m")))
    assert e.value.code == "timeout"
    a = OpenAICompatAdapter(transport=FakeTransport([(200, {"data": [{"id": "b"}, {"id": "a"}, {}]})]))
    assert run(a.discover_models(Creds("https://x", "k"))) == ["a", "b"]


async def _collect(agen):
    return [p async for p in agen]


# ---------- anthropic ----------

def test_anthropic_stream_system_tools_usage():
    from app.providers.anthropic import AnthropicAdapter
    from app.providers.openai_compat import Creds
    chunks = [anth_chunk("message_start", {"message": {"usage": {"input_tokens": 7}}}),
              anth_chunk("content_block_delta", {"delta": {"type": "text_delta", "text": "Hi"}}),
              anth_chunk("message_delta", {"usage": {"output_tokens": 2}})]
    a = AnthropicAdapter(transport=FakeTransport([(200, chunks)]))
    out = run(_collect(a.stream([{"role": "system", "content": "sys"}, {"role": "user", "content": "hi"}],
                                creds=Creds("https://a.test", "k"), model="claude-x")))
    assert out == ["Hi", Usage(7, 0, 2)]
    p = a._http.posts[0]["payload"]
    assert p["system"] == "sys" and all(m["role"] != "system" for m in p["messages"])
    # schema call uses the tool shape
    a2 = AnthropicAdapter(transport=FakeTransport([(200, [anth_chunk("content_block_delta", {"delta": {"type": "input_json_delta", "partial_json": "{\"ok\":"}}),
                                                                     anth_chunk("content_block_delta", {"delta": {"type": "input_json_delta", "partial_json": " true}"}})])]))
    out = run(_collect(a2.stream([{"role": "user", "content": "go"}], schema={"type": "object"}, creds=Creds("https://a.test", "k"), model="c")))
    assert "".join(p for p in out if isinstance(p, str)) == '{"ok": true}'
    assert a2._http.posts[0]["payload"]["tool_choice"] == {"type": "tool", "name": "milo_turn"}


def test_anthropic_quota_and_empty_discovery():
    from app.providers.anthropic import AnthropicAdapter
    from app.providers.openai_compat import Creds
    a = AnthropicAdapter(transport=FakeTransport([(400, [b"credit balance too low"])]))
    with pytest.raises(ProviderError) as e:
        run(_collect(a.stream([{"role": "user", "content": "hi"}], creds=Creds("https://a", "k"), model="c")))
    assert e.value.code == "quota"
    assert run(AnthropicAdapter(transport=FakeTransport([])).discover_models(Creds("https://a", "k"))) == []


# ---------- probes ----------

class _SmartFake:
    """Answers openai/anthropic probe calls by payload shape."""

    def __init__(self, kind):
        self.kind, self.posts = kind, []

    async def post_stream(self, url, headers, payload, timeout=30):
        self.posts.append(payload)
        msgs = json.dumps(payload.get("messages", []))
        if "Reply {" in msgs or "Call the tool." in msgs:
            if self.kind == "openai":
                return FakeStream(200, [oai_chunk('{"ok": true}'), b"data: [DONE]\n\n"])
            return FakeStream(200, [anth_chunk("content_block_delta", {"delta": {"type": "input_json_delta", "partial_json": '{"ok": true}'}})])
        if "image_url" in msgs or '"image"' in msgs:
            if self.kind == "openai":
                return FakeStream(200, [oai_chunk("a pixel"), b"data: [DONE]\n\n"])
            return FakeStream(200, [anth_chunk("content_block_delta", {"delta": {"type": "text_delta", "text": "a pixel"}})])
        if self.kind == "openai":
            return FakeStream(200, [oai_chunk("ok"), b"data: [DONE]\n\n"])
        return FakeStream(200, [anth_chunk("content_block_delta", {"delta": {"type": "text_delta", "text": "ok"}})])


def test_probes_pick_strategies():
    from app.providers.anthropic import AnthropicAdapter
    from app.providers.openai_compat import Creds, OpenAICompatAdapter
    r = run(OpenAICompatAdapter(transport=_SmartFake("openai")).probe(Creds("https://x", "k"), "m"))
    assert isinstance(r, ProbeResult) and r.ok and r.strategy == "json_schema" and r.checks["vision"] == "pass" and r.ttfb_ms >= 0
    r = run(AnthropicAdapter(transport=_SmartFake("anthropic")).probe(Creds("https://a", "k"), "c"))
    assert r.ok and r.strategy == "tool_schema" and r.checks["vision"] == "pass"


def test_probe_auth_failure_is_not_ok():
    from app.providers.openai_compat import Creds, OpenAICompatAdapter
    r = run(OpenAICompatAdapter(transport=FakeTransport([(401, [b"no"])] * 3)).probe(Creds("https://x", "bad"), "m"))
    assert not r.ok and r.checks["chat"] == "fail:auth_failed"


# ---------- mock adapter ----------

def test_mock_adapter_conformance_shape():
    from app.providers.mock_adapter import MockAdapter
    a = MockAdapter()
    out = run(_collect(a.stream([{"role": "system", "content": "x"}, {"role": "user", "content": "hello"}], model="mock")))
    assert isinstance(out[-1], Usage) and "".join(out[:-1])
    assert run(a.discover_models()) == ["mock"]
    r = run(a.probe())
    assert r.ok and r.strategy == "json_schema"


# ---------- router ----------

class _Scripted:
    """Adapter double: script of lists (yield) or exceptions (raise)."""

    def __init__(self, script):
        self.script, self.calls = list(script), 0

    async def stream(self, messages, **kw):
        self.calls += 1
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        for p in item:
            yield p


class _Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_router_failover_before_first_byte():
    r = routing.Router({"a": _Scripted([ProviderError("timeout", 504)]), "b": _Scripted([["hi", Usage(1, 0, 1)]])},
                       {"brain": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())
    p, m, strat, it = run(r.select_and_stream("brain", None, {"a": object(), "b": object()}, [{"role": "user", "content": "x"}]))
    assert (p, m) == ("b", "m2") and run(_collect(it)) == ["hi", Usage(1, 0, 1)]


def test_router_no_failover_after_first_byte_or_auth():
    r = routing.Router({"a": _Scripted([[ProviderError("timeout", 504)]]), "b": _Scripted([["unreached"]])},
                       {"brain": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())

    async def go():
        _, _, strat, it = await r.select_and_stream("brain", None, {"a": object(), "b": object()}, [])
        return [p async for p in it]

    got = run(go())
    assert len(got) == 1 and got[0].code == "timeout"  # yielded errors are data, not failures
    r2 = routing.Router({"a": _Scripted([ProviderError("auth_failed", 502)]), "b": _Scripted([["unreached"]])},
                        {"brain": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())
    with pytest.raises(ProviderError) as e:
        run(r2.select_and_stream("brain", None, {"a": object(), "b": object()}, []))
    assert e.value.code == "auth_failed"


def test_router_midstream_error_propagates():
    async def gen():
        yield "first"
        raise ProviderError("timeout", 504)

    class A:
        async def stream(self, messages, **kw):
            async for p in gen():
                yield p

    r = routing.Router({"a": A(), "b": _Scripted([["unreached"]])}, {"brain": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())

    async def go():
        _, _, strat, it = await r.select_and_stream("brain", None, {"a": object(), "b": object()}, [])
        return [p async for p in it]

    with pytest.raises(ProviderError) as e:
        run(go())
    assert e.value.code == "timeout"


def test_router_circuit_opens_and_half_opens():
    clk = _Clock()
    r = routing.Router({"a": _Scripted([ProviderError("timeout", 504)] * 5), "b": _Scripted([["ok"]] * 5)},
                       {"brain": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=clk)
    for _ in range(3):  # three failures open a's breaker
        p, _, strat, it = run(r.select_and_stream("brain", None, {"a": object(), "b": object()}, []))
        assert p == "b"
        run(_collect(it))
    assert r._circuits[("a", "m1")].is_open()
    calls = r.adapters["a"].calls
    p, _, strat, it = run(r.select_and_stream("brain", None, {"a": object(), "b": object()}, []))
    assert p == "b" and r.adapters["a"].calls == calls  # open: not even tried
    clk.t += 61  # window passes: half-open probe allowed
    p, _, strat, it = run(r.select_and_stream("brain", None, {"a": object(), "b": object()}, []))
    assert r.adapters["a"].calls == calls + 1


def test_router_skips_missing_caps_creds_and_empty():
    r = routing.Router({"a": _Scripted([["x"]])}, {"brain": [RouteEntry("a", "m1")]}, clock=_Clock())
    with pytest.raises(ProviderError) as e:  # probed caps lack text_stream
        run(r.select_and_stream("brain", None, {"a": object()}, [], caps_map={("a", "m1"): {"text_stream": False}}))
    assert e.value.code == "unsupported_capability"
    with pytest.raises(ProviderError) as e:  # no creds for a real provider
        run(r.select_and_stream("brain", None, {}, []))
    assert e.value.code == "unsupported_capability"
    r2 = routing.Router({}, {}, clock=_Clock())
    with pytest.raises(ProviderError) as e:
        run(r2.select_and_stream("brain", None, {}, []))
    assert e.value.code == "unsupported_capability"


def test_router_strategy_resolver_and_need_override():
    seen = {}

    class A:
        async def stream(self, messages, **kw):
            seen.update(kw)
            yield "x"

    def resolver(entry, probed):
        return registry.resolve_strategy(entry.strategy, probed)

    r = routing.Router({"a": A()}, {"brain": [RouteEntry("a", "m1", "lines")]}, clock=_Clock())
    p, m, strat, it = run(r.select_and_stream("brain", None, {"a": object()}, [], schema={"type": "object"},
                                              strategy_resolver=resolver))
    assert strat == "lines" and seen["schema"] is None  # lines entries get no schema
    run(_collect(it))
    r = routing.Router({"a": A()}, {"understand": [RouteEntry("a", "m1")]}, clock=_Clock())
    with pytest.raises(ProviderError) as e:  # image need, probed blind
        run(r.select_and_stream("understand", None, {"a": object()}, [], need="vision",
                                caps_map={("a", "m1"): {"vision": False}}))
    assert e.value.code == "unsupported_capability"


def test_cli_parses_and_never_takes_keys_as_argv():
    from app.cli import build_parser
    p = build_parser()
    assert p.parse_args(["connect", "openai", "--model", "m", "--yes"]).provider == "openai"
    assert p.parse_args(["use", "brain", "openai/m", "--fallback", "mock/mock"]).capability == "brain"
    assert p.parse_args(["test", "openai/m"]).target == "openai/m"
    for action in p._actions:
        assert "key" not in (action.dest or "") or action.dest in ("key_env", "key_stdin"), action.dest
    connect = [a for a in p._actions if isinstance(getattr(a, "choices", None), dict)][0].choices["connect"]
    flags = {a.dest for a in connect._actions}
    assert "key_env" in flags and "key_stdin" in flags and "key" not in flags  # never --key VALUE


def test_router_image_and_voice_failover():
    class Img:
        def __init__(self, script):
            self.script = script

        async def generate_image(self, prompt, creds=None, model=None):
            item = self.script.pop(0)
            if isinstance(item, Exception):
                raise item
            return item

    r = routing.Router({"a": Img([ProviderError("timeout", 504)]), "b": Img([b"png"])},
                       {"visual": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())
    assert run(r.generate_image(None, {"a": object(), "b": object()}, "cat")) == ("b", "m2", b"png")

    class V:
        def __init__(self, script):
            self.script = script

        async def open_voice(self, lb=None, kw=None, creds=None, model=None):
            item = self.script.pop(0)
            if isinstance(item, Exception):
                raise item
            return item

    r = routing.Router({"a": V([ProviderError("auth_failed", 502)]), "b": V(["sess"])},
                       {"stt": [RouteEntry("a", "m1"), RouteEntry("b", "m2")]}, clock=_Clock())
    with pytest.raises(ProviderError) as e:
        run(r.open_voice(None, {"a": object(), "b": object()}))
    assert e.value.code == "auth_failed"  # auth never fails over
