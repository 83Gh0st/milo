"""Milo provider CLI: connect a family's vault to AI providers the way you log
a coding agent into the terminal. Run inside the gateway container:

    docker compose exec gateway python -m app.cli connect openai

Vault credentials come from VAULT_ID / VAULT_KEY env (Windows cmd:
`set VAULT_ID=...`) or hidden interactive prompts — never from argv.
Provider keys likewise: --key-env / --key-stdin / hidden prompt, never argv.
Exit codes: 0 ok, 2 usage, 3 vault/auth error, 4 provider error.
"""
import argparse
import asyncio
import getpass
import hashlib
import os
import secrets
import sys
import time

EXIT_AUTH = 3
EXIT_PROVIDER = 4


def _table(rows):
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.ljust(w) for c, w in zip(r, widths)) for r in rows)


def _vault_creds(args):
    vid = os.environ.get("VAULT_ID", "") or getattr(args, "vault_id", "") or ""
    key = os.environ.get("VAULT_KEY", "") or ""
    if not vid:
        vid = input("vault id (32 hex): ").strip()
    if not key:
        key = getpass.getpass("vault key (hidden): ").strip()
    import re
    if not re.fullmatch(r"[0-9a-f]{32}", vid) or not re.fullmatch(r"[0-9a-f]{64}", key):
        print("bad vault credentials (want 32-hex id + 64-hex key)", file=sys.stderr)
        raise SystemExit(EXIT_AUTH)
    return vid, key


def _key_input(args):
    if getattr(args, "key_env", ""):
        key = os.environ.get(args.key_env, "").strip()
        if not key:
            print(f"env {args.key_env} is empty", file=sys.stderr)
            raise SystemExit(2)
        return key
    if getattr(args, "key_stdin", False):
        return sys.stdin.read().strip()
    return getpass.getpass("provider key (hidden, never stored on the phone): ").strip()


def _engine_and_settings():
    from .config import get_settings
    from .db import make_engine
    s = get_settings()
    url = os.environ.get("DATABASE_URL", s.database_url)
    return make_engine(url), s


def _check_provider(provider):
    from .providers.registry import adapter_ids
    if provider not in adapter_ids() or provider == "mock":
        print(f"unknown provider: {provider} (want meta|openai|anthropic|custom)", file=sys.stderr)
        raise SystemExit(2)


async def cmd_vault_new(args):
    from sqlalchemy import insert
    from .db import md, vaults
    engine, _ = _engine_and_settings()
    async with engine.begin() as c:
        await c.run_sync(md.create_all)
    vid, key = secrets.token_hex(16), secrets.token_hex(32)
    async with engine.begin() as c:
        await c.execute(insert(vaults).values(vault_id=vid, auth_hash=hashlib.sha256(key.encode()).hexdigest(),
                                               created=int(time.time()), last_seq=0, bytes_used=0))
    print("vault created. Save the key now — it is shown once and cannot be recovered:")
    print(f"  VAULT_ID={vid}\n  VAULT_KEY={key}")


async def cmd_connect(args):
    from . import vaultstore
    from .datapolicy import POLICIES, needs_ack
    from .egress import check_base_url
    from .providers.base import ProviderError
    from .providers.capabilities import DECLARED
    from .providers.openai_compat import Creds
    from .providers.registry import check_model, get_adapter_for
    from .vaultkeys import key_hint, seal_vault_key
    provider = args.provider
    _check_provider(provider)
    engine, s = _engine_and_settings()
    vid, vkey = _vault_creds(args)
    from .sync import vault_ctx_for
    try:
        await vault_ctx_for(vid, vkey, engine, s)
    except Exception:
        print("vault not found (run `vault-new` first, or use the app-enrolled vault)", file=sys.stderr)
        raise SystemExit(EXIT_AUTH)
    base = (args.base_url or "").strip()
    if provider == "meta":
        base = s.meta_base_url
    elif not base:
        from .connections import DEFAULT_BASE_URLS
        base = DEFAULT_BASE_URLS.get(provider, "")
    if provider == "custom" and not base:
        print("custom needs --base-url", file=sys.stderr)
        raise SystemExit(2)
    try:
        base = check_base_url(base, env=s.env, allow_lan=s.allow_lan_providers) if base else ""
    except ValueError as e:
        print(f"base url rejected: {e}", file=sys.stderr)
        raise SystemExit(2)
    key = "" if (provider == "custom" and args.no_key) else _key_input(args)
    if key and len(key) < 8:
        print("key too short", file=sys.stderr)
        raise SystemExit(2)
    policy = POLICIES.get(provider)
    if policy and needs_ack(policy) and not args.ack_policy:
        print(f"DATA POLICY ({provider}): trains_on_data={policy.trains_on_data}; retention: {policy.retention}")
        print(f"source: {policy.source_url} [{policy.checked_on}]\n{policy.note}")
        if input("type YES to acknowledge: ").strip() != "YES":
            print("aborted", file=sys.stderr)
            raise SystemExit(2)
    adapter = get_adapter_for(provider, s)
    creds = Creds(base_url=base, api_key=key)
    model = (args.model or "").strip()
    if not model:
        try:
            models = await adapter.discover_models(creds)
        except ProviderError as e:
            print(f"model discovery failed: {e.code}", file=sys.stderr)
            raise SystemExit(EXIT_PROVIDER)
        if models:
            print(_table([(" #", "model")] + [(str(i + 1), m) for i, m in enumerate(models[:30])]))
            pick = input(f"pick 1-{min(len(models), 30)} (or type a model id): ").strip()
            model = models[int(pick) - 1] if pick.isdigit() and 1 <= int(pick) <= min(len(models), 30) else pick
        else:
            model = input("model id: ").strip()
    try:
        check_model(provider, model)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        raise SystemExit(2)
    probe = None
    if not args.no_probe:
        print(f"probing {provider}/{model} ...")
        try:
            probe = await adapter.probe(creds, model)
        except ProviderError as e:
            print(f"probe failed: {e.code}", file=sys.stderr)
            raise SystemExit(EXIT_PROVIDER)
        rows = [("check", "result")] + [(k, v) for k, v in probe.checks.items()]
        print(_table(rows) + f"\nstrategy: {probe.strategy}  ttfb: {probe.ttfb_ms} ms")
        if not probe.ok:
            print("probe failed; not saving", file=sys.stderr)
            raise SystemExit(EXIT_PROVIDER)
    if not args.yes and input(f"save {provider}/{model} to this vault? [y/N] ").strip().lower() != "y":
        print("aborted", file=sys.stderr)
        raise SystemExit(2)
    caps = {"declared": DECLARED[provider].as_dict()}
    if probe:
        caps[model] = {"strategy": probe.strategy, "ttfb_ms": probe.ttfb_ms, "checks": probe.checks}
    await vaultstore.save_connection(engine, vid, provider, base, seal_vault_key(s.key_enc_secret, s.env, key) if key else "",
                                     key_hint(key) if key else "", model, caps)
    print(f"saved {provider}/{model} ({key_hint(key) if key else 'no key'})")


