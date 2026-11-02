"""End-to-end encrypted sync. The server stores opaque ciphertext only: no plaintext, no keys, no table names.
Client derives (vault_id, auth_key, enc_key) from a high-entropy secret with Argon2id + HKDF (see docs/SYNC_DESIGN.md).

The same vault credentials authenticate family BYOK: a family stores its own
provider key (Fernet-sealed, hint only ever returned) and inference calls that
carry vault headers are billed to that key. This is NOT end-to-end encrypted:
the gateway must hold the key in clear to call the provider. It is encrypted
at rest and isolated per vault."""
import base64, hashlib, hmac, re, time
from dataclasses import dataclass, field
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import delete, func, insert, select, update
from . import vaultstore
from .db import sync_records, vault_connections, vault_keys, vaults
from .models import ProviderKeyReq, SyncPush
from .security import auth
from .vaultkeys import key_hint, seal_vault_key

router = APIRouter(prefix="/v1/sync")
MAX_CT = 262_144


def _hdr(request: Request):
    vid, key = request.headers.get("x-vault-id", ""), request.headers.get("x-vault-key", "")
    if not re.fullmatch(r"[0-9a-f]{32}", vid) or not re.fullmatch(r"[0-9a-f]{64}", key):
        raise HTTPException(401, {"error": "bad_vault_credentials"})
    return vid, key


def need_vault_store(request: Request) -> None:
    """Database-optional chat means the vault (sync identity + sealed family
    keys) may not exist on this server. Every vault path answers 503
    vault_unavailable then - never a crash, never a silent bypass."""
    if request.app.state.engine is None:
        raise HTTPException(503, {"error": "vault_unavailable"})


async def vault_auth(request: Request, dev: str = Depends(auth)) -> str:
    need_vault_store(request)
    vid, key = _hdr(request)
    async with request.app.state.engine.connect() as c:
        row = (await c.execute(select(vaults.c.auth_hash).where(vaults.c.vault_id == vid))).first()
    if not row or not hmac.compare_digest(row[0], hashlib.sha256(key.encode()).hexdigest()):
        raise HTTPException(401, {"error": "bad_vault_credentials"})  # same answer for unknown vs wrong
    return vid


@router.post("/vault", status_code=201)
async def create_vault(request: Request, dev: str = Depends(auth)):
    need_vault_store(request)
    vid, key = _hdr(request)
    async with request.app.state.engine.begin() as c:
        if (await c.execute(select(vaults.c.vault_id).where(vaults.c.vault_id == vid))).first():
            raise HTTPException(409, {"error": "vault_exists"})
        await c.execute(insert(vaults).values(vault_id=vid, auth_hash=hashlib.sha256(key.encode()).hexdigest(), created=int(time.time()), last_seq=0, bytes_used=0))
    return {"vault_id": vid}


@router.get("/changes")
async def changes(request: Request, since: int = 0, limit: int = 500, vid: str = Depends(vault_auth)):
    limit = max(1, min(limit, 500))
    async with request.app.state.engine.connect() as c:
        rows = (await c.execute(select(sync_records).where(sync_records.c.vault_id == vid, sync_records.c.seq > since).order_by(sync_records.c.seq).limit(limit + 1))).all()
        latest = (await c.execute(select(vaults.c.last_seq).where(vaults.c.vault_id == vid))).scalar()
    more = len(rows) > limit
    return {"records": [{"record_id": r.record_id, "seq": r.seq, "updated_at": r.updated_at, "deleted": bool(r.deleted), "nonce": r.nonce,
                         "ciphertext_b64": base64.b64encode(r.ciphertext).decode()} for r in rows[:limit]], "latest_seq": latest, "more": more}


