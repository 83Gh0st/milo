import time
from sqlalchemy import BigInteger, Boolean, Column, Float, Index, LargeBinary, MetaData, String, Table, select, update, insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

md = MetaData()
spend = Table("spend", md, Column("day", String(10), primary_key=True), Column("usd", Float, nullable=False))
visual_cache = Table("visual_cache", md, Column("h", String(64), primary_key=True), Column("png", LargeBinary), Column("created", BigInteger))
vaults = Table("vaults", md, Column("vault_id", String(64), primary_key=True), Column("auth_hash", String(64)), Column("created", BigInteger),
               Column("last_seq", BigInteger, nullable=False), Column("bytes_used", BigInteger, nullable=False))
sync_records = Table("sync_records", md, Column("vault_id", String(64), primary_key=True), Column("record_id", String(64), primary_key=True),
                     Column("seq", BigInteger), Column("updated_at", BigInteger), Column("deleted", Boolean), Column("nonce", String(32)),
                     Column("ciphertext", LargeBinary), Index("ix_sync_seq", "vault_id", "seq"))
vault_keys = Table("vault_keys", md, Column("vault_id", String(64), primary_key=True), Column("provider", String(16)),
                   Column("key_enc", String(1024)), Column("key_hint", String(16)), Column("created", BigInteger), Column("updated_at", BigInteger))
# Phase 3: one row per (vault, provider). routes_json holds the vault's route
# table redundantly on every row (written together by save_routes); readers
# take the first non-empty value. Legacy vault_keys rows are lazily migrated
# here on first access (see vaultstore.migrate_legacy).
vault_connections = Table("vault_connections", md, Column("vault_id", String(64), primary_key=True), Column("provider", String(16), primary_key=True),
                          Column("base_url", String(500)), Column("key_enc", String(2048)), Column("key_hint", String(16)),
                          Column("default_model", String(128)), Column("caps_json", String(4000)), Column("routes_json", String(8000)),
                          Column("updated_at", BigInteger))


def make_engine(url: str) -> AsyncEngine:
    return create_async_engine(url, pool_pre_ping=True)


class Budget:
    """Daily spend estimate in USD, persisted so restarts do not reset the guard."""
    def __init__(self, engine: AsyncEngine, limit: float):
        self.engine, self.limit = engine, limit

    @staticmethod
    def _day() -> str:
        return time.strftime("%Y-%m-%d", time.gmtime())

    async def spent(self) -> float:
        async with self.engine.connect() as c:
            r = (await c.execute(select(spend.c.usd).where(spend.c.day == self._day()))).scalar()
            return float(r or 0)

    async def ok(self) -> bool:
        return await self.spent() < self.limit

    async def add(self, usd: float) -> None:
        if usd <= 0:
            return
        async with self.engine.begin() as c:
            r = await c.execute(update(spend).where(spend.c.day == self._day()).values(usd=spend.c.usd + usd))
            if r.rowcount == 0:
                try:
                    await c.execute(insert(spend).values(day=self._day(), usd=usd))
                except IntegrityError:
                    await c.execute(update(spend).where(spend.c.day == self._day()).values(usd=spend.c.usd + usd))
