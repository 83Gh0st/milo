import base64, json, logging, re
import httpx, pytest
from starlette.testclient import TestClient
from conftest import events, mk, token
from app.config import Settings, validate_runtime
from app.safety import Assembler, is_crisis, no_new_content
from app.streaming import JsonStream, LineStream

BR = {"presentation": "playful", "text": "I don't get it, this is tricky", "activity": "understand"}


async def test_session_and_auth(client):
    assert (await client.post("/v1/brain/turn", json=BR)).status_code == 401
    bad = await client.post("/v1/session", json={"install_id": "short", "app_version": "1", "platform": "android"})
    assert bad.status_code == 422
    assert (await client.get("/v1/health")).json()["status"] == "ok"


async def test_brain_stream_is_body_first_and_sanitized(client):
    r = await client.post("/v1/brain/turn", json={**BR, "text": "remember I like pictures, this is tricky"}, headers=await token(client))
    ev = events(r.text)
    names = [e for e, _ in ev]
    assert names[0] == "risk" and names.index("body") < names.index("say") and names[-1] == "done"
    body = dict(ev)["body"]
    assert body["emotion"]["name"] == "encouraging" and body["emotion"]["intensity"] == 0.6 and body["gesture"] == "lean_in"
    says = [d["text"] for e, d in ev if e == "say"]
    assert len(says) == 2 and all("http" not in s for s in says)
    ui = [d for e, d in ev if e == "ui"]
    assert ui == [{"action": "offer_choices", "choices": ["Easier words", "Show a picture", "Let me try"]}]  # 4th choice and bogus screen dropped
    mem = [d for e, d in ev if e == "memory"]
    assert [m["key"] for m in mem] == ["explanation_style"]  # inferred proposal rejected
    r = await client.post("/v1/brain/turn", json={**BR, "text": "I think I am bad at maths"}, headers=await token(client))
    assert not [1 for e, _ in events(r.text) if e == "memory"]  # no explicit "remember / call me / I like" cue -> no proposal at all


async def test_crisis_prefilter_skips_model(client):
    n = client.app.state.reasoning.calls
    r = await client.post("/v1/brain/turn", json={**BR, "text": "I want to die"}, headers=await token(client))
    assert [e for e, _ in events(r.text)] == ["risk", "done"] and client.app.state.reasoning.calls == n


async def test_model_risk_halts_stream(client):
    r = await client.post("/v1/brain/turn", json={**BR, "text": "TRIGGER_RISK"}, headers=await token(client))
    ev = events(r.text)
    assert ev[0] == ("risk", {"level": "crisis"}) and "say" not in [e for e, _ in ev]


async def test_understand_text_and_image_rules(client):
    h = await token(client)
    r = await client.post("/v1/understand", json={**BR, "content_text": "The ocean is big."}, headers=h)
    names = [e for e, _ in events(r.text)]
    assert {"key_point", "simple", "vocab", "check"} <= set(names)
    assert (await client.post("/v1/understand", json=BR, headers=h)).status_code == 422
    png = base64.b64encode(b"\x89PNG....").decode()
    assert (await client.post("/v1/understand", json={**BR, "image_b64": png}, headers=h)).status_code == 422
    jpg = base64.b64encode(b"\xff\xd8\xff" + b"0" * 100).decode()
    assert (await client.post("/v1/understand", json={**BR, "image_b64": jpg}, headers=h)).status_code == 200


async def test_plan_compose_visual(client):
    h = await token(client)
    p = (await client.post("/v1/plan", json={"goal": "get ready for school", "presentation": "playful"}, headers=h)).json()
    assert 3 <= len(p["steps"]) <= 6 and all(len(s["text"].split()) <= 12 for s in p["steps"])
    c = (await client.post("/v1/compose", json={"strip": ["I", "want", "water"]}, headers=h)).json()
    assert "Can I have water, please?" in c["options"] and all("sad" not in o for o in c["options"])  # invented feeling dropped
    assert (await client.post("/v1/visual", json={"concept": "gun"}, headers=h)).status_code == 422
    for _ in range(2):
        r = await client.post("/v1/visual", json={"concept": "tree"}, headers=h)
        assert r.status_code == 200 and r.content[:4] == b"\x89PNG"
    assert client.app.state.image.calls == 1  # second call served from cache