async def cmd_list(args):
    from . import vaultstore
    engine, _ = _engine_and_settings()
    vid, _ = _vault_creds(args)
    conns = await vaultstore.list_connections(engine, vid)
    routes = await vaultstore.get_routes(engine, vid)
    if not conns:
        print("(no connections — run `connect` first)")
    else:
        print(_table([("provider", "model", "hint", "base url")] +
                     [(c["provider"], c["default_model"] or "-", c["hint"] or "-", c["base_url"] or "-") for c in conns]))
    if routes:
        print("routes:")
        for cap, entries in routes.items():
            print(f"  {cap}: " + " → ".join(f"{e['provider']}/{e['model']}" for e in entries))


async def cmd_models(args):
    from .providers.base import ProviderError
    from .providers.openai_compat import Creds
    from .providers.registry import get_adapter_for
    from .vaultkeys import open_vault_key
    from . import vaultstore
    _check_provider(args.provider)
    engine, s = _engine_and_settings()
    vid, _ = _vault_creds(args)
    row = await vaultstore.get_connection_key(engine, vid, args.provider)
    if not row:
        print("no connection for that provider", file=sys.stderr)
        raise SystemExit(EXIT_PROVIDER)
    try:
        key = open_vault_key(s.key_enc_secret, s.env, row.key_enc) if row.key_enc else ""
    except ValueError:
        print("stored key no longer decrypts (re-connect)", file=sys.stderr)
        raise SystemExit(EXIT_AUTH)
    try:
        models = await get_adapter_for(args.provider, s).discover_models(Creds(base_url=row.base_url or "", api_key=key))
    except ProviderError as e:
        print(f"discovery failed: {e.code}", file=sys.stderr)
        raise SystemExit(EXIT_PROVIDER)
    print("\n".join(models) if models else "(this provider lists no models — type the id)")


async def cmd_test(args):
    from .providers.base import ProviderError
    from .providers.openai_compat import Creds
    from .providers.registry import get_adapter_for
    from .vaultkeys import open_vault_key
    from . import vaultstore
    engine, s = _engine_and_settings()
    vid, _ = _vault_creds(args)
    if args.target and "/" in args.target:
        provider, model = args.target.split("/", 1)
    else:
        provider, model = (args.target or ""), ""
    if not provider:
        conns = await vaultstore.list_connections(engine, vid)
        if not conns:
            print("(no connections — run `connect` first)", file=sys.stderr)
            raise SystemExit(EXIT_PROVIDER)
        provider, model = conns[0]["provider"], conns[0]["default_model"]
    _check_provider(provider)
    row = await vaultstore.get_connection_key(engine, vid, provider)
    if not row:
        print("no connection for that provider", file=sys.stderr)
        raise SystemExit(EXIT_PROVIDER)
    model = model or row.default_model or ""
    if not model:
        print("no model (pass provider/model or re-connect with --model)", file=sys.stderr)
        raise SystemExit(2)
    try:
        key = open_vault_key(s.key_enc_secret, s.env, row.key_enc) if row.key_enc else ""
    except ValueError:
        print("stored key no longer decrypts (re-connect)", file=sys.stderr)
        raise SystemExit(EXIT_AUTH)
    try:
        probe = await get_adapter_for(provider, s).probe(Creds(base_url=row.base_url or "", api_key=key), model)
    except ProviderError as e:
        print(f"probe failed: {e.code}", file=sys.stderr)
        raise SystemExit(EXIT_PROVIDER)
    print(_table([("check", "result")] + [(k, v) for k, v in probe.checks.items()]))
    print(f"strategy: {probe.strategy}  ttfb: {probe.ttfb_ms} ms  ok: {probe.ok}")
    if probe.ok:
        await vaultstore.save_caps(engine, vid, provider, {model: {"strategy": probe.strategy, "ttfb_ms": probe.ttfb_ms, "checks": probe.checks}})
    else:
        raise SystemExit(EXIT_PROVIDER)


