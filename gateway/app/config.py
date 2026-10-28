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
    brain_mode: str = "json"               # json | lines
    jwt_secret: str = ""
    key_enc_secret: str = ""             # encrypts family BYOK keys at rest; required (>=32 chars) in prod
    token_ttl_s: int = 900
    database_url: str = "sqlite+aiosqlite:///./milo.db"
    rate_per_min: int = 30
    rate_per_day: int = 1500
    session_per_min_ip: int = 20
    daily_budget_usd: float = 20.0
    price_in: float = 1.25                 # USD per 1M tokens (list prices, confirm on your dashboard)
    price_cached_in: float = 0.15
    price_out: float = 4.25
    price_image: float = 0.01
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
        return {self.spark_model, self.voice_model, self.image_model}


def assert_model_allowed(s: Settings, model: str) -> None:
    """Children's data must never train a model: refuse '-contributor' variants and unknown IDs."""
    if model.endswith("-contributor") or model not in s.allowed_models:
        raise RuntimeError(f"model id not allowed: {model}")


def validate_runtime(s: Settings) -> None:
    for m in s.allowed_models:
        assert_model_allowed(s, m)
        if not (m.startswith("muse-") or m.startswith("sam-")):
            raise RuntimeError(f"unexpected model id: {m}")
    if s.brain_mode not in ("json", "lines"):
        raise RuntimeError("BRAIN_MODE must be json or lines")
    if s.env == "prod":
        if len(s.jwt_secret) < 32:
            raise RuntimeError("JWT_SECRET must be at least 32 characters in prod")
        if len(s.key_enc_secret) < 32:
            raise RuntimeError("KEY_ENC_SECRET must be at least 32 characters in prod (it encrypts family API keys)")
        if s.provider != "meta" or not s.model_api_key:
            raise RuntimeError("prod requires PROVIDER=meta and MODEL_API_KEY")
        if s.database_url.startswith("sqlite"):
            raise RuntimeError("prod requires a PostgreSQL DATABASE_URL")
        if s.attestation_mode == "enforce":
            raise RuntimeError("ATTESTATION_MODE=enforce needs a Play Integrity / App Attest verifier wired in app/security.py")


@lru_cache
def get_settings() -> Settings:
    return Settings()