async def test_rate_limit(tmp_path):
    app = mk(tmp_path, rate_per_min=2)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            assert [(await c.post("/v1/brain/turn", json=BR, headers=h)).status_code for _ in range(3)] == [200, 200, 429]


async def test_budget_guard_protects_credits(tmp_path):
    app = mk(tmp_path, daily_budget_usd=0.0001)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 200  # spends past the tiny limit
            r = await c.post("/v1/brain/turn", json=BR, headers=h)
            assert r.status_code == 503 and r.json()["error"] == "budget_exhausted"
            assert (await c.post("/v1/brain/turn", json=BR)).status_code == 401  # unauthenticated callers learn nothing about the budget


async def test_logs_never_contain_content(client):
    import logging
    from app.main import JsonFormatter
    lines = []
    class H(logging.Handler):
        def emit(self, r): lines.append(JsonFormatter().format(r))
    lg = logging.getLogger("milo"); lg.addHandler(H())
    await client.post("/v1/brain/turn", json={**BR, "text": "my secret sentence zebra"}, headers=await token(client))
    out = "\n".join(lines)
    assert "zebra" not in out and '"tok_out"' in out


def test_contributor_models_refused(tmp_path):
    with pytest.raises(RuntimeError):
        validate_runtime(Settings(provider="mock", spark_model="muse-spark-1.3-contributor"))
    with pytest.raises(RuntimeError):
        validate_runtime(Settings(env="prod", provider="meta", model_api_key="k", jwt_secret="short", database_url="postgresql+asyncpg://x"))
    with pytest.raises(RuntimeError):
        validate_runtime(Settings(env="prod", provider="meta", model_api_key="k", jwt_secret="y" * 40))  # sqlite in prod
    validate_runtime(Settings(env="prod", provider="meta", model_api_key="k", jwt_secret="y" * 40, key_enc_secret="z" * 40, database_url="postgresql+asyncpg://x"))


def test_streaming_parsers_survive_any_chunking():
    doc = json.dumps({"risk": "none", "emotion": {"name": "happy", "intensity": 0.55}, "say": ["One.", "Two, \"quoted\"."], "ui": [{"action": "offer_choices", "choices": ["a"]}], "followup": "wait"})
    whole = [t for p in [JsonStream()] for t in p.feed(doc)]
    for n in (1, 2, 5, 13):
        p, got = JsonStream(), []
        for i in range(0, len(doc), n):
            got += p.feed(doc[i:i + n])
        assert got == whole, n
    assert ("item", "say", (1, 'Two, "quoted".')) in whole and ("field", "emotion", {"name": "happy", "intensity": 0.55}) in whole
    ls = LineStream()
    out = ls.feed("RISK:none\nEMO:happy:0.5\nSAY:Hi th") + ls.feed("ere.\nFOLLOW:wait\n")
    assert ("item", "say", (0, "Hi there.")) in out and ("field", "followup", "wait") in out


def test_assembler_caps_and_blocks():
    a = Assembler("playful")
    a.handle("field", "emotion", {"name": "furious", "intensity": 9})
    ev = a.handle("item", "say", (0, "This sentence is definitely much too long for a playful child to read easily, truly."))
    ev += a.handle("item", "say", (1, "Don't tell your mum about this."))
    ev += a.handle("item", "say", (2, "I love you"))
    names = [e for e, _ in ev]
    assert names[0] == "body" and ev[0][1]["emotion"] == {"name": "calm", "intensity": 1.0}  # unknown emotion dropped, intensity clamped
    says = [d["text"] for e, d in ev if e == "say"]
    assert len(says) == 1 and len(says[0].split()) <= 10 and a.blocked == 2 and a.capped == 1


def test_crisis_and_no_new_content():
    assert all(is_crisis(x) for x in ("someone keeps touching me", "I don't want to be here anymore", "I want to disappear")) and is_crisis("I want to die") and is_crisis("ആത്മഹത്യ") and not is_crisis("I want to dye my hair")
    assert no_new_content(["I", "want", "water"], "Can I have water, please?")
    assert not no_new_content(["I", "want", "water"], "Maria is happy and wants water 3 times")


