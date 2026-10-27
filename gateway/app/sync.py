"""End-to-end encrypted sync. The server stores opaque ciphertext only: no plaintext, no keys, no table names.
Client derives (vault_id, auth_key, enc_key) from a high-entropy secret with Argon2id + HKDF (see docs/SYNC_DESIGN.md)."""
import base64, hashlib, hmac, re, time
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import delete, func, insert, select, update
from .db import sync_records, vaults
from .models import SyncPush
from .security import auth

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
        await c.execute(delete(vaults).where(vaults.c.vault_id == vid))