async def cmd_use(args):
    from . import vaultstore
    from .providers.registry import CAPABILITIES_NEEDED, check_model
    engine, _ = _engine_and_settings()
    vid, _ = _vault_creds(args)
    if args.capability not in CAPABILITIES_NEEDED:
        print(f"unknown capability (want one of {sorted(CAPABILITIES_NEEDED)})", file=sys.stderr)
        raise SystemExit(2)
    entries = []
    for spec in [args.primary, *(args.fallback or [])]:
        if "/" not in spec:
            print(f"bad route {spec!r} (want provider/model)", file=sys.stderr)
            raise SystemExit(2)
        provider, model = spec.split("/", 1)
        _check_provider(provider)
        try:
            check_model(provider, model)
        except ValueError as e:
            print(str(e), file=sys.stderr)
            raise SystemExit(2)
        entries.append({"provider": provider, "model": model, "strategy": "auto"})
    routes = await vaultstore.get_routes(engine, vid)
    routes[args.capability] = entries
    if not await vaultstore.save_routes(engine, vid, routes):
        print("no connections yet — run `connect` first", file=sys.stderr)
        raise SystemExit(2)
    print(f"{args.capability}: " + " → ".join(f"{e['provider']}/{e['model']}" for e in entries))


async def cmd_status(args):
    engine, s = _engine_and_settings()
    print(f"provider: {s.provider}  brain_mode: {s.brain_mode}  env: {s.env}")
    await cmd_list(args)


async def cmd_disconnect(args):
    from . import vaultstore
    _check_provider(args.provider)
    engine, _ = _engine_and_settings()
    vid, _ = _vault_creds(args)
    if not args.yes and input(f"remove {args.provider} from this vault? [y/N] ").strip().lower() != "y":
        print("aborted", file=sys.stderr)
        raise SystemExit(2)
    await vaultstore.delete_connection(engine, vid, args.provider)
    print(f"removed {args.provider}")


def build_parser():
    p = argparse.ArgumentParser(prog="milo provider CLI", description="Connect a family vault to AI providers.")
    p.add_argument("--vault-id", default="", help="vault id (or VAULT_ID env, or prompt)")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("vault-new", help="create a vault for CLI use (prints id + key once)")
    c.set_defaults(fn=cmd_vault_new)
    c = sub.add_parser("connect", help="connect a provider (key via hidden prompt, --key-env or --key-stdin)")
    c.add_argument("provider", help="meta|openai|anthropic|custom")
    c.add_argument("--base-url", default="")
    c.add_argument("--model", default="")
    c.add_argument("--key-env", default="", help="read the key from this env var")
    c.add_argument("--key-stdin", action="store_true", help="read the key from stdin")
    c.add_argument("--no-key", action="store_true", help="custom local endpoints without auth")
    c.add_argument("--ack-policy", action="store_true", help="acknowledge the provider data policy")
    c.add_argument("--no-probe", action="store_true", help="save without probing (tests/local)")
    c.add_argument("--yes", action="store_true", help="skip the confirm prompt")
    c.set_defaults(fn=cmd_connect)
    c = sub.add_parser("list", help="show connections + routes")
    c.set_defaults(fn=cmd_list)
    c = sub.add_parser("models", help="list models from the provider")
    c.add_argument("provider")
    c.set_defaults(fn=cmd_models)
    c = sub.add_parser("test", help="probe a connection (default: first)")
    c.add_argument("target", nargs="?", default="", help="[provider/model]")
    c.set_defaults(fn=cmd_test)
    c = sub.add_parser("use", help="set routes for a capability")
    c.add_argument("capability", help="brain|understand|plan|compose|visual|stt|tts")
    c.add_argument("primary", help="provider/model")
    c.add_argument("--fallback", action="append", default=[], help="provider/model (repeatable)")
    c.set_defaults(fn=cmd_use)
    c = sub.add_parser("status", help="deployer status + connections")
    c.set_defaults(fn=cmd_status)
    c = sub.add_parser("disconnect", help="remove a provider connection")
    c.add_argument("provider")
    c.add_argument("--yes", action="store_true")
    c.set_defaults(fn=cmd_disconnect)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    asyncio.run(args.fn(args))


if __name__ == "__main__":
    main()