@router.post("/records")
async def push(body: SyncPush, request: Request, vid: str = Depends(vault_auth)):
    s = request.app.state.settings
    accepted, conflicts = [], []
    async with request.app.state.engine.begin() as c:
        v = (await c.execute(select(vaults.c.last_seq, vaults.c.bytes_used).where(vaults.c.vault_id == vid).with_for_update())).one()
        seq, used = v.last_seq, v.bytes_used
        count = (await c.execute(select(func.count()).select_from(sync_records).where(sync_records.c.vault_id == vid))).scalar()
        for r in body.records:
            try:
                ct = base64.b64decode(r.ciphertext_b64, validate=True)
            except Exception:
                raise HTTPException(422, {"error": "bad_ciphertext"})
            if len(ct) > MAX_CT:
                raise HTTPException(413, {"error": "record_too_large"})
            ex = (await c.execute(select(sync_records.c.updated_at, sync_records.c.seq, sync_records.c.ciphertext).where(sync_records.c.vault_id == vid, sync_records.c.record_id == r.record_id))).first()
            if ex and r.updated_at <= ex.updated_at:  # last-write-wins by the client's timestamp
                conflicts.append({"record_id": r.record_id, "seq": ex.seq, "updated_at": ex.updated_at})
                continue
            new_used = used + len(ct) - (len(ex.ciphertext) if ex else 0)
            if (not ex and count + 1 > s.sync_max_records) or new_used > s.sync_max_bytes:
                raise HTTPException(413, {"error": "vault_quota"})
            seq += 1
            vals = dict(seq=seq, updated_at=r.updated_at, deleted=r.deleted, nonce=r.nonce, ciphertext=ct)
            if ex:
                await c.execute(update(sync_records).where(sync_records.c.vault_id == vid, sync_records.c.record_id == r.record_id).values(**vals))
            else:
                await c.execute(insert(sync_records).values(vault_id=vid, record_id=r.record_id, **vals))
                count += 1
            used = new_used
            accepted.append({"record_id": r.record_id, "seq": seq})
        await c.execute(update(vaults).where(vaults.c.vault_id == vid).values(last_seq=seq, bytes_used=used))
    return {"accepted": accepted, "conflicts": conflicts, "latest_seq": seq}


@router.delete("/vault", status_code=204)
async def delete_vault(request: Request, vid: str = Depends(vault_auth)):
    async with request.app.state.engine.begin() as c:  # right to erasure: everything for this vault, immediately
        await c.execute(delete(sync_records).where(sync_records.c.vault_id == vid))
        await c.execute(delete(vault_connections).where(vault_connections.c.vault_id == vid))
        await c.execute(delete(vault_keys).where(vault_keys.c.vault_id == vid))
        await c.execute(delete(vaults).where(vaults.c.vault_id == vid))


@router.post("/provider-key")
async def set_provider_key(body: ProviderKeyReq, request: Request, vid: str = Depends(vault_auth)):
    """Legacy single-key endpoint (kept for the old app flow and tests).
    Now writes the connections store; same request/response behaviour."""
    from .providers.registry import adapter_ids
    s = request.app.state.settings
    if body.provider not in adapter_ids():
        raise HTTPException(422, {"error": "unknown_provider"})
    key = body.api_key.strip()
    if len(key) < 8:
        raise HTTPException(422, {"error": "key_too_short"})
    enc, hint = seal_vault_key(s.key_enc_secret, s.env, key), key_hint(key)
    await vaultstore.save_connection(request.app.state.engine, vid, body.provider, "", enc, hint, "", {})
    return {"provider": body.provider, "hint": hint}  # the key itself is never returned


@router.get("/provider-key")
async def get_provider_key(request: Request, vid: str = Depends(vault_auth)):
    conns = await vaultstore.list_connections(request.app.state.engine, vid)
    prefs = [c for c in conns if c["provider"] == "meta"] or conns
    if not prefs:
        raise HTTPException(404, {"error": "no_key"})
    return {"provider": prefs[0]["provider"], "hint": prefs[0]["hint"], "updated_at": prefs[0]["updated_at"]}


@router.delete("/provider-key", status_code=204)
async def delete_provider_key(request: Request, vid: str = Depends(vault_auth)):
    conns = await vaultstore.list_connections(request.app.state.engine, vid)
    for c in ([x for x in conns if x["provider"] == "meta"] or conns[:1]):
        await vaultstore.delete_connection(request.app.state.engine, vid, c["provider"])