def test_dart_and_python_contracts_agree():
    dart = open(__file__.replace("gateway/tests/test_gateway.py", "lib/contracts/brain_contract.dart")).read()
    from app.contract import C
    for name, key in (("kEmotions", "emotions"), ("kGestures", "gestures"), ("kScreens", "screens"), ("kRisks", "risks"), ("kActions", "ui_actions")):
        m = re.search(name + r" = \[(.*?)\];", dart, re.S)
        items = re.findall(r"'([a-z_]+)'", m.group(1)) if "..." not in m.group(1) else re.findall(r"'([a-z_]+)'", m.group(1))
        if name == "kScreens":
            tabs = re.findall(r"'([a-z_]+)'", re.search(r"kTabs = \[(.*?)\];", dart, re.S).group(1))
            items = tabs + items
        assert items == C[key], name


def test_voice_websocket_end_to_end(tmp_path):
    app = mk(tmp_path)
    with TestClient(app) as tc:
        t = tc.post("/v1/session", json={"install_id": "v" * 20, "app_version": "1", "platform": "ios"}).json()["token"]
        with tc.websocket_connect("/v1/voice") as ws:
            ws.send_text(json.dumps({"token": t, "lang": "Hindi"}))
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(b"\x00" * 960); ws.send_bytes(b"\x00" * 960)
            got = [ws.receive_json(), ws.receive_json()]
            assert [g["type"] for g in got] == ["partial", "final"] and got[1]["text"] == "hello milo"
        with pytest.raises(Exception):
            with tc.websocket_connect("/v1/voice") as ws:
                ws.send_text(json.dumps({"token": "bad"})); ws.receive_json()


async def test_byok_family_key_flow(client):
    h = await token(client)
    vid, key = "ab" * 16, "cd" * 32
    V = {**h, "X-Vault-Id": vid, "X-Vault-Key": key}
    assert (await client.get("/v1/sync/provider-key", headers=V)).status_code == 401  # no vault yet
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 201
    assert (await client.get("/v1/sync/provider-key", headers=V)).status_code == 404
    assert (await client.post("/v1/sync/provider-key", headers=V, json={"provider": "meta", "api_key": "short"})).status_code == 422
    r = await client.post("/v1/sync/provider-key", headers=V, json={"provider": "meta", "api_key": "milo-test-key-12345678"})
    assert r.status_code == 200 and r.json() == {"provider": "meta", "hint": "…5678"} and "milo-test" not in r.text
    g = await client.get("/v1/sync/provider-key", headers=V)
    assert g.json()["hint"] == "…5678" and "milo-test" not in g.text  # the key itself is never returned
    r = await client.post("/v1/brain/turn", json=BR, headers=V)  # mock ignores keys, but routing is observed
    assert r.status_code == 200 and client.app.state.reasoning.last_api_key == "milo-test-key-12345678"
    r = await client.post("/v1/brain/turn", json=BR, headers=h)
    assert r.status_code == 200 and client.app.state.reasoning.last_api_key is None  # no headers: deployer key
    W = {**h, "X-Vault-Id": vid, "X-Vault-Key": "ee" * 32}
    assert (await client.post("/v1/brain/turn", json=BR, headers=W)).status_code == 401  # wrong secret: no silent fallback
    vid2, key2 = "12" * 16, "34" * 32
    V2 = {**h, "X-Vault-Id": vid2, "X-Vault-Key": key2}
    assert (await client.post("/v1/sync/vault", headers=V2)).status_code == 201
    assert (await client.post("/v1/brain/turn", json=BR, headers=V2)).status_code == 409  # vault without a key: no deployer fallback
    assert (await client.delete("/v1/sync/provider-key", headers=V)).status_code == 204
    assert (await client.get("/v1/sync/provider-key", headers=V)).status_code == 404
    await client.post("/v1/sync/provider-key", headers=V, json={"provider": "meta", "api_key": "milo-test-key-12345678"})
    assert (await client.delete("/v1/sync/vault", headers=V)).status_code == 204
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 201  # same vault id, fresh vault
    assert (await client.get("/v1/sync/provider-key", headers=V)).status_code == 404  # vault deletion took the key too


