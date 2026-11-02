"""Provider registry: adapter protocol, lazy loading, model rules, output
strategies. Dependency-free module (typing only); adapter classes are
imported on demand so unit tests never need httpx/openai/fastapi.
"""
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

STRATEGIES = ("json_schema", "tool_schema", "lines")
CAPABILITIES_NEEDED = {"brain": "text_stream", "understand": "text_stream", "plan": "text_stream",
                       "compose": "text_stream", "story": "text_stream", "visual": "image_gen", "segment": "visual_ground", "stt": "audio_in", "tts": "tts"}


@dataclass(frozen=True)
class RouteEntry:
    provider: str
    model: str
    strategy: str = "auto"  # auto | json_schema | tool_schema | lines


@runtime_checkable
class ProviderAdapter(Protocol):
    id: str
    display_name: str

    async def stream(self, messages, *, schema=None, effort: str = "low", max_tokens=None, creds=None, model=None): ...
    async def discover_models(self, creds=None): ...
    async def probe(self, creds=None, model=None): ...


_LOADERS = {"meta": ("app.providers.meta_adapter", "MetaAdapter"),
            "openai": ("app.providers.openai_compat", "OpenAICompatAdapter"),
            "anthropic": ("app.providers.anthropic", "AnthropicAdapter"),
            "custom": ("app.providers.openai_compat", "OpenAICompatAdapter"),
            "modal": ("app.providers.modal_hosted", "ModalAdapter"),
            "mock": ("app.providers.mock_adapter", "MockAdapter")}
_CACHE = {}


def adapter_ids() -> list[str]:
    return sorted(_LOADERS)


def get_adapter(provider: str, *args, **kwargs):
    """Instantiates (and caches, when constructed without args) the adapter."""
    if provider not in _LOADERS:
        raise ValueError(f"unknown provider: {provider}")
    if not args and not kwargs and provider in _CACHE:
        return _CACHE[provider]
    mod_name, cls_name = _LOADERS[provider]
    import importlib
    cls = getattr(importlib.import_module(mod_name), cls_name)
    inst = cls(*args, **kwargs)
    if provider == "custom":
        inst.id, inst.display_name = "custom", "Custom / local"
    if not args and not kwargs:
        _CACHE[provider] = inst
    return inst


def get_adapter_for(provider: str, settings):
    """Settings-aware construction: only the meta adapter needs suite
    settings (endpoint URLs); every other adapter builds with no args
    (their first constructor parameter is an HTTP transport, NOT
    settings, so passing settings blindly would corrupt them)."""
    if provider == "meta":
        return get_adapter(provider, settings)
    return get_adapter(provider)


def deny_model(model: str) -> str | None:
    """Global model deny rules. Returns the reason, or None when allowed."""
    if not model or not model.strip():
        return "empty model id"
    if model.strip().endswith("-contributor"):
        return "contributor variants would train on children's data"
    return None


def check_model(provider: str, model: str) -> None:
    why = deny_model(model)
    if why:
        raise ValueError(f"model id not allowed: {why}")


def resolve_strategy(entry_strategy: str, probe_strategy: str | None) -> str:
    """Per-model output strategy: an explicit route strategy wins, else the
    probe's result, else lines. The contract validator stays the only gate."""
    if entry_strategy in STRATEGIES and entry_strategy != "auto":
        return entry_strategy
    if probe_strategy in STRATEGIES:
        return probe_strategy
    return "lines"
