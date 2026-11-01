"""Deployer spend ledgers: where the daily/monthly GPU+vendor spend totals live.

Why this exists: ordinary chat must work without PostgreSQL, but a
resettable in-memory counter must never be the SOLE protection on shared
money. So the ledger has three backends, resolved explicitly:

- ``postgres``: totals in the ``spend`` table (survives everything short
  of a DB loss). Used whenever DATABASE_URL is set.
- ``modal_dict``: totals in a Modal Dict (survives container restarts and
  redeploys without any database). Used when SPEND_BACKEND=modal_dict or
  when auto-resolution finds no DATABASE_URL but a configured dict name.
- ``memory``: process-local totals (reset on restart). Only ever used
  without a database AND without a dict name, and then ONLY behind much
  lower ephemeral ceilings (EPHEMERAL_DAY_USD / EPHEMERAL_MONTH_USD) plus
  honest ``budget_persistent: false`` health. This is the documented
  conservative alternative, not a silent downgrade.

Totals are estimates (read-modify-write, no cross-request locking — the
same as the historical Postgres version); the hard per-request caps
(max tokens, timeouts, per-device rate limits) hold regardless of backend.
"""
import time

DAY_CEILING_FALLBACK = 5.0
MONTH_CEILING_FALLBACK = 20.0


def utc_day() -> str:
    return time.strftime("%Y-%m-%d", time.gmtime())


def utc_month() -> str:
    return time.strftime("%Y-%m", time.gmtime())


class PostgresSpend:
    """Ledger over the ``spend`` table. Async (shares the app's async engine)."""

    persistent = True

    def __init__(self, engine):
        self.engine = engine

    async def add(self, usd: float) -> None:
        from sqlalchemy import insert, select, update

        from .db import spend as spend_table
        day = utc_day()
        async with self.engine.begin() as c:
            r = (await c.execute(select(spend_table.c.usd).where(spend_table.c.day == day))).scalar()
            if r is None:
                await c.execute(insert(spend_table).values(day=day, usd=usd))
            else:
                await c.execute(update(spend_table).where(spend_table.c.day == day).values(usd=float(r) + usd))

    async def spent_day(self) -> float:
        from sqlalchemy import select

        from .db import spend as spend_table
        async with self.engine.connect() as c:
            r = (await c.execute(select(spend_table.c.usd).where(spend_table.c.day == utc_day()))).scalar()
            return float(r or 0)

    async def spent_month(self) -> float:
        from sqlalchemy import select

        from .db import spend as spend_table
        prefix = utc_month()
        async with self.engine.connect() as c:
            rows = (await c.execute(select(spend_table.c.usd).where(spend_table.c.day.like(prefix + "%")))).scalars().all()
            return float(sum(rows or []))


class DictSpend:
    """Ledger over a Modal Dict (or a plain dict in tests).

    Keys hold running float totals per UTC day. Modal Dicts are touched
    ONLY through their async API (``get.aio``/``put.aio``) — blocking
    ``mapping[key]`` calls stall the event loop and Modal warns loudly
    about them. Plain dicts (no ``.aio``) use the sync path.
    """

    persistent = True

    def __init__(self, mapping):
        self.mapping = mapping

    async def _get(self, key: str) -> float:
        get = getattr(self.mapping, "get", None)
        if get is not None and hasattr(get, "aio"):
            v = await get.aio(key)  # Modal failures propagate loudly, as before
            try:
                return float(v)
            except (TypeError, ValueError):
                return 0.0
        try:
            return float(self.mapping[key])
        except (KeyError, ValueError, TypeError):
            return 0.0

    async def _put(self, key: str, value: float) -> None:
        put = getattr(self.mapping, "put", None)
        if put is not None and hasattr(put, "aio"):
            await put.aio(key, value)
        else:
            self.mapping[key] = value

    async def add(self, usd: float) -> None:
        day = utc_day()
        key = f"spend:day:{day}"
        await self._put(key, await self._get(key) + usd)

    async def spent_day(self) -> float:
        return await self._get(f"spend:day:{utc_day()}")

    async def spent_month(self) -> float:
        import asyncio
        import calendar

        now = time.gmtime()
        last = calendar.monthrange(now.tm_year, now.tm_mon)[1]
        vals = await asyncio.gather(*[self._get(f"spend:day:{now.tm_year:04d}-{now.tm_mon:02d}-{d:02d}")
                                      for d in range(1, last + 1)])
        return float(sum(vals))


class MemorySpend:
    """Process-local ledger. Ephemeral by construction: the Budget pairs it
    with the low ephemeral ceilings, and health reports budget_persistent."""

    persistent = False

    def __init__(self):
        self._totals: dict[str, float] = {}

    async def add(self, usd: float) -> None:
        day = utc_day()
        self._totals[day] = self._totals.get(day, 0.0) + usd

    async def spent_day(self) -> float:
        return self._totals.get(utc_day(), 0.0)

    async def spent_month(self) -> float:
        prefix = utc_month()
        return sum(v for k, v in self._totals.items() if k.startswith(prefix))


def resolve_backend_name(settings) -> str:
    """Pure resolution (sync, unit-tested): explicit setting wins, else
    postgres when a database is configured, else the Modal Dict when a dict
    name is configured, else ephemeral memory."""
    mode = (settings.spend_backend or "auto").strip().lower()
    if mode in ("postgres", "modal_dict", "memory"):
        return mode
    if (settings.database_url or "").strip():
        return "postgres"
    if (settings.spend_dict_name or "").strip():
        return "modal_dict"
    return "memory"


def effective_limits(settings, backend: str) -> tuple[float, float]:
    """(day_limit, month_limit) actually enforced. Memory mode clamps to the
    ephemeral ceilings no matter what the shared budgets say."""
    day, month = float(settings.daily_budget_usd), float(settings.monthly_budget_usd)
    if backend == "memory":
        day = min(day, float(settings.ephemeral_day_usd or DAY_CEILING_FALLBACK))
        month = min(month, float(settings.ephemeral_month_usd or MONTH_CEILING_FALLBACK))
    return day, month


def open_modal_dict(name: str):
    """Opens (creating if needed) a Modal Dict for spend totals. Import is
    lazy so unit tests and non-Modal hosts never need the modal package;
    inside a Modal container the ambient credentials cover same-workspace
    resources, so no token handling is needed here."""
    import modal

    return modal.Dict.from_name(name, create_if_missing=True)
