from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", protected_namespaces=())
    env: str = "dev"                       # dev | prod
    provider: str = "meta"                 # meta | mock
    model_api_key: str = ""
    meta_base_url: str = "https://api.meta.ai/v1"
    meta_asr_url: str = "wss://api.meta.ai/v1/asr/realtime"
    spark_model: str = "muse-spark-1.3"
    voice_model: str = "muse-voice-transcribe-1.0"
    image_model: str = "muse-image-1.0"
    wonder_model: str = "muse-wonder-1.0"  # long-form only (stories/plan), explicit route; never default turns
    sam_model: str = "sam-3.1"  # entitlement-checked; app path gated on a keyed probe_sam.py run
    sam_verified: bool = False  # SAM_VERIFIED: true only after probe_sam.py passes with a real key (server secret)
    # --- competition demo access (hosted Meta credential, server-side only) ---
    demo_enabled: bool = True  # DEMO_ENABLED: admin switch for hosted/demo access; set false to disable hosted serving (BYOK unaffected)
    demo_requests_per_day: int = 300  # per installation (device hash), deployer/demo path only
    demo_image_per_day: int = 20  # per installation; image generation is the expensive capability
    demo_segment_per_day: int = 30  # per installation
    demo_voice_minutes_per_day: float = 30.0  # per installation, billed from streamed PCM bytes
    demo_max_concurrent: int = 4  # global in-flight demo requests (single-container pinning makes this exact)
    brain_mode: str = "json"               # json | lines
    jwt_secret: str = ""
    key_enc_secret: str = ""             # encrypts family BYOK keys at rest; required (>=32 chars) in prod
    token_ttl_s: int = 900
    database_url: str = "sqlite+aiosqlite:///./milo.db"
    rate_per_min: int = 30
    rate_per_day: int = 1500
    session_per_min_ip: int = 20
    daily_budget_usd: float = 20.0
    monthly_budget_usd: float = 100.0  # UTC-month cap on deployer-path vendor spend; family keys spend the family's quota, never this
    modal_models_url: str = ""       # Modal Shared Endpoint base, MUST end with /v1 (the adapter appends /chat/completions and /models)
    modal_models_key: str = ""       # proxy token (id.secret) for that endpoint (server-side only, never to the app)
    modal_model: str = ""            # Shared Endpoint model id per the Modal docs (meta-models/Muse-Spark-Open-816B-A42B); no default: a wrong id must fail loudly, never guess
    reasoning_provider: str = ""     # "" = follow PROVIDER suite; "modal" = hosted Muse Spark for text caps
    modal_fallback: bool = True      # text turns fall back to the suite entries when the hosted model errors pre-byte
    inference_timeout_s: float = 8   # deadline for hosted text inference (first byte + full stream); staging raises this, prod keeps 8
    spend_backend: str = "auto"      # auto | postgres | modal_dict | memory (see app/spend.py)
    spend_dict_name: str = ""        # Modal Dict for spend totals; empty disables the dict backend (see app/spend.py)
    ephemeral_day_usd: float = 5.0   # ceilings that ALWAYS bind the memory ledger (see app/spend.py)
    ephemeral_month_usd: float = 20.0
    price_in: float = 1.25                 # USD per 1M tokens (list prices, confirm on your dashboard)
    price_cached_in: float = 0.15
    price_out: float = 4.25
    price_image: float = 0.01
    price_segment: float = 0.01  # one SAM grounding call; Meta prices per 1k images - recheck on the dashboard
    price_voice_hour: float = 0.18
    max_body_bytes: int = 3_000_000
    max_image_bytes: int = 2_000_000
    sync_max_records: int = 20_000
    sync_max_bytes: int = 50_000_000
    attestation_mode: str = "off"          # off | enforce
    allow_lan_providers: bool = False    # dev only: permit http + LAN endpoints for local models (Ollama/LM Studio)
    speak_engine: str = "auto"           # auto | mock | piper | openai (auto: piper if installed, else mock in dev, else honest 503)
    speak_api_key: str = ""              # deployer TTS key (hosted engines); families use their own vault keys
    speak_model: str = "gpt-4o-mini-tts"  # UNVERIFIED default (no network 28 Oct 2026); first keyed run confirms
    piper_voice: str = ""                # path to a Piper .onnx voice model (local, no key)
    speak_price_per_1k: float = 0.0      # USD per 1k chars; 0 = unmetered until the human prices it from the terms

    @property
    def allowed_models(self) -> set[str]:
        return {self.spark_model, self.voice_model, self.image_model, self.wonder_model, self.sam_model}


