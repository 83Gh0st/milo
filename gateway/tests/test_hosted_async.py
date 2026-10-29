"""Async coverage for family credential isolation, route synthesis, tested
timestamps, and database-optional operation. Runs in CI (this sandbox
cannot create an event loop)."""
import httpx

from app.config import Settings
from app.providers.mock_adapter import MockAdapter
from app.providers.openai_compat import Creds
from app.sync import vault_ctx_for
from conftest import mk, token

BR = {"presentation": "playful", "text": "hello there", "activity": "chat"}
V = {"X-Vault-Id": "f" * 32, "X-Vault-Key": "e" * 64}


async def _family(app, c, headers):
    await c.post("/v1/sync/vault", headers=headers)
    await c.put("/v1/connections/openai", headers=headers,
                json={"api_key": "milo-family-key-12345678", "default_model": "gpt-x", "ack_data_policy": True})


async def test_family_turns_cannot_reach_deployer_creds(tmp_path):
    """A family route to a provider the family never configured must fail
    honestly — never silently spend the deployer's key. The injected
    fake-meta adapter records any credentials it receives."""
    app = mk(tmp_path)
    fake_meta = MockAdapter()
    app.state.adapters["meta"] = fake_meta
    app.state.deployer_creds["meta"] = Creds("https://vendor.example", "DEPLOYER-SPEND-ME")
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            vh = dict(h);
            vh.update(V)
            await _family(app, c, vh)
            await c.put("/v1/connections/routes", headers=vh,
                        json={"routes": {"brain": [{"provider": "meta", "model": "m"}]}})
            r = await c.post("/v1/brain/turn", json=BR, headers=vh)
            assert r.status_code == 200  # SSE envelope always 200; the error rides inside
            assert '"code": "unsupported_capability"' in r.text
            assert getattr(fake_meta, "last_api_key", None) is None  # deployer key never handed over


async def test_family_routes_synthesized_from_saved_keys(tmp_path):
    """Non-mock suites: keys saved but no routes saved still produce working
    turns from the family's own providers (no deployer fallback anywhere)."""
    app = mk(tmp_path)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            vh = dict(h);
            vh.update(V)
            await _family(app, c, vh)
            s = Settings(provider="meta")
            ctx = await vault_ctx_for(V["X-Vault-Id"], V["X-Vault-Key"], app.state.engine, s)
            assert ctx.routes["brain"][0].provider == "openai"  # synthesized from the saved key
            assert ctx.routes["brain"][0].model == "gpt-x"
            assert "meta" not in ctx.creds  # ...without touching deployer credentials
            s_mock = Settings(provider="mock")
            ctx_mock = await vault_ctx_for(V["X-Vault-Id"], V["X-Vault-Key"], app.state.engine, s_mock)
            assert ctx_mock.routes == {}  # mock suite keeps demo defaults


async def test_successful_probe_stamps_tested_at(tmp_path):
    """Tested timestamps round-trip through the vault so the app can show
    Tested <date> instead of treating a saved key as working."""
    from app import vaultstore
    app = mk(tmp_path)
    async with app.router.lifespan_context(app):
        eng = app.state.engine
        await vaultstore.save_caps(eng, "f" * 32, "openai",
                                   {"gpt-x": {"strategy": "json_schema", "ttfb_ms": 12, "checks": {"chat": "pass"},
                                              "tested_at": "2026-10-29T00:00:00Z"}})
        conns = await vaultstore.list_connections(eng, "f" * 32)
        assert conns[0]["caps"]["gpt-x"]["tested_at"] == "2026-10-29T00:00:00Z"


async def test_db_less_chat_with_honest_vault_outage(tmp_path):
    """Ordinary chat works without PostgreSQL; vault/sync answer 503 with a
    named code; health reports the degraded state (never healthy-zeros)."""
    app = mk(tmp_path, database_url="")
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 200
            assert (await c.post("/v1/plan", json={"goal": "brush teeth", "presentation": "playful"}, headers=h)).status_code == 200
            assert (await c.post("/v1/visual", json={"concept": "tree"}, headers=h)).status_code == 200
            vh = dict(h);
            vh.update(V)
            r = await c.get("/v1/connections", headers=vh)
            assert r.status_code == 503 and r.json()["error"] == "vault_unavailable"
            r = await c.post("/v1/sync/vault", headers=vh)
            assert r.status_code == 503 and r.json()["error"] == "vault_unavailable"
            health = (await c.get("/v1/health")).json()
            assert health["vault_available"] is False
            assert health["budget_persistent"] is False
            assert health["spend_backend"] == "memory"
            assert health["reasoning_provider"] == "mock"
