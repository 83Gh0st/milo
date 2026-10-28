"""Family AI connections store: one encrypted key per (vault, provider),
probed capabilities, and the vault's route table. Needs sqlalchemy (CI);
unit-testable logic lives in registry/routing/egress instead.
"""
import json
import time

from sqlalchemy import delete, insert, select, update
from sqlalchemy.exc import IntegrityError

from .db import vault_connections, vault_keys
from .vaultkeys import open_vault_key


async def migrate_legacy(engine, vid: str) -> bool:
    """Copies a pre-Phase-3 vault_keys row into vault_connections without
    data loss (same Fernet envelope, same key_enc_secret), then removes the
    original — all in one transaction. Returns True when it migrated."""
    async with engine.begin() as c:
        knew = (await c.execute(select(vault_connections.c.provider).where(vault_connections.c.vault_id == vid))).first()
        krow = (await c.execute(select(vault_keys).where(vault_keys.c.vault_id == vid))).first()
        if knew or not krow:
            return False
        await c.execute(insert(vault_connections).values(
            vault_id=vid, provider=krow.provider or "meta", base_url="", key_enc=krow.key_enc, key_hint=krow.key_hint,
            default_model="", caps_json="{}", routes_json="{}", updated_at=int(time.time())))
        await c.execute(delete(vault_keys).where(vault_keys.c.vault_id == vid))
        return True


def _row_to_conn(r) -> dict:
    return {"provider": r.provider, "base_url": r.base_url or "", "hint": r.key_hint,
            "default_model": r.default_model or "", "caps": json.loads(r.caps_json or "{}"),
            "updated_at": r.updated_at}


async def list_connections(engine, vid: str) -> list[dict]:
    await migrate_legacy(engine, vid)
    async with engine.connect() as c:
        rows = (await c.execute(select(vault_connections).where(vault_connections.c.vault_id == vid))).all()
    return [_row_to_conn(r) for r in rows]


async def get_connection_key(engine, vid: str, provider: str):
    """Internal: full row incl. key_enc for server-side use. Never returned."""
    await migrate_legacy(engine, vid)
    async with engine.connect() as c:
        return (await c.execute(select(vault_connections).where(
            vault_connections.c.vault_id == vid, vault_connections.c.provider == provider))).first()


async def save_connection(engine, vid: str, provider: str, base_url: str, key_enc: str, hint: str,
                          default_model: str, caps: dict) -> None:
    """Upserts a connection. Never touches routes_json (routes are saved
    separately and survive key rotation)."""
    await migrate_legacy(engine, vid)
    now = int(time.time())
    async with engine.begin() as c:
        try:
            await c.execute(insert(vault_connections).values(
                vault_id=vid, provider=provider, base_url=base_url, key_enc=key_enc, key_hint=hint,
                default_model=default_model, caps_json=json.dumps(caps), routes_json="{}", updated_at=now))
        except IntegrityError:
            await c.execute(update(vault_connections).where(
                vault_connections.c.vault_id == vid, vault_connections.c.provider == provider).values(
                base_url=base_url, key_enc=key_enc, key_hint=hint, default_model=default_model,
                caps_json=json.dumps(caps), updated_at=now))


async def save_caps(engine, vid: str, provider: str, caps: dict) -> None:
    async with engine.begin() as c:
        await c.execute(update(vault_connections).where(
            vault_connections.c.vault_id == vid, vault_connections.c.provider == provider).values(
            caps_json=json.dumps(caps), updated_at=int(time.time())))


async def delete_connection(engine, vid: str, provider: str) -> None:
    await migrate_legacy(engine, vid)
    async with engine.begin() as c:
        await c.execute(delete(vault_connections).where(
            vault_connections.c.vault_id == vid, vault_connections.c.provider == provider))


async def delete_vault_connections(engine, vid: str) -> None:
    async with engine.begin() as c:
        await c.execute(delete(vault_connections).where(vault_connections.c.vault_id == vid))


async def get_routes(engine, vid: str) -> dict:
    """The vault's route table ({capability: [{provider, model, strategy}]}),
    or {} when the vault never saved one."""
    await migrate_legacy(engine, vid)
    async with engine.connect() as c:
        rows = (await c.execute(select(vault_connections.c.routes_json).where(vault_connections.c.vault_id == vid))).all()
    for r in rows:
        try:
            if r[0]:
                return json.loads(r[0])
        except ValueError:
            continue
    return {}


async def save_routes(engine, vid: str, routes: dict) -> bool:
    """Writes the route table to every connection row. Returns False when the
    vault has no connections yet (connect first, then route)."""
    await migrate_legacy(engine, vid)
    blob = json.dumps(routes)
    async with engine.begin() as c:
        r = await c.execute(update(vault_connections).where(vault_connections.c.vault_id == vid).values(
            routes_json=blob, updated_at=int(time.time())))
        return r.rowcount > 0


async def vault_creds(engine, settings, vid: str) -> tuple[dict, list[str]]:
    """Decrypts every connection key: ({provider: Creds}, [unreadable...]).
    Unreadable keys are skipped (the family re-enters them); the caller logs
    the count, never the keys."""
    from .providers.openai_compat import Creds
    await migrate_legacy(engine, vid)
    async with engine.connect() as c:
        rows = (await c.execute(select(vault_connections).where(vault_connections.c.vault_id == vid))).all()
    creds, bad = {}, []
    for r in rows:
        try:
            key = open_vault_key(settings.key_enc_secret, settings.env, r.key_enc)
        except ValueError:
            bad.append(r.provider)
            continue
        creds[r.provider] = Creds(base_url=r.base_url or "", api_key=key, model=r.default_model or "")
    return creds, bad
