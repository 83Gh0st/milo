"""Per-provider data policy disclosure. Stdlib only.

Honesty rule (Phase 3A): every field is filled ONLY from the provider's
official terms, with the source URL and check date. This environment has no
network access, so every live provider below is `unknown` with the reason
recorded — the app requires an explicit trusted-adult acknowledgement for
anything `unknown` or `yes`, and the CLI prints the policy before saving.
A human with network access re-checks the terms and updates this table.
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
    "meta": DataPolicy("meta", "unknown", "unknown — terms not yet reviewed",
                       "https://developers.facebook.com/terms/ — NOT YET CHECKED", "unverified",
                       "No network in this environment (28 Oct 2026); re-check Meta's Model API data terms before release."),
    "openai": DataPolicy("openai", "unknown", "unknown — terms not yet reviewed",
                         "https://openai.com/policies/api-data-usage-policies — NOT YET CHECKED", "unverified",
                         "No network in this environment (28 Oct 2026); re-check OpenAI's API data-usage policy before release."),
    "anthropic": DataPolicy("anthropic", "unknown", "unknown — terms not yet reviewed",
                            "https://www.anthropic.com/legal/commercial-terms — NOT YET CHECKED", "unverified",
                            "No network in this environment (28 Oct 2026); re-check Anthropic's commercial terms before release."),
    "custom": DataPolicy("custom", "configurable", "depends on the endpoint you point Milo at; a model on your own machine keeps data local",
                         "", "unverified", "Self-hosted endpoints (Ollama, LM Studio, vLLM) never leave your network by construction."),
    "mock": DataPolicy("mock", "no", "nothing leaves the gateway", "", "2026-10-28", "Deterministic offline demo provider."),
}


def needs_ack(policy: DataPolicy) -> bool:
    return policy.trains_on_data in ("yes", "unknown")
