"""End-to-end encrypted sync. The server stores opaque ciphertext only: no plaintext, no keys, no table names.
Client derives (vault_id, auth_key, enc_key) from a high-entropy secret with Argon2id + HKDF (see docs/SYNC_DESIGN.md).

The same vault credentials authenticate family BYOK: a family stores its own
provider key (Fernet-sealed, hint only ever returned) and inference calls that
carry vault headers are billed to that key. This is NOT end-to-end encrypted:
the gateway must hold the key in clear to call the provider. It is encrypted
at rest and isolated per vault."""
import base64, hashlib, hmac, re, time
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import delete, func, insert, select, update
from sqlalchemy.exc import IntegrityError
from .db import sync_records, vault_keys, vaults
from .models import ProviderKeyReq, SyncPush
from .security import auth
from .vaultkeys import key_hint, open_vault_key, seal_vault_key

router = APIRouter(prefix="/v1/sync")
MAX_CT = 262_144


def _hdr(request: Request):
    vid, key = request.headers.get("x-vault-id", ""), request.headers.get("x-vault-key", "")
    if not re.fullmatch(r"[0-9a-f]{32}", vid) or not re.fullmatch(r"[0-9a-f]{64}", key):
        raise HTTPException(401, {"error": "bad_vault_credentials"})
    return vid, key


async def vault_auth(request: Request, dev: str = Depends(auth)) -> str:
    vid, key = _hdr(request)
    async with request.app.state.engine.connect() as c:
        row = (await c.execute(select(vaults.c.auth_hash).where(vaults.c.vault_id == vid))).first()
    if not row or not hmac.compare_digest(row[0], hashlib.sha256(key.encode()).hexdigest()):
        raise HTTPException(401, {"error": "bad_vault_credentials"})  # same answer for unknown vs wrong
    return vid


@router.post("/vault", status_code=201)
async def create_vault(request: Request, dev: str = Depends(auth)):
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
        await c.execute(delete(vault_keys).where(vault_keys.c.vault_id == vid))
        await c.execute(delete(vaults).where(vaults.c.vault_id == vid))


@router.post("/provider-key")
async def set_provider_key(body: ProviderKeyReq, request: Request, vid: str = Depends(vault_auth)):
    s = request.app.state.settings
    key = body.api_key.strip()
    if len(key) < 8:
        raise HTTPException(422, {"error": "key_too_short"})
    enc, hint, now = seal_vault_key(s.key_enc_secret, s.env, key), key_hint(key), int(time.time())
    async with request.app.state.engine.begin() as c:
        try:
            await c.execute(insert(vault_keys).values(vault_id=vid, provider=body.provider, key_enc=enc, key_hint=hint, created=now, updated_at=now))
        except IntegrityError:
            await c.execute(update(vault_keys).where(vault_keys.c.vault_id == vid).values(provider=body.provider, key_enc=enc, key_hint=hint, updated_at=now))
    return {"provider": body.provider, "hint": hint}  # the key itself is never returned


@router.get("/provider-key")
async def get_provider_key(request: Request, vid: str = Depends(vault_auth)):
    async with request.app.state.engine.connect() as c:
        row = (await c.execute(select(vault_keys.c.provider, vault_keys.c.key_hint, vault_keys.c.updated_at).where(vault_keys.c.vault_id == vid))).first()
    if not row:
        raise HTTPException(404, {"error": "no_key"})
    return {"provider": row[0], "hint": row[1], "updated_at": row[2]}


@router.delete("/provider-key", status_code=204)
async def delete_provider_key(request: Request, vid: str = Depends(vault_auth)):
    async with request.app.state.engine.begin() as c:
        await c.execute(delete(vault_keys).where(vault_keys.c.vault_id == vid))


async def vault_api_key_for(vid: str, key: str, engine, s) -> str:
    """Decrypts the family's provider key. 401 for bad vault credentials,
    409 when the vault holds no (readable) key. Never returns a fallback."""
    if not re.fullmatch(r"[0-9a-f]{32}", vid or "") or not re.fullmatch(r"[0-9a-f]{64}", key or ""):
        raise HTTPException(401, {"error": "bad_vault_credentials"})
    async with engine.connect() as c:
        row = (await c.execute(select(vaults.c.auth_hash).where(vaults.c.vault_id == vid))).first()
        if not row or not hmac.compare_digest(row[0], hashlib.sha256(key.encode()).hexdigest()):
            raise HTTPException(401, {"error": "bad_vault_credentials"})
        krow = (await c.execute(select(vault_keys.c.key_enc).where(vault_keys.c.vault_id == vid))).first()
    if not krow:
        raise HTTPException(409, {"error": "no_family_key"})
    try:
        return open_vault_key(s.key_enc_secret, s.env, krow[0])
    except ValueError:
        raise HTTPException(409, {"error": "family_key_unreadable"})  # KEK rotated or lost: the family re-enters the key


async def vault_api_key(request: Request) -> str | None:
    """Family BYOK key for this inference call, or None for the deployer key.

    Vault headers present but wrong -> 401. Vault valid but no family key
    stored -> 409. Neither case ever falls back to the deployer key silently.
    """
    vid, key = request.headers.get("x-vault-id", ""), request.headers.get("x-vault-key", "")
    if not vid and not key:
        return None
    return await vault_api_key_for(vid, key, request.app.state.engine, request.app.state.settings)
