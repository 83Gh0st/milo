"""First-party Meta capability registry: one honest row per Meta model Milo
can use - endpoint, credentials, cost, and, crucially, integration status.

Status vocabulary (do not blur these):
  live:   exercised against a real endpoint and observed working.
  wired:  client + gateway code complete; awaiting a keyed live run.
  probe:  no app-path code; a runnable probe script validates the endpoint.
  manual: operator-run infrastructure (local server), connected generically.
  absent: evaluated and declined, or no supported endpoint exists.

Costs are public list prices at time of writing; confirm on the dashboard.
Docs: docs/MULTIMODAL.md. Probes: gateway/scripts/probe_*.py.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class MetaCapability:
    id: str
    models: tuple
    endpoint: str
    via: str            # modal-shared | meta-api | local | none
    credentials: str
    byok: bool
    request: str
    response: str
    cost: str
    latency: str
    offline: str
    retention: str
    status: str
    verified_live: bool
    notes: str = ""


META_CAPABILITIES = (
    MetaCapability(
        id="spark", models=("meta-models/Muse-Spark-Open-816B-A42B", "muse-spark-1.3"),
        endpoint="Modal Shared Endpoint (/v1, OpenAI-compatible) or https://api.meta.ai/v1",
        via="modal-shared", credentials="Modal proxy token (server secret) or Meta Model API key",
        byok=True, request="chat completions + image_url parts, json_schema, reasoning_effort",
        response="SSE token stream -> risk/body/say/ui/memory/ui_spec/done",
        cost="Modal inference; suite $1.25/M in, $0.15/M cached, $4.25/M out",
        latency="2-8 s hosted turns (20 s staging deadline)",
        offline="pocket brain (hand-written local flows)",
        retention="no training on API data; 30-day abuse logs; -contributor refused",
        status="live", verified_live=True,
        notes="Primary reasoning. Staging ladder green incl. ui_spec + ui_context."),
    MetaCapability(
        id="wonder", models=("muse-wonder-1.0",),
        endpoint="https://api.meta.ai/v1 (Model API, preview)",
        via="meta-api", credentials="Meta Model API key (deployer secret or BYOK vault)",
        byok=True, request="chat completions, 1M context, effort up to max",
        response="text (agentic: plans, tool calls, delegated steps)",
        cost="$4/M in, $20/M out (Wonder Full is subscription-only, no API)",
        latency="tens of seconds at high effort",
        offline="pocket brain; Wonder never on the critical path",
        retention="same Model API terms as Spark suite",
        status="wired", verified_live=False,
        notes="Routable for plan + story only: PUT /routes rejects it for every "
              "other capability, the AI Connections screen offers it on the Plans "
              "and Stories rows, and it is never a default. Needs a keyed run."),
    MetaCapability(
        id="image", models=("muse-image-1.0",),
        endpoint="https://api.meta.ai/v1 (Model API, conversational image calls)",
        via="meta-api", credentials="Meta Model API key (deployer secret or BYOK vault)",
        byok=True, request="screened prompt + fixed child-safe cartoon wrapper, tools off",
        response="PNG bytes + X-Milo-Image: ai-generated",
        cost="$0.01/image", latency="image turns budgeted 60 s",
        offline="honest 'needs internet + picture access' words; board unaffected",
        retention="bytes cached by content hash (no user link); client memory-only",
        status="wired", verified_live=False,
        notes="Tap-to-create only; disclosure + alt text mandatory. Needs keyed run."),
    MetaCapability(
        id="voice", models=("muse-voice-transcribe-1.0",),
        endpoint="wss://api.meta.ai/v1/asr/realtime (Model API)",
        via="meta-api", credentials="Meta Model API key (deployer secret or BYOK vault)",
        byok=True, request="16 kHz PCM frames + lang/keywords hints, zero-retention flag",
        response="partial + final transcripts, turn/end events",
        cost="$0.18/hr audio", latency="streaming partials, final on turn end",
        offline="typed input always available; TTS is platform-side",
        retention="zero-retention requested; transcripts are turns, not stored audio",
        status="wired", verified_live=False,
        notes="Push-to-talk only; keyword/contextual vocabulary via first-frame hints."),
    MetaCapability(
        id="sam", models=("sam-3.1",),
        endpoint="https://api.meta.ai/v1 (Model API Responses API, streamed)",
        via="meta-api", credentials="Meta Model API key",
        byok=True, request="image data URL or uploaded MP4 + one noun phrase",
        response="streamed segmentation grammar (parse ONLY with meta_sam_parser)",
        cost="per 1k images/frames (check dashboard)", latency="streamed; video is minutes-scale",
        offline="photo + Understand explanation (no boxes); boxes need the API",
        retention="media leaves the device per request; no Milo-side retention",
        status="wired", verified_live=False,
        notes="Boxes path wired in /v1/segment from Meta's cookbook wire format; "
              "verified_live flips when probe_sam.py passes with a real key. "
              "Video + masks deferred. Overlay renderer: SegmentOverlay."),
    MetaCapability(
        id="glimmer", models=("muse-glimmer:30b",),
        endpoint="operator Ollama/llama.cpp/LM Studio (OpenAI-compatible :11434/v1)",
        via="local", credentials="none (own hardware) or third-party key",
        byok=True, request="OpenAI-compatible chat (+vision encoder input)",
        response="text (+ tool calls for agentic use)",
        cost="hardware only: ~24 GB VRAM or equipped Mac", latency="local-first, no cloud hop",
        offline="fully offline once weights are local; NOT on phones (30B/20 GB)",
        retention="stays on your network by construction",
        status="manual", verified_live=False,
        notes="Connect as a Custom/local BYOK endpoint; eval judge already speaks to it "
              "(JUDGE_BASE_URL). Never presented as on-device intelligence."),
)


def get_capability(cap_id: str) -> MetaCapability:
    for c in META_CAPABILITIES:
        if c.id == cap_id:
            return c
    raise KeyError(f"unknown Meta capability: {cap_id}")


def live_capabilities() -> tuple:
    return tuple(c.id for c in META_CAPABILITIES if c.verified_live)