@dataclass
class VaultCtx:
    """Everything inference needs from a family's vault: decrypted per-
    provider credentials, the saved route table, and probed capabilities."""
    vid: str
    creds: dict = field(default_factory=dict)  # provider -> Creds
    routes: dict = field(default_factory=dict)  # capability -> [RouteEntry]
    caps: dict = field(default_factory=dict)  # (provider, model) -> {need: bool, "strategy": str}
    unreadable: list = field(default_factory=list)  # providers whose key no longer decrypts


def _caps_for(conn: dict) -> dict:
    """Builds the (provider, model) caps entries from one connection row.
    A need is False only when a probe explicitly failed it; unprobed needs
    stay allowed (the provider's own error then surfaces honestly)."""
    out = {}
    for model, info in (conn.get("caps") or {}).items():
        if not isinstance(info, dict) or "checks" not in info:
            continue
        checks = info["checks"]
        entry = {"strategy": info.get("strategy", "lines")}
        for need, check in (("text_stream", "chat"), ("vision", "vision")):
            v = checks.get(check, "")
            entry[need] = not (isinstance(v, str) and v.startswith("fail"))
        out[model] = entry
    return out


async def vault_ctx_for(vid: str, key: str, engine, s) -> VaultCtx:
    """Validates vault headers (401), loads decrypted credentials, routes and
    probed caps (409 when the vault holds no usable key). Never falls back
    to the deployer key silently. 503 when this server has no vault store."""
    from .providers.registry import RouteEntry
    if engine is None:
        raise HTTPException(503, {"error": "vault_unavailable"})
    if not re.fullmatch(r"[0-9a-f]{32}", vid or "") or not re.fullmatch(r"[0-9a-f]{64}", key or ""):
        raise HTTPException(401, {"error": "bad_vault_credentials"})
    async with engine.connect() as c:
        row = (await c.execute(select(vaults.c.auth_hash).where(vaults.c.vault_id == vid))).first()
        if not row or not hmac.compare_digest(row[0], hashlib.sha256(key.encode()).hexdigest()):
            raise HTTPException(401, {"error": "bad_vault_credentials"})  # same answer for unknown vs wrong
    creds, bad = await vaultstore.vault_creds(engine, s, vid)
    if not creds:
        raise HTTPException(409, {"error": "no_family_key"})
    routes_raw = await vaultstore.get_routes(engine, vid)
    routes = {cap: [RouteEntry(e["provider"], e["model"], e.get("strategy", "auto")) for e in entries]
              for cap, entries in routes_raw.items()}
    conns = await vaultstore.list_connections(engine, vid)
    caps = {}
    for c in conns:
        for model, entry in _caps_for(c).items():
            caps[(c["provider"], model)] = entry
    if s.provider == "mock" and len(creds) == 1 and "mock" not in creds:
        # Offline-demo plumbing: the single family key funds mock turns too
        # (mock never sends it anywhere; tests observe last_api_key).
        creds["mock"] = next(iter(creds.values()))
    elif s.provider != "mock":
        # A family that saved keys but never saved per-capability routes
        # still gets working turns: each configured provider+model becomes
        # the default entry for every capability, and the router + probed
        # caps skip what a provider cannot serve (honest errors, never
        # deployer fallback - family requests only ever see family creds).
        own = [RouteEntry(c["provider"], c["default_model"], "auto")
               for c in conns if c.get("default_model") and c["provider"] in creds]
        if own:
            from .providers.registry import CAPABILITIES_NEEDED
            for cap in CAPABILITIES_NEEDED:
                routes.setdefault(cap, list(own))
    return VaultCtx(vid=vid, creds=creds, routes=routes, caps=caps, unreadable=bad)


async def vault_ctx(request: Request) -> VaultCtx | None:
    """Vault context for this inference call, or None for the deployer path.
    Vault headers present but wrong -> 401. Vault valid but no usable family
    key -> 409. Neither case ever falls back to the deployer key silently.
    """
    vid, key = request.headers.get("x-vault-id", ""), request.headers.get("x-vault-key", "")
    if not vid and not key:
        return None
    return await vault_ctx_for(vid, key, request.app.state.engine, request.app.state.settings)
