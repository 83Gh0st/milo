"""Runs the REAL Meta adapters against a local fake of Meta's documented API (chat completions SSE, images, realtime ASR handshake)."""
import asyncio, base64, json, socket, threading, time
import httpx, pytest, uvicorn
from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import StreamingResponse
from starlette.testclient import TestClient
from conftest import events, mk
from app.providers.base import ProviderError
from app.providers.mock import PNG

seen: dict = {}
fake = FastAPI()
TURN = {"risk": "none", "emotion": {"name": "curious", "intensity": 0.7}, "gesture": "lean_in", "gaze": {"target": "person", "id": ""}, "say": ["Hello there."], "followup": "none"}


@fake.post("/v1/chat/completions")
async def chat(req: Request):
    seen["chat"], seen["auth"] = await req.json(), req.headers.get("authorization")
    async def gen():
        text = json.dumps(TURN)
        for i in range(0, len(text), 9):
            yield f"data: {json.dumps({'choices': [{'delta': {'content': text[i:i + 9]}}]})}\n\n"
        yield f"data: {json.dumps({'choices': [], 'usage': {'prompt_tokens': 1000, 'completion_tokens': 100, 'prompt_tokens_details': {'cached_tokens': 800}}})}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")


@fake.post("/v1/images/generations")
async def img(req: Request):
    seen["img"] = await req.json()
    return {"data": [{"b64_json": base64.b64encode(PNG).decode()}]}


@fake.get("/v1/models")
async def models():
    seen["models_auth"] = True
    ids = ("muse-spark-1.3", "muse-voice-transcribe-1.0", "muse-image-1.0", "muse-wonder-1.0", "sam-3.1")
    return {"object": "list", "data": [{"id": m, "created": 1, "object": "model", "owned_by": "meta"} for m in ids]}


@fake.websocket("/v1/asr/realtime")
async def asr(ws: WebSocket):
    await ws.accept()
    seen["asr"] = json.loads(await ws.receive_text())
    await ws.send_text(json.dumps({"sessionId": "s1"}))
    n = 0
    while True:
        m = await ws.receive()
        if m["type"] == "websocket.disconnect":
            return
        if m.get("bytes"):
            n += 1
            if n == 2:
                await ws.send_text(json.dumps({"type": "transcript", "transcript": "hel"}))
                await ws.send_text(json.dumps({"type": "speechComplete", "transcript": "Hello Milo.", "turnId": 1}))
        elif m.get("text") and "endStream" in m["text"]:
            seen["ended"] = True
            await ws.close()
            return


@pytest.fixture(scope="module")
def meta_server():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    srv = uvicorn.Server(uvicorn.Config(fake, host="127.0.0.1", port=port, log_level="error"))
    threading.Thread(target=srv.run, daemon=True).start()
    while not srv.started:
        time.sleep(0.05)
    yield port
    srv.should_exit = True


def meta_app(tmp_path, port):
    return mk(tmp_path, provider="meta", model_api_key="test-key", meta_base_url=f"http://127.0.0.1:{port}/v1", meta_asr_url=f"ws://127.0.0.1:{port}/v1/asr/realtime")


async def test_spark_and_image_requests(tmp_path, meta_server):
    app = meta_app(tmp_path, meta_server)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            t = (await c.post("/v1/session", json={"install_id": "m" * 20, "app_version": "1", "platform": "android"})).json()["token"]
            h = {"Authorization": f"Bearer {t}"}
            r = await c.post("/v1/brain/turn", json={"presentation": "friendly", "text": "hi"}, headers=h)
            ev = events(r.text)
            assert [e for e, _ in ev][:3] == ["risk", "body", "say"] and ev[-1][0] == "done"
            b = seen["chat"]
            assert b["model"] == "muse-spark-1.3" and b["stream"] is True and b["reasoning_effort"] == "low"
            assert b["response_format"]["type"] == "json_schema" and seen["auth"] == "Bearer test-key"
            assert b["messages"][0]["role"] == "system" and "Milo" in b["messages"][0]["content"]  # static, cacheable prefix first
            spent = await app.state.budget.spent()
            assert abs(spent - (200 * 1.25 + 800 * 0.15 + 100 * 4.25) / 1e6) < 1e-9  # cached tokens priced at the cached rate
            v = await c.post("/v1/visual", json={"concept": "whale"}, headers=h)
            assert v.content == PNG and seen["img"]["model"] == "muse-image-1.0"
            assert seen["img"]["tool_enablement"] == {"enable_image_search": False, "enable_web_search": False, "enable_shell": False}


def test_voice_uses_documented_handshake_with_zero_retention(tmp_path, meta_server):
    app = meta_app(tmp_path, meta_server)
    with TestClient(app) as tc:
        t = tc.post("/v1/session", json={"install_id": "w" * 20, "app_version": "1", "platform": "ios"}).json()["token"]
        with tc.websocket_connect("/v1/voice") as ws:
            ws.send_text(json.dumps({"token": t, "lang": "Malayalam"}))
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(b"\x00" * 960); ws.send_bytes(b"\x00" * 960)
            assert ws.receive_json() == {"type": "partial", "text": "hel"}
            assert ws.receive_json() == {"type": "final", "text": "Hello Milo."}
            ws.send_text('{"type":"end"}')
        hs = seen["asr"]
        assert hs["authorization"] == {"accessToken": "Bearer test-key"} and hs["audioEncoding"] == "PCM_24KHZ"
        assert hs["model"] == "muse-voice-transcribe-1.0" and hs["zdrOverride"] is True and hs["languageBias"] == ["Malayalam"]
        time.sleep(0.2)
        assert seen.get("ended")


async def test_meta_entitlements_and_wonder_routing(meta_server):
    from app.config import Settings
    from app.providers.meta_adapter import MetaAdapter
    from app.providers.openai_compat import Creds
    s = Settings(env="dev", provider="meta", jwt_secret="x" * 40, database_url="sqlite+aiosqlite:///:memory:",
                 model_api_key="test-key", meta_base_url=f"http://127.0.0.1:{meta_server}/v1",
                 meta_asr_url=f"ws://127.0.0.1:{meta_server}/v1/asr/realtime")
    a = MetaAdapter(s)
    fam = Creds(f"http://127.0.0.1:{meta_server}/v1", "family-key")
    p = await a.probe(fam, "muse-image-1.0")  # non-chat member: list check only, no generation spend
    assert p.ok and p.checks["image_entitled"] == "pass" and p.checks["sam_entitled"] == "pass"
    assert "chat" not in p.checks and seen.get("models_auth") is True
    q = await a.probe(fam)  # spark: live chat checks + all entitlements in one call
    assert q.ok and q.checks["chat"] == "pass" and q.checks["wonder_entitled"] == "pass"
    seen.pop("chat", None)
    async for _ in a.stream([{"role": "user", "content": "hi"}], creds=fam, model="muse-wonder-1.0", max_tokens=8):
        pass
    assert seen["chat"]["model"] == "muse-wonder-1.0"  # Wonder routes; never the default
    with pytest.raises(ProviderError) as e:
        async for _ in a.stream([{"role": "user", "content": "hi"}], model="gpt-4o"):
            pass
    assert e.value.code == "model_not_found"
