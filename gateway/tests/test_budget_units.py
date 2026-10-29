import httpx
from conftest import mk, token

BR = {"presentation": "playful", "text": "hello there", "activity": "chat"}


async def test_monthly_guard_trips_while_daily_is_fine(tmp_path):
    app = mk(tmp_path, daily_budget_usd=1000.0, monthly_budget_usd=0.0001)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 200  # spends past the tiny monthly cap
            r = await c.post("/v1/brain/turn", json=BR, headers=h)
            assert r.status_code == 503 and r.json()["error"] == "budget_exhausted"


async def test_monthly_spend_counts_the_current_month(tmp_path):
    app = mk(tmp_path)
    async with app.router.lifespan_context(app):
        b = app.state.budget
        assert await b.spent_month() == 0
        assert await b.month_ok()
        await b.add(1.25)
        assert await b.spent_month() == 1.25
        assert await b.spent() == 1.25
        assert await b.month_ok()  # default limit 100
        b.monthly_limit = 1.0
        assert not await b.month_ok()


async def test_health_reports_both_budget_bits(tmp_path):
    app = mk(tmp_path, monthly_budget_usd=0.0001)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 200
            health = (await c.get("/v1/health")).json()
            assert health["budget_ok"] is True and health["budget_month_ok"] is False
