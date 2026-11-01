"""Sync unit tests for hosted-model wiring, spend backends, and family
credential isolation helpers. Runnable anywhere (no event loop). Async
end-to-end coverage lives in test_hosted_async.py (CI)."""
import pytest

from app.config import Settings, validate_runtime
from app.connections import _adapter, _check_provider
from app.main import create_app
from app.providers.capabilities import DECLARED
from app.providers.meta_adapter import MetaAdapter
from app.providers.modal_hosted import ModalAdapter
from app.providers.openai_compat import OpenAICompatAdapter
from app.providers.registry import adapter_ids, get_adapter_for
from app.spend import effective_limits, resolve_backend_name
from fastapi import HTTPException


def test_spend_backend_resolution():
    base = dict(database_url="", spend_dict_name="")
    assert resolve_backend_name(Settings(**base, spend_backend="postgres")) == "postgres"
    assert resolve_backend_name(Settings(**base, spend_backend="modal_dict")) == "modal_dict"
    assert resolve_backend_name(Settings(**base, spend_backend="memory")) == "memory"
    assert resolve_backend_name(Settings(**base)) == "memory"  # nothing configured: ephemeral
    assert resolve_backend_name(Settings(database_url="sqlite+aiosqlite:///:memory:")) == "postgres"
    assert resolve_backend_name(Settings(database_url="", spend_dict_name="milo-spend")) == "modal_dict"


def test_ephemeral_ceilings_always_bind_memory():
    s = Settings(database_url="", daily_budget_usd=1000.0, monthly_budget_usd=1000.0,
                 ephemeral_day_usd=5.0, ephemeral_month_usd=20.0)
    assert effective_limits(s, "memory") == (5.0, 20.0)
    assert effective_limits(s, "postgres") == (1000.0, 1000.0)
    assert effective_limits(s, "modal_dict") == (1000.0, 1000.0)
    s2 = Settings(database_url="", daily_budget_usd=1.0, monthly_budget_usd=2.0)
    assert effective_limits(s2, "memory") == (1.0, 2.0)  # lower configured caps still win


def test_modal_adapter_registered_and_routed():
    kw = dict(env="dev", provider="mock", jwt_secret="x" * 40, database_url="",
              modal_models_url="https://spark-test.modal.msp.run", modal_models_key="k" * 16,
              modal_model="meta-models/Muse-Spark-Open-816B-A42B", reasoning_provider="modal")
    app = create_app(Settings(**kw))
    assert "modal" in app.state.adapters
    assert app.state.deployer_creds["modal"].base_url == "https://spark-test.modal.msp.run"
    first = app.state.default_routes["brain"][0]
    assert (first.provider, first.model) == ("modal", "meta-models/Muse-Spark-Open-816B-A42B")
    assert len(app.state.default_routes["brain"]) == 2  # suite fallback by default
    assert app.state.default_routes["visual"][0].provider == "mock"  # image/voice stay on the suite
    strict = create_app(Settings(**kw, modal_fallback=False))
    assert [e.provider for e in strict.state.default_routes["brain"]] == ["modal"]  # staging: loud failures
    suite = create_app(Settings(**{**kw, "reasoning_provider": ""}))
    assert [e.provider for e in suite.state.default_routes["brain"]] == ["mock"]  # registered but unused
    validate_runtime(Settings(**kw))  # dev settings validate


def test_modal_default_max_tokens_fits_reasoning():
    modal = ModalAdapter()
    assert modal._payload("m", [], schema=None, effort="low", max_tokens=None)["max_completion_tokens"] == 2000
    assert modal._payload("m", [], schema=None, effort="low", max_tokens=10)["max_completion_tokens"] == 10
    assert OpenAICompatAdapter()._payload("m", [], schema=None, effort="low", max_tokens=None)["max_completion_tokens"] == 900


def test_modal_payload_adapter_extras():
    modal = ModalAdapter()
    spark = modal._payload("meta-models/Muse-Spark-Open-816B-A42B", [{"role": "user", "content": "hi"}], schema=None, effort="low", max_tokens=10)
    assert "chat_template_kwargs" not in spark  # Shared Endpoint: plain OpenAI body
    assert spark["stream"] is True and spark["model"] == "meta-models/Muse-Spark-Open-816B-A42B"
    qwen = modal._payload("Qwen/Qwen3-4B-Instruct-2507", [], schema=None, effort="low", max_tokens=10)
    assert qwen["chat_template_kwargs"] == {"enable_thinking": False}  # legacy self-host flag only
    base = OpenAICompatAdapter()._payload("gpt-x", [], schema=None, effort="low", max_tokens=10)
    assert "chat_template_kwargs" not in base  # shared vendors untouched
    assert ModalAdapter().capabilities().vision is False
    assert DECLARED["modal"].json_schema is True


def test_modal_is_deployer_only_and_known():
    assert "modal" in adapter_ids()
    with pytest.raises(HTTPException):
        _check_provider("modal")  # families can never save a modal connection
    with pytest.raises(HTTPException):
        _check_provider("launch_missiles")


def test_settings_aware_construction():
    s = Settings()
    assert isinstance(_adapter("meta", s), MetaAdapter)  # meta needs suite settings (endpoint URLs)
    assert get_adapter_for("openai", None).id == "openai"  # the rest build with no args, settings never as transport
    with pytest.raises(HTTPException):
        _adapter("modal", s)
