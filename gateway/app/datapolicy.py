"""Per-provider data policy disclosure. Stdlib only.

Honesty rule (Phase 3A): every field is filled ONLY from the provider's
official terms, with the source URL and check date. Terms below were
verified from the vendors' own pages on 2026-10-29 (see source URLs); the
app requires an explicit trusted-adult acknowledgement for anything
`unknown` or `yes`, and the CLI prints the policy before saving.
Re-check the terms before every release — vendors change them.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class DataPolicy:
    provider: str
    trains_on_data: str  # yes | no | unknown | configurable
    retention: str
    source_url: str
    checked_on: str  # ISO date or "unverified"
    note: str = ""


POLICIES = {
    "meta": DataPolicy("meta", "unknown", "standard-model retention unverified",
                       "https://dev.meta.ai/docs (login required) — NOT YET CHECKED", "unverified",
                       "Endpoint confirmed live 2026-10-29 (OpenAI-compatible 401 shape); "
                       "-contributor model ids train on data (refused by the gateway); "
                       "standard-model retention still unverified, so acknowledgement is required."),
    "openai": DataPolicy("openai", "no",
                         "API data not used for training (since 2023-03-01, unless explicit opt-in); "
                         "abuse-monitoring logs (may include prompts/responses) kept up to 30 days by default; "
                         "zero-retention option exists for eligible customers",
                         "https://developers.openai.com/api/docs/guides/your-data", "2026-10-29",
                         "Verified from OpenAI's own API data-controls page."),
    "anthropic": DataPolicy("anthropic", "no",
                            "Commercial Terms forbid training on Customer Content; conversation content "
                            "not retained by default (Covered Models: 30 days); zero-retention and HIPAA options exist",
                            "https://www.anthropic.com/legal/commercial-terms + "
                            "https://platform.claude.com/docs/en/manage-claude/api-and-data-retention", "2026-10-29",
                            "Verified from Anthropic's commercial terms and API retention docs."),
    "modal": DataPolicy("modal", "unknown",
                        "Milo's Modal Shared Endpoint (Muse Spark Open) over TLS; prompts are not stored "
                        "by Milo. Whether Modal trains on or retains endpoint content is NOT YET CHECKED "
                        "in their terms — verify on modal.com before real users",
                        "https://modal.com/terms (NOT YET CHECKED)", "unverified",
                        "Milo-hosted model, billed to the deployer. Families cannot save a modal "
                        "connection, so this disclosure never gates anyone; it is honest by policy."),
    "custom": DataPolicy("custom", "configurable", "depends on the endpoint you point Milo at; a model on your own machine keeps data local",
                         "", "unverified", "Self-hosted endpoints (Ollama, LM Studio, vLLM) never leave your network by construction."),
    "mock": DataPolicy("mock", "no", "nothing leaves the gateway", "", "2026-10-28", "Deterministic offline demo provider."),
}


def needs_ack(policy: DataPolicy) -> bool:
    return policy.trains_on_data in ("yes", "unknown")
