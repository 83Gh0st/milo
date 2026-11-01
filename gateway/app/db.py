from sqlalchemy import BigInteger, Boolean, Column, Float, Index, LargeBinary, MetaData, String, Table
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
    """Daily + monthly deployer spend estimates in USD. Only deployer-path
    turns are metered here; family-keyed turns spend the family's quota.
    Totals live on a SpendLedger (postgres | Modal Dict | memory — see
    app/spend.py); the memory ledger is always clamped to the low
    ephemeral ceilings, and ``persistent`` reports which case this is."""
    def __init__(self, ledger, limit: float, monthly_limit: float = 100.0, backend: str = "postgres"):
        self.ledger, self.limit, self.monthly_limit = ledger, limit, monthly_limit
        self.backend = backend
        self.persistent = bool(getattr(ledger, "persistent", False))

    @classmethod
    def for_settings(cls, settings, engine: AsyncEngine | None) -> "Budget":
        from .spend import DictSpend, MemorySpend, PostgresSpend, effective_limits, open_modal_dict, resolve_backend_name
        backend = resolve_backend_name(settings)
        if backend == "postgres":
            ledger: object = PostgresSpend(engine)
        elif backend == "modal_dict":
            ledger = DictSpend(open_modal_dict(settings.spend_dict_name))
        else:
            ledger = MemorySpend()
        day, month = effective_limits(settings, backend)
        return cls(ledger, day, month, backend)

    async def spent(self) -> float:
        return await self.ledger.spent_day()

    async def ok(self) -> bool:
        return await self.spent() < self.limit

    async def spent_month(self) -> float:
        return await self.ledger.spent_month()

    async def month_ok(self) -> bool:
        return await self.spent_month() < self.monthly_limit

    async def add(self, usd: float) -> None:
        if usd <= 0:
            return
        await self.ledger.add(usd)
