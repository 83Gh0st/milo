import hashlib, json, os, pathlib, sys
import httpx, pytest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from app.config import Settings
from app.main import create_app


def mk(tmp_path, **kw):
    d = dict(env="dev", provider="mock", jwt_secret="x" * 40, database_url=f"sqlite+aiosqlite:///{tmp_path}/t.db", rate_per_min=1000)
    d.update(kw)
    return create_app(Settings(**d))


@pytest.fixture
async def client(tmp_path):
    app = mk(tmp_path)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
            c.app = app
            yield c


async def token(c, iid="a" * 20):
    r = await c.post("/v1/session", json={"install_id": iid, "app_version": "1.0.0", "platform": "android"})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["token"]}


def events(text):
    out = []
    for blk in text.strip().split("\n\n"):
        ev, data = blk.split("\n")
        out.append((ev[7:], json.loads(data[6:])))
    return out