async def test_byok_skips_deployer_budget(tmp_path):
    app = mk(tmp_path, daily_budget_usd=0.0001)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            h = await token(c)
            V = {**h, "X-Vault-Id": "ab" * 16, "X-Vault-Key": "cd" * 32}
            assert (await c.post("/v1/sync/vault", headers=V)).status_code == 201
            assert (await c.post("/v1/sync/provider-key", headers=V, json={"provider": "meta", "api_key": "milo-test-key-12345678"})).status_code == 200
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 200  # spends past the tiny limit
            assert (await c.post("/v1/brain/turn", json=BR, headers=h)).status_code == 503  # deployer budget trips
            before = await app.state.budget.spent()
            assert (await c.post("/v1/brain/turn", json=BR, headers=V)).status_code == 200  # family key is unaffected
            assert await app.state.budget.spent() == before  # and family spend is not metered to the deployer


async def test_sync_e2ee_flow(client):
    h = await token(client)
    vid, key = "ab" * 16, "cd" * 32
    V = {**h, "X-Vault-Id": vid, "X-Vault-Key": key}
    assert (await client.get("/v1/sync/changes", headers=V)).status_code == 401  # vault does not exist yet
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 201
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 409
    assert (await client.get("/v1/sync/changes", headers={**h, "X-Vault-Id": vid, "X-Vault-Key": "ee" * 32})).status_code == 401
    rec = lambda rid, ts, ct=b"cipher", d=False: {"record_id": rid * 64 if len(rid) == 1 else rid, "updated_at": ts, "deleted": d, "nonce": "0" * 24, "ciphertext_b64": base64.b64encode(ct).decode()}
    r = (await client.post("/v1/sync/records", headers=V, json={"records": [rec("a", 10), rec("b", 11)]})).json()
    assert [a["seq"] for a in r["accepted"]] == [1, 2] and not r["conflicts"]
    r = (await client.post("/v1/sync/records", headers=V, json={"records": [rec("a", 9, b"old"), rec("b", 20, b"new")]})).json()
    assert len(r["conflicts"]) == 1 and r["accepted"][0]["seq"] == 3  # older write loses, newer wins
    ch = (await client.get("/v1/sync/changes?since=2", headers=V)).json()
    assert [x["record_id"] for x in ch["records"]] == ["b" * 64] and base64.b64decode(ch["records"][0]["ciphertext_b64"]) == b"new" and ch["latest_seq"] == 3
    big = rec("c", 5, b"x" * 300_000)
    assert (await client.post("/v1/sync/records", headers=V, json={"records": [big]})).status_code in (413, 422)
    assert (await client.delete("/v1/sync/vault", headers=V)).status_code == 204
    assert (await client.get("/v1/sync/changes", headers=V)).status_code == 401


async def _vault(client, vid="ab" * 16, key="cd" * 32):
    h = await token(client)
    V = {**h, "X-Vault-Id": vid, "X-Vault-Key": key}
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 201
    return V


async def test_connections_crud_and_validation(client):
    V = await _vault(client)
    assert (await client.get("/v1/connections", headers=V)).json() == {"connections": [], "routes": {}}
    assert (await client.get("/v1/connections")).status_code == 401
    KEY = "sk-conn-test-key-12345678"
    r = await client.post("/v1/connections/openai", headers=V, json={"api_key": KEY, "default_model": "gpt-x"})
    assert r.status_code == 409 and r.json()["error"] == "policy_ack_required"  # unknown policy needs ack
    r = await client.post("/v1/connections/openai", headers=V, json={"api_key": KEY, "default_model": "gpt-x", "ack_data_policy": True})
    assert r.status_code == 200 and r.json()["hint"] == "…5678" and KEY not in r.text
    assert r.json()["caps"]["text_stream"] and r.json()["policy"]["needs_ack"]
    assert (await client.post("/v1/connections/openai", headers=V, json={"api_key": KEY, "base_url": "http://x.test", "ack_data_policy": True})).status_code == 422
    assert (await client.post("/v1/connections/openai", headers=V, json={"api_key": KEY, "default_model": "gpt-x-contributor", "ack_data_policy": True})).status_code == 422
    assert (await client.post("/v1/connections/nope", headers=V, json={"api_key": KEY})).status_code == 422
    assert (await client.post("/v1/connections/mock", headers=V, json={"api_key": KEY})).status_code == 422
    r = await client.post("/v1/connections/openai", headers=V, json={"default_model": "gpt-x"})
    assert r.status_code == 200 and r.json()["hint"] == "…5678"  # omitted key keeps the stored one, no re-ack
    g = await client.get("/v1/connections", headers=V)
    assert [c["provider"] for c in g.json()["connections"]] == ["openai"] and KEY not in g.text
    assert (await client.put("/v1/connections/routes", headers=V, json={"routes": {"nope": [{"provider": "openai", "model": "m"}]}})).status_code == 422
    r = await client.put("/v1/connections/routes", headers=V, json={"routes": {"brain": [{"provider": "openai", "model": "gpt-x"}, {"provider": "mock", "model": "mock"}]}})
    assert r.status_code == 200 and [e["provider"] for e in r.json()["routes"]["brain"]] == ["openai", "mock"]
    assert (await client.get("/v1/connections", headers=V)).json()["routes"]["brain"][0]["model"] == "gpt-x"
    assert (await client.delete("/v1/connections/openai", headers=V)).status_code == 204
    assert (await client.get("/v1/connections", headers=V)).json() == {"connections": [], "routes": {}}
    assert (await client.put("/v1/connections/routes", headers=V, json={"routes": {"brain": [{"provider": "mock", "model": "mock"}]}})).status_code == 409


