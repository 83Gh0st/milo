"""Family AI connections (Phase 3): one encrypted key per provider per vault,
model discovery, capability probing, and per-capability routing. All routes
are vault-authenticated like the sync endpoints. Keys are sealed with the
existing Fernet scheme, never returned, and redacted from logs.
"""
import json
import logging
import time

from fastapi import APIRouter, Depends, HTTPException, Request

from . import vaultstore
from .datapolicy import POLICIES, needs_ack
from .egress import check_base_url
from .models import ConnectionReq, ProbeReq, RoutesReq
from .providers.base import ProviderError, redact
from .providers.capabilities import DECLARED, DISPLAY_NAMES
from .providers.registry import CAPABILITIES_NEEDED, adapter_ids, check_model, get_adapter_for
from .sync import vault_auth
from .vaultkeys import key_hint, open_vault_key, seal_vault_key

router = APIRouter(prefix="/v1/connections")
log = logging.getLogger("milo")

# Default base URLs (UNVERIFIED-live 28 Oct 2026: no network to check vendor
# docs; isolated here so the first live `test` run confirms or corrects).
DEFAULT_BASE_URLS = {"openai": "https://api.openai.com/v1", "anthropic": "https://api.anthropic.com"}


def _check_provider(provider: str):
    # modal is deployer-only (hosted GPU spend is always the deployer's);
    # mock is not a real vendor. Neither accepts family connections.
    if provider not in adapter_ids() or provider in ("mock", "modal"):
        raise HTTPException(422, {"error": "unknown_provider"})


def _adapter(provider: str, s):
    _check_provider(provider)
    return get_adapter_for(provider, s)


@router.get("")
async def list_connections(request: Request, vid: str = Depends(vault_auth)):
    conns = await vaultstore.list_connections(request.app.state.engine, vid)
    routes = await vaultstore.get_routes(request.app.state.engine, vid)
    return {"connections": [{**c, "display_name": DISPLAY_NAMES.get(c["provider"], c["provider"]),
                             "policy": _policy(c["provider"])} for c in conns], "routes": routes}


def _policy(provider: str) -> dict:
    p = POLICIES.get(provider)
    if not p:
        return {}
    return {"trains_on_data": p.trains_on_data, "retention": p.retention, "source_url": p.source_url,
            "checked_on": p.checked_on, "note": p.note, "needs_ack": needs_ack(p)}


@router.post("/{provider}")
async def save_connection(provider: str, body: ConnectionReq, request: Request, vid: str = Depends(vault_auth)):
    s = request.app.state.settings
    _check_provider(provider)  # validate only: saving a key never instantiates an adapter
    base = (body.base_url or "").strip() or DEFAULT_BASE_URLS.get(provider) or ""
    if provider == "meta":
        base = s.meta_base_url
    if provider == "custom" and not base:
        raise HTTPException(422, {"error": "base_url_required"})
    try:
        base = check_base_url(base, env=s.env, allow_lan=s.allow_lan_providers) if base else ""
    except ValueError as e:
        raise HTTPException(422, {"error": "bad_base_url", "reason": str(e)})
    row = await vaultstore.get_connection_key(request.app.state.engine, vid, provider)
    if not body.api_key and provider != "custom" and not (row and row.key_enc):
        raise HTTPException(422, {"error": "key_required"})
    if body.api_key and len(body.api_key.strip()) < 8:
        raise HTTPException(422, {"error": "key_too_short"})
    if body.default_model:
        try:
            check_model(provider, body.default_model.strip())
        except ValueError as e:
            raise HTTPException(422, {"error": "model_not_allowed", "reason": str(e)})
    policy = POLICIES.get(provider)
    if policy and needs_ack(policy) and not body.ack_data_policy and not row:
        raise HTTPException(409, {"error": "policy_ack_required", "policy": _policy(provider)})
    key = (body.api_key or "").strip()
    model = (body.default_model or "").strip()
    if key:
        enc, hint = seal_vault_key(s.key_enc_secret, s.env, key), key_hint(key)
        caps = {"declared": DECLARED[provider].as_dict()}
    elif row and row.key_enc:
        enc, hint = row.key_enc, row.key_hint  # empty field keeps the stored key; re-probe only when the model changed
        caps = json.loads(row.caps_json or "{}") if (row.default_model or "") == model else {"declared": DECLARED[provider].as_dict()}
    else:
        enc, hint, caps = "", "", {"declared": DECLARED[provider].as_dict()}  # keyless custom/local endpoint
    await vaultstore.save_connection(request.app.state.engine, vid, provider, base, enc, hint, model, caps)
    log.info("connection saved", extra={"kind": "connections", "prov": provider})
    return {"provider": provider, "hint": hint, "model": model, "caps": DECLARED[provider].as_dict(), "policy": _policy(provider)}


