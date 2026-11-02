"""Provider capabilities and probe results. Dependency-free (stdlib only) so
unit tests can import it without the web stack."""
import re
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Capabilities:
    text_stream: bool = False
    json_schema: bool = False
    tool_calls: bool = False
    vision: bool = False
    audio_in: bool = False
    tts: bool = False
    image_gen: bool = False
    realtime: bool = False
    visual_ground: bool = False  # SAM-style "point at the words" boxes (P2; mock only until docs verified)

    def as_dict(self) -> dict:
        return {k: getattr(self, k) for k in (
            "text_stream", "json_schema", "tool_calls", "vision", "audio_in", "tts", "image_gen", "realtime", "visual_ground")}


@dataclass
class ProbeResult:
    provider: str
    model: str
    ok: bool
    ttfb_ms: int = -1
    strategy: str = "lines"  # json_schema | tool_schema | lines
    checks: dict = field(default_factory=dict)  # name -> "pass" | "fail:reason" | "skipped:reason"

    def as_dict(self) -> dict:
        return {"provider": self.provider, "model": self.model, "ok": self.ok,
                "ttfb_ms": self.ttfb_ms, "strategy": self.strategy, "checks": self.checks}


# Declared (static) capabilities per adapter id. probe() refines these per
# model; the router only ever offers what the probe confirmed.
DECLARED = {
    "meta": Capabilities(text_stream=True, json_schema=True, vision=True, audio_in=True, image_gen=True, realtime=True),
    "openai": Capabilities(text_stream=True, json_schema=True, tool_calls=True, vision=True, audio_in=True, tts=True, image_gen=True),
    "anthropic": Capabilities(text_stream=True, tool_calls=True, vision=True),
    "custom": Capabilities(text_stream=True, json_schema=True, tool_calls=True, vision=True, audio_in=True, tts=True, image_gen=True),
    "modal": Capabilities(text_stream=True, json_schema=True),
    "mock": Capabilities(text_stream=True, json_schema=True, vision=True, audio_in=True, image_gen=True, visual_ground=True),
}

DISPLAY_NAMES = {"meta": "Meta", "openai": "OpenAI", "anthropic": "Anthropic", "custom": "Custom / local",
                 "modal": "Milo hosted", "mock": "Mock (offline demo)"}

_ACRONYMS = {"gpt", "tts", "stt", "api", "xl", "xs", "os"}


def friendly_model_name(model_id: str) -> str:
    """Parent-readable label for a model id. No curated vendor list to go
    stale: last path segment, separators to spaces, gentle casing that
    preserves existing capitals (4o stays 4o) and version dots (1.3)."""
    seg = (model_id or "").split("/")[-1].strip()
    if not seg:
        return "Unknown model"
    out = []
    for w in re.split(r"[-_]+", seg):
        if not w:
            continue
        if w != w.lower() or w.replace(".", "").isdigit():
            out.append(w)  # Muse, Open, 816B, 1.3 untouched
        elif w in _ACRONYMS:
            out.append(w.upper())
        else:
            out.append(w[:1].upper() + w[1:])
    return " ".join(out) or "Unknown model"
