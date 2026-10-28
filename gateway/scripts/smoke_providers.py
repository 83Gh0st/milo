"""Live provider smoke: probes each provider whose key is present in the
environment and prints a real capability table. No keys -> every provider
listed as skipped (exit 0). A configured provider that fails -> exit 1.

Env: MILO_SMOKE_META_KEY (+MILO_SMOKE_META_MODEL), MILO_SMOKE_OPENAI_KEY
(+_MODEL/_BASE), MILO_SMOKE_ANTHROPIC_KEY (+_MODEL), MILO_SMOKE_CUSTOM_BASE
(+_KEY/_MODEL). Runs against the real vendor APIs; needs network + keys.
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.providers.base import ProviderError
from app.providers.openai_compat import Creds
from app.providers.registry import get_adapter


async def one(provider, base, key, model):
    if not key and provider != "custom":
        return provider, model, "skipped", "no key in env", -1, "-"
    try:
        probe = await get_adapter(provider).probe(Creds(base_url=base, api_key=key), model)
    except ProviderError as e:
        return provider, model, "FAIL", e.code, -1, "-"
    status = "ok" if probe.ok else "FAIL"
    checks = ", ".join(f"{k}={v}" for k, v in probe.checks.items())
    return provider, model, status, checks, probe.ttfb_ms, probe.strategy


def targets():
    return [("meta", os.environ.get("MILO_SMOKE_META_BASE", "https://api.meta.ai/v1"),
             os.environ.get("MILO_SMOKE_META_KEY", ""), os.environ.get("MILO_SMOKE_META_MODEL", "muse-spark")),
            ("openai", os.environ.get("MILO_SMOKE_OPENAI_BASE", "https://api.openai.com/v1"),
             os.environ.get("MILO_SMOKE_OPENAI_KEY", ""), os.environ.get("MILO_SMOKE_OPENAI_MODEL", "gpt-4o-mini")),
            ("anthropic", "https://api.anthropic.com", os.environ.get("MILO_SMOKE_ANTHROPIC_KEY", ""),
             os.environ.get("MILO_SMOKE_ANTHROPIC_MODEL", "claude-3-5-haiku-latest")),
            ("custom", os.environ.get("MILO_SMOKE_CUSTOM_BASE", ""), os.environ.get("MILO_SMOKE_CUSTOM_KEY", ""),
             os.environ.get("MILO_SMOKE_CUSTOM_MODEL", ""))]


def configured(t):
    return bool(t[1] and (t[2] or t[0] == "custom") and t[3])


def show(rows):
    widths = [max(len(r[i]) for r in rows) for i in range(6)]
    print("\n".join("  ".join(c.ljust(w) for c, w in zip(r, widths)) for r in rows))


async def main(live):
    rows = [("provider", "model", "status", "checks", "ttfb_ms", "strategy")]
    failed = False
    for t in live:
        r = await one(*t)
        rows.append((r[0], r[1], r[2], r[3], str(r[4]), r[5]))
        failed = failed or r[2] == "FAIL"
    return rows, failed


if __name__ == "__main__":
    all_targets = targets()
    live = [t for t in all_targets if configured(t)]
    skipped = [(t[0], t[3] or "-", "skipped", "no key/model in env", "-", "-") for t in all_targets if not configured(t)]
    if not live:  # keyless path needs no event loop (verifiable anywhere)
        show([("provider", "model", "status", "checks", "ttfb_ms", "strategy")] + skipped)
        raise SystemExit(0)
    rows, failed = asyncio.run(main(live))
    show(rows + skipped)
    raise SystemExit(1 if failed else 0)
