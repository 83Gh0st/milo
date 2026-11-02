import re
from typing import Literal
from pydantic import BaseModel, Field, field_validator

Pres = Literal["playful", "friendly", "discreet"]


class SessionReq(BaseModel):
    install_id: str = Field(min_length=16, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    app_version: str = Field(max_length=20)
    platform: Literal["android", "ios", "web", "other"] = "other"


class Turn(BaseModel):
    role: Literal["user", "milo"]
    text: str = Field(max_length=600)


class Chip(BaseModel):
    kind: str = Field(max_length=20)
    label: str = Field(max_length=80)
    text: str = Field(default="", max_length=3000)


class Mem(BaseModel):
    key: str = Field(max_length=40)
    value: str = Field(max_length=80)


class BrainReq(BaseModel):
    presentation: Pres = "friendly"
    support: dict[str, str] = Field(default_factory=dict, max_length=8)
    lang: str = Field(default="English", max_length=30)
    name: str | None = Field(default=None, max_length=30)
    activity: Literal["home", "understand", "express", "do", "chat"] = "chat"
    chips: list[Chip] = Field(default_factory=list, max_length=6)
    memories: list[Mem] = Field(default_factory=list, max_length=5)
    recent: list[Turn] = Field(default_factory=list, max_length=6)
    text: str = Field(default="", max_length=800)
    ui_context: dict = Field(default_factory=dict)

    @field_validator("support")
    @classmethod
    def _short(cls, v):
        return {k[:20]: x[:40] for k, x in v.items()}

    @field_validator("ui_context")
    @classmethod
    def _ui_context(cls, v):
        # Flat snapshot of the client's activity panel (activity id, last
        # action, component values). Bounded and scalar-only: never a tree.
        import re as _re

        out = {}
        for k, x in list(v.items())[:12]:
            if not isinstance(k, str) or _re.fullmatch(r"[A-Za-z0-9_-]{1,32}", k) is None:
                continue
            if isinstance(x, bool):
                out[k] = x
            elif isinstance(x, str):
                out[k] = x[:500]
            elif isinstance(x, (int, float)):
                out[k] = x
        return out


class UnderstandReq(BrainReq):
    content_text: str | None = Field(default=None, max_length=6000)
    image_b64: str | None = None
    strategy: Literal["default", "simpler", "picture", "example", "short"] = "default"


class PlanReq(BaseModel):
    goal: str = Field(min_length=2, max_length=200)
    presentation: Pres = "friendly"
    lang: str = Field(default="English", max_length=30)


class ComposeReq(BaseModel):
    strip: list[str] = Field(min_length=1, max_length=20)
    presentation: Pres = "friendly"
    lang: str = Field(default="English", max_length=30)


StoryMode = Literal["new", "continue", "ending", "answer"]
StoryLen = Literal["short", "medium", "long"]


class StoryPage(BaseModel):
    heading: str = Field(default="", max_length=80)
    text: str = Field(default="", max_length=2000)


class StoryReq(BaseModel):
    mode: StoryMode = "new"
    theme: str = Field(default="", max_length=80)
    characters: list[str] = Field(default=[], max_length=4)
    setting: str = Field(default="", max_length=80)
    length: StoryLen = "short"
    pages: list[StoryPage] = Field(default=[], max_length=10)  # prior pages for continue/ending/answer
    question: str = Field(default="", max_length=200)
    presentation: Pres = "friendly"
    lang: str = Field(default="English", max_length=30)


class VisualReq(BaseModel):
    concept: str = Field(max_length=30)


class ImageReq(BaseModel):
    prompt: str = Field(min_length=2, max_length=300)


class SegmentReq(BaseModel):
    image_b64: str = Field(min_length=100, max_length=7_000_000)  # ~5 MB decoded, under max_body_bytes
    phrase: str = Field(min_length=2, max_length=60)  # one short noun phrase ("heart", "red boat")


class SpeakReq(BaseModel):
    text: str = Field(min_length=1, max_length=500)  # one sentence; the phone pipelines sentences
    lang: str = Field(default="en", max_length=8)
    profile: str = Field(default="milo_warm_en", max_length=32)  # stable voice identity, independent of the brain
    voice_id: str = Field(default="", max_length=128)  # engine voice override (bake-off winner fills profiles instead)
    style: dict = Field(default_factory=dict)  # {emotion, pace}: hints, honoured only where the engine supports them
    sentence_id: str = Field(default="", max_length=32)  # echoed in the sideband for client queueing


class VaultCreate(BaseModel):
    pass


class ProviderKeyReq(BaseModel):
    provider: Literal["meta", "openai", "anthropic", "custom"] = "meta"
    api_key: str = Field(min_length=8, max_length=500)


class ConnectionReq(BaseModel):
    api_key: str | None = Field(default=None, min_length=8, max_length=2000)
    base_url: str | None = Field(default=None, max_length=500)
    default_model: str | None = Field(default=None, max_length=128)
    ack_data_policy: bool = False  # required when the provider's policy is yes/unknown


class RouteEntryReq(BaseModel):
    provider: Literal["meta", "openai", "anthropic", "custom", "mock"]
    model: str = Field(min_length=1, max_length=128)
    strategy: Literal["auto", "json_schema", "tool_schema", "lines"] = "auto"


class RoutesReq(BaseModel):
    routes: dict[str, list[RouteEntryReq]] = Field(max_length=7)


class ProbeReq(BaseModel):
    model: str | None = Field(default=None, max_length=128)


class SyncRecordIn(BaseModel):
    record_id: str = Field(pattern=r"^[0-9a-f]{64}$")
    updated_at: int
    deleted: bool = False
    nonce: str = Field(pattern=r"^[0-9a-f]{24}$")
    ciphertext_b64: str = Field(max_length=350_000)


class SyncPush(BaseModel):
    records: list[SyncRecordIn] = Field(max_length=200)