def assert_model_allowed(s: Settings, model: str) -> None:
    """Children's data must never train a model: refuse '-contributor' variants and unknown IDs."""
    if model.endswith("-contributor") or model not in s.allowed_models:
        raise RuntimeError(f"model id not allowed: {model}")


def validate_runtime(s: Settings) -> None:
    import logging

    for m in s.allowed_models:
        assert_model_allowed(s, m)
        if not (m.startswith("muse-") or m.startswith("sam-")):
            raise RuntimeError(f"unexpected model id: {m}")
    if s.reasoning_provider == "modal" and s.modal_models_url.strip() and not s.modal_model.strip():
        raise RuntimeError("MODAL_MODEL must name the Shared Endpoint model (meta-models/Muse-Spark-Open-816B-A42B) when the modal path is enabled")
    if s.modal_model.strip().endswith("-contributor"):
        raise RuntimeError("MODAL_MODEL must be a non-contributor id")
    if bool(s.modal_models_url.strip()) != bool(s.modal_models_key.strip()):
        raise RuntimeError("MODAL_MODELS_URL and MODAL_MODELS_KEY must be set together or not at all")
    if s.reasoning_provider not in ("", "modal"):
        raise RuntimeError('REASONING_PROVIDER must be "" or "modal"')
    if s.reasoning_provider == "modal" and not s.modal_models_url.strip():
        raise RuntimeError('REASONING_PROVIDER=modal needs MODAL_MODELS_URL and MODAL_MODELS_KEY')
    if not 1 <= s.inference_timeout_s <= 120:
        raise RuntimeError("INFERENCE_TIMEOUT_S must be between 1 and 120 seconds")
    if s.spend_backend.strip().lower() not in ("auto", "postgres", "modal_dict", "memory"):
        raise RuntimeError("SPEND_BACKEND must be auto, postgres, modal_dict, or memory")
    if s.spend_backend.strip().lower() == "postgres" and not s.database_url.strip():
        raise RuntimeError("SPEND_BACKEND=postgres needs DATABASE_URL")
    if s.spend_backend.strip().lower() == "modal_dict" and not s.spend_dict_name.strip():
        raise RuntimeError("SPEND_BACKEND=modal_dict needs SPEND_DICT_NAME")
    if s.demo_requests_per_day < 1 or s.demo_image_per_day < 0 or s.demo_segment_per_day < 0 or s.demo_max_concurrent < 1:
        raise RuntimeError("demo limits must be positive (DEMO_REQUESTS_PER_DAY/DEMO_IMAGE_PER_DAY/DEMO_SEGMENT_PER_DAY/DEMO_MAX_CONCURRENT)")
    if s.brain_mode not in ("json", "lines"):
        raise RuntimeError("BRAIN_MODE must be json or lines")
    if s.provider not in ("meta", "mock"):
        raise RuntimeError("PROVIDER must be meta or mock")
    if s.env == "prod":
        if len(s.jwt_secret) < 32:
            raise RuntimeError("JWT_SECRET must be at least 32 characters in prod")
        if len(s.key_enc_secret) < 32:
            raise RuntimeError("KEY_ENC_SECRET must be at least 32 characters in prod (it encrypts family API keys)")
        if s.provider == "meta" and not s.model_api_key:
            raise RuntimeError("PROVIDER=meta needs MODEL_API_KEY")
        if not s.database_url.strip():
            logging.getLogger("milo").warning("prod without DATABASE_URL: chat runs, vault/sync/cache are honestly unavailable")
        if s.attestation_mode == "enforce":
            raise RuntimeError("ATTESTATION_MODE=enforce needs a Play Integrity / App Attest verifier wired in app/security.py")


@lru_cache
def get_settings() -> Settings:
    return Settings()