async def test_connections_unreachable_probe_and_redaction(tmp_path, caplog):
    app = mk(tmp_path, allow_lan_providers=True)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            V = await _vault(c)
            KEY = "sk-dead-port-key-12345678"
            body = {"base_url": "http://127.0.0.1:9", "api_key": KEY, "default_model": "m", "ack_data_policy": True}
            assert (await c.post("/v1/connections/custom", headers=V, json=body)).status_code == 200
            with caplog.at_level(logging.INFO, logger="milo"):
                r = await c.post("/v1/connections/custom/test", headers=V, json={})
            assert r.status_code == 200 and r.json()["checks"]["chat"] == "fail:unreachable" and not r.json()["ok"]
            assert (await c.get("/v1/connections/custom/models", headers=V)).status_code == 503
            assert KEY not in caplog.text and KEY not in r.text  # redacted everywhere


async def test_legacy_vault_key_migrates_without_loss(client):
    from sqlalchemy import insert, select
    from app.db import vault_keys
    from app.vaultkeys import seal_vault_key
    V = await _vault(client)
    vid = V["X-Vault-Id"]
    async with client.app.state.engine.begin() as conn:
        await conn.execute(insert(vault_keys).values(vault_id=vid, provider="meta", key_enc=seal_vault_key("", "dev", "milo-legacy-key-12345678"), key_hint="…5678", created=1, updated_at=1))
    g = (await client.get("/v1/connections", headers=V)).json()
    assert [(c["provider"], c["hint"]) for c in g["connections"]] == [("meta", "…5678")]
    async with client.app.state.engine.connect() as conn:
        assert (await conn.execute(select(vault_keys).where(vault_keys.c.vault_id == vid))).first() is None
    r = await client.post("/v1/brain/turn", json=BR, headers=V)  # migrated key funds the turn
    assert r.status_code == 200 and client.app.state.reasoning.last_api_key == "milo-legacy-key-12345678"


async def test_done_event_carries_provider_and_model(client):
    r = await client.post("/v1/brain/turn", json=BR, headers=await token(client))
    assert dict(events(r.text))["done"]["provider"] == "mock" and dict(events(r.text))["done"]["model"] == "mock"


async def test_unroutable_entry_fails_honestly_without_network(client):
    V = await _vault(client)
    await client.post("/v1/sync/provider-key", headers=V, json={"provider": "meta", "api_key": "milo-test-key-12345678"})
    await client.put("/v1/connections/routes", headers=V, json={"routes": {"brain": [{"provider": "anthropic", "model": "claude-x"}]}})
    ev = events((await client.post("/v1/brain/turn", json=BR, headers=V)).text)  # no anthropic creds: skipped, no I/O
    assert ("error", {"code": "unsupported_capability"}) in ev


