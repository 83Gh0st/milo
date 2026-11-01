from dataclasses import dataclass


@dataclass
class Usage:
    prompt: int = 0
    cached: int = 0
    completion: int = 0
    connect_ms: int = 0  # upstream connect+send+headers (0 when the adapter doesn't measure)
    ttft_ms: int = 0  # time to first content token (0 when unmeasured)


# Normalised provider error codes (Phase 3). Existing codes
# (provider_error, image_failed, family_key_rejected, ...) are kept: the
# Meta adapters' behaviour is unchanged; new adapters use these codes.
TIMEOUT = "timeout"
UNREACHABLE = "unreachable"
AUTH_FAILED = "auth_failed"
MODEL_NOT_FOUND = "model_not_found"
RATE_LIMITED = "rate_limited"
QUOTA = "quota"
CONTENT_FILTERED = "content_filtered"
UNSUPPORTED_CAPABILITY = "unsupported_capability"

# Errors that may fail over to the next route entry (router retries these,
# never auth failures or content filtering).
FAILOVER_CODES = frozenset({TIMEOUT, UNREACHABLE, RATE_LIMITED, QUOTA, "provider_error", "image_failed"})


class ProviderError(Exception):
    def __init__(self, code: str, status: int = 502):
        super().__init__(code)
        self.code, self.status = code, status


def raise_for_status(provider: str, status: int, body: str = "") -> None:
    """Maps an HTTP status from a provider API to a normalised ProviderError.
    Pure (no network); the body is only sniffed for known markers, never kept.
    """
    b = (body or "")[:300].lower()
    if status in (401, 403):
        raise ProviderError(AUTH_FAILED, 502)
    if status == 404:
        raise ProviderError(MODEL_NOT_FOUND, 502)
    if status == 429:
        raise ProviderError(QUOTA if "quota" in b or "billing" in b or "credit" in b else RATE_LIMITED, 503)
    if status == 422 and ("content" in b or "moderat" in b or "safety" in b or "filter" in b):
        raise ProviderError(CONTENT_FILTERED, 502)
    if 500 <= status <= 599:
        raise ProviderError("provider_error", 503)
    if 400 <= status <= 499:
        raise ProviderError("provider_error", 502)


def redact(text: str, secrets: list[str]) -> str:
    """Replaces every known secret in log-bound text with [redacted]. The
    logging paths call this before emitting anything a provider echoed."""
    out = text or ""
    for s in secrets:
        if s and len(s) >= 8 and s in out:
            out = out.replace(s, "[redacted]")
    return out