@router.get("/{provider}/models")
async def list_models(provider: str, request: Request, vid: str = Depends(vault_auth)):
    from .providers.openai_compat import Creds
    s = request.app.state.settings
    adapter = _adapter(provider, s)
    row = await vaultstore.get_connection_key(request.app.state.engine, vid, provider)
    if not row:
        raise HTTPException(404, {"error": "no_connection"})
    try:
        key = open_vault_key(s.key_enc_secret, s.env, row.key_enc) if row.key_enc else ""
    except ValueError:
        raise HTTPException(409, {"error": "family_key_unreadable"})
    try:
        models = await adapter.discover_models(Creds(base_url=row.base_url or "", api_key=key))
    except ProviderError as e:
        log.info("discover failed", extra={"kind": "connections", "prov": provider, "err": e.code})
        raise HTTPException(e.status, {"error": e.code})
    return {"models": models}


@router.post("/{provider}/test")
async def test_connection(provider: str, body: ProbeReq, request: Request, vid: str = Depends(vault_auth)):
    from .providers.openai_compat import Creds
    s = request.app.state.settings
    adapter = _adapter(provider, s)
    row = await vaultstore.get_connection_key(request.app.state.engine, vid, provider)
    if not row:
        raise HTTPException(404, {"error": "no_connection"})
    model = (body.model or "").strip() or (row.default_model or "")
    if not model:
        raise HTTPException(422, {"error": "model_required"})
    try:
        key = open_vault_key(s.key_enc_secret, s.env, row.key_enc) if row.key_enc else ""
    except ValueError:
        raise HTTPException(409, {"error": "family_key_unreadable"})
    try:
        probe = await adapter.probe(Creds(base_url=row.base_url or "", api_key=key), model)
    except ProviderError as e:
        log.info("probe failed", extra={"kind": "connections", "prov": provider, "err": e.code})
        raise HTTPException(e.status, {"error": e.code})
    if probe.ok:
        caps = {model: {"strategy": probe.strategy, "ttfb_ms": probe.ttfb_ms, "checks": probe.checks,
                         "tested_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}}
        await vaultstore.save_caps(request.app.state.engine, vid, provider, caps)
    out = probe.as_dict()
    out["echo_safe"] = redact(str(out), [key] if key else []) == str(out)
    return out


@router.put("/routes")
async def put_routes(body: RoutesReq, request: Request, vid: str = Depends(vault_auth)):
    routes = {}
    for cap, entries in body.routes.items():
        if cap not in CAPABILITIES_NEEDED:
            raise HTTPException(422, {"error": "unknown_capability", "capability": cap})
        if not entries or len(entries) > 4:
            raise HTTPException(422, {"error": "bad_route_list", "capability": cap})
        routes[cap] = []
        for e in entries:
            try:
                check_model(e.provider, e.model.strip())
            except ValueError as ex:
                raise HTTPException(422, {"error": "model_not_allowed", "reason": str(ex)})
            routes[cap].append({"provider": e.provider, "model": e.model.strip(), "strategy": e.strategy})
    if not await vaultstore.save_routes(request.app.state.engine, vid, routes):
        raise HTTPException(409, {"error": "no_connections", "hint": "connect a provider first, then route"})
    return {"routes": routes}


@router.delete("/{provider}", status_code=204)
async def delete_connection(provider: str, request: Request, vid: str = Depends(vault_auth)):
    if provider not in adapter_ids():
        raise HTTPException(422, {"error": "unknown_provider"})
    await vaultstore.delete_connection(request.app.state.engine, vid, provider)