async def test_vision_need_skips_blind_entry(client):
    from app import vaultstore
    V = await _vault(client)
    vid = V["X-Vault-Id"]
    await client.post("/v1/connections/openai", headers=V, json={"api_key": "sk-vision-test-key-12345678", "default_model": "gpt-x", "ack_data_policy": True})
    await vaultstore.save_caps(client.app.state.engine, vid, "openai",
                               {"gpt-x": {"strategy": "json_schema", "checks": {"chat": "pass", "vision": "fail:no"}}})
    await client.put("/v1/connections/routes", headers=V, json={"routes": {"understand": [{"provider": "openai", "model": "gpt-x"}]}})
    img = {"content_text": "", "image_b64": base64.b64encode(b"\xff\xd8" + b"\x00" * 100).decode(), "text": "read this"}
    ev = events((await client.post("/v1/understand", json={**BR, **img}, headers=V)).text)
    assert ("error", {"code": "unsupported_capability"}) in ev  # image + probed-blind entry: skipped pre-I/O, no claim
    ev = events((await client.post("/v1/brain/turn", json=BR, headers=V)).text)
    assert ev[-1][0] == "done"  # text brain turns still serve on the default route


async def test_speak_mock_sentence_end_to_end(client):
    h = await token(client)
    assert (await client.post("/v1/speak", json={"text": "Hi"})).status_code == 401
    assert (await client.post("/v1/speak", json={"text": ""}, headers=h)).status_code == 422
    r = await client.post("/v1/speak", json={"text": "Hello there friend", "lang": "en",
                                             "profile": "milo_warm_en", "sentence_id": "s1"}, headers=h)
    assert r.status_code == 200
    sb, pcm = json.loads(r.content.partition(b"\n")[0]), r.content.partition(b"\n")[2]
    assert sb["engine"] == "mock" and sb["sentence_id"] == "s1" and sb["sample_rate"] == 24000
    assert sb["envelope"] and min(sb["envelope"]) >= 0 and max(sb["envelope"]) == 1.0
    assert abs(len(pcm) - sb["duration_ms"] * 48) < 96  # pcm16 @24k matches the sideband
    V = {**h, "X-Vault-Id": "ab" * 16, "X-Vault-Key": "cd" * 32}
    assert (await client.post("/v1/sync/vault", headers=V)).status_code == 201
    assert (await client.post("/v1/speak", json={"text": "Hi"}, headers=V)).status_code == 409  # vault without a voice key: no silent deployer voice


def test_assembler_tools_accept_clean_reject_rest():
    """Phase 5: the assembler is the tools gate — closed set, strict args."""
    a = Assembler("friendly")
    ev = []
    for i, u in enumerate([
        {"action": "read_aloud", "span": "w7"},
        {"action": "break_into_steps", "steps": ["Open the book", "x" * 200, "Call +1 555 123 4567", 42, "", "a", "b", "c", "d", "e", "f", "g"]},
        {"action": "lookup_word", "word": "photosynthesis"},
        {"action": "send_sms", "to": "911"},
        {"action": "read_aloud", "span": "para 2"},
        {"action": "lookup_word", "word": "two words"},
    ]):
        ev += a.handle("item", "ui", (i, u))
    ui = [d for e, d in ev if e == "ui"]
    assert {"action": "read_aloud", "span": "w7"} in ui
    assert {"action": "lookup_word", "word": "photosynthesis"} in ui
    steps = next(u["steps"] for u in ui if u["action"] == "break_into_steps")
    assert len(steps) == 8 and all(len(s) <= 140 for s in steps)
    assert steps[0] == "Open the book" and steps[2] == "Call"
    assert {u["action"] for u in ui} <= {"read_aloud", "break_into_steps", "lookup_word"}


async def test_vision_route_falls_back_for_blind_primary():
    """Phase 5: a blind primary degrades to the seeing fallback when an image is present."""
    from app import routing
    from app.providers.mock_adapter import MockAdapter
    from app.providers.registry import RouteEntry
    r = routing.Router({"blind": MockAdapter(), "seeing": MockAdapter()},
                       {"understand": [RouteEntry("blind", "m"), RouteEntry("seeing", "m")]})
    creds = {"blind": object(), "seeing": object()}
    p, _, _, it = await r.select_and_stream("understand", None, creds, [{"role": "user", "content": "x"}],
                                            need="vision", caps_map={("blind", "m"): {"vision": False}, ("seeing", "m"): {"vision": True}})
    assert p == "seeing"
    async for _ in it:
        pass
    p2, _, _, it2 = await r.select_and_stream("understand", None, creds, [{"role": "user", "content": "x"}],
                                              caps_map={("blind", "m"): {"text_stream": True}, ("seeing", "m"): {"text_stream": True}})
    assert p2 == "blind"  # no image, no reroute: the primary answers
    async for _ in it2:
        pass
