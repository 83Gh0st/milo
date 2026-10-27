import json, logging, sys, time, uuid
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from .config import Settings, get_settings, validate_runtime
from .db import Budget, make_engine, md
from .security import RateLimiter


class JsonFormatter(logging.Formatter):
    KEYS = ("rid", "path", "status", "ms", "kind", "tok_in", "tok_cached", "tok_out", "err", "bytes", "dev")  # never prompt or response text

    def format(self, r):
        d = {"ts": round(r.created, 3), "lvl": r.levelname, "msg": r.getMessage()}
        d.update({k: getattr(r, k) for k in self.KEYS if hasattr(r, k)})
        return json.dumps(d)


def setup_logging():
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(JsonFormatter())
    lg = logging.getLogger("milo")
    lg.handlers, lg.level, lg.propagate = [h], logging.INFO, False


def create_app(settings: Settings | None = None, *, reasoning=None, image=None, voice=None) -> FastAPI:
    s = settings or get_settings()
    validate_runtime(s)
    setup_logging()

    @asynccontextmanager
    async def lifespan(app):
        eng = make_engine(s.database_url)
        async with eng.begin() as c:
            await c.run_sync(md.create_all)
        app.state.engine, app.state.budget = eng, Budget(eng, s.daily_budget_usd)
        yield
        await eng.dispose()

    prod = s.env == "prod"
    app = FastAPI(title="Milo Gateway", version="1.0.0", lifespan=lifespan, docs_url=None if prod else "/docs", redoc_url=None, openapi_url=None if prod else "/openapi.json")
    app.state.settings, app.state.limiter = s, RateLimiter(s.rate_per_min, s.rate_per_day)
    app.state.ip_limiter = RateLimiter(s.session_per_min_ip, 5000)
    if s.provider == "mock":
        from .providers.mock import MockImage, MockReasoning, MockVoice
        app.state.reasoning, app.state.image, app.state.voice = reasoning or MockReasoning(), image or MockImage(), voice or MockVoice()
    else:
        from .providers.meta import MetaImage, MetaReasoning, MetaVoice
        app.state.reasoning, app.state.image, app.state.voice = reasoning or MetaReasoning(s), image or MetaImage(s), voice or MetaVoice(s)

    @app.middleware("http")
    async def guard(request: Request, call_next):
        rid, t0 = uuid.uuid4().hex[:12], time.monotonic()
        if int(request.headers.get("content-length") or 0) > s.max_body_bytes:
            return JSONResponse({"error": "too_large"}, status_code=413)
        resp = await call_next(request)
        resp.headers["X-Request-Id"] = rid
        resp.headers["X-Content-Type-Options"] = "nosniff"
        logging.getLogger("milo").info("req", extra={"rid": rid, "path": request.url.path, "status": resp.status_code, "ms": int((time.monotonic() - t0) * 1000)})
        return resp

    @app.exception_handler(Exception)
    async def boom(request: Request, exc: Exception):
        logging.getLogger("milo").error("unhandled", extra={"err": type(exc).__name__})
        return JSONResponse({"error": "internal"}, status_code=500)

    from .routes import router
    from .sync import router as sync_router
    app.include_router(router)
    app.include_router(sync_router)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True}

    return app


def app_factory() -> FastAPI:  # uvicorn --factory app.main:app_factory
    return create_app()
