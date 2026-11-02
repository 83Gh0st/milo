import json, logging, sys, time, uuid
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from .config import Settings, get_settings, validate_runtime
from .db import Budget, make_engine, md
from .security import RateLimiter


class JsonFormatter(logging.Formatter):
    KEYS = ("rid", "path", "status", "ms", "kind", "tok_in", "tok_cached", "tok_out", "err", "bytes", "dev", "prov", "pmodel")  # never prompt or response text

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
        # Database-optional: without DATABASE_URL the engine stays None and
        # the vault/sync/visual-cache endpoints answer honestly unavailable,
        # while chat, plans, auth, and rate limits work (spend ledger falls
        # back per SPEND_BACKEND, with ephemeral ceilings when in-memory).
        eng = make_engine(s.database_url) if (s.database_url or "").strip() else None
        if eng is not None:
            async with eng.begin() as c:
                await c.run_sync(md.create_all)
        app.state.engine, app.state.budget = eng, Budget.for_settings(s, eng)
        yield
        if eng is not None:
            await eng.dispose()

    prod = s.env == "prod"
    app = FastAPI(title="Milo Gateway", version="1.0.0", lifespan=lifespan, docs_url=None if prod else "/docs", redoc_url=None, openapi_url=None if prod else "/openapi.json")
    app.state.settings, app.state.limiter = s, RateLimiter(s.rate_per_min, s.rate_per_day)
    app.state.ip_limiter = RateLimiter(s.session_per_min_ip, 5000)
    if s.provider == "mock":
        from .providers.mock import MockImage, MockReasoning, MockVoice
        app.state.reasoning, app.state.image, app.state.voice = reasoning or MockReasoning(), image or MockImage(), voice or MockVoice()
    else:
        from .providers.meta import MetaGround, MetaImage, MetaReasoning, MetaVoice
        app.state.reasoning, app.state.image, app.state.voice = reasoning or MetaReasoning(s), image or MetaImage(s), voice or MetaVoice(s)
        app.state.ground = MetaGround(s)
    from .providers.meta_adapter import MetaAdapter
    from .providers.mock_adapter import MockAdapter
    from .providers.openai_compat import Creds
    from .providers.registry import RouteEntry, get_adapter
    from .routing import Router
    if hasattr(app.state.reasoning, "discover_models") and hasattr(app.state.reasoning, "probe"):
        home = app.state.reasoning  # tests may inject a full protocol adapter
    elif s.provider == "mock":
        home = MockAdapter(reasoning=app.state.reasoning, image=app.state.image, voice=app.state.voice)
    else:
        home = MetaAdapter(s, reasoning=app.state.reasoning, image=app.state.image, voice=app.state.voice, ground=app.state.ground)
    adapters = {s.provider: home}
    for pid in ("openai", "anthropic", "custom"):
        adapters[pid] = get_adapter(pid)
    if s.provider != "mock":
        adapters["mock"] = get_adapter("mock")
    modal_ready = bool(s.modal_models_url.strip() and s.modal_models_key.strip())
    if modal_ready:
        adapters["modal"] = get_adapter("modal")
    app.state.adapters = adapters
    if s.provider == "mock":
        one = [RouteEntry("mock", "mock")]
        app.state.default_routes = {c: list(one) for c in ("brain", "understand", "plan", "compose", "story", "visual", "segment", "stt", "tts")}
    else:
        app.state.default_routes = {"brain": [RouteEntry("meta", s.spark_model)], "understand": [RouteEntry("meta", s.spark_model)],
                                    "plan": [RouteEntry("meta", s.spark_model)], "compose": [RouteEntry("meta", s.spark_model)],
                                    "story": [RouteEntry("meta", s.spark_model)],
                                    "visual": [RouteEntry("meta", s.image_model)], "segment": [RouteEntry("meta", s.sam_model)],
                                    "stt": [RouteEntry("meta", s.voice_model)], "tts": []}
    if s.reasoning_provider == "modal" and modal_ready:
        # Hosted Muse Spark serves the text capabilities; image/voice stay on the
        # suite. Fallback to the suite entry is configurable: staging sets
        # MODAL_FALLBACK=false so hosted outages fail loudly instead of
        # silently testing the suite.
        first = [RouteEntry("modal", s.modal_model)]
        for cap in ("brain", "understand", "plan", "compose", "story"):
            suite = app.state.default_routes.get(cap) or []
            app.state.default_routes[cap] = first + (suite if s.modal_fallback else [])
    app.state.router = Router(adapters, app.state.default_routes)
    app.state.deployer_creds = {"meta": Creds(base_url=s.meta_base_url, api_key=s.model_api_key)} if s.provider == "meta" else {}
    if modal_ready:
        app.state.deployer_creds["modal"] = Creds(base_url=s.modal_models_url.rstrip("/"), api_key=s.modal_models_key)

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

    @app.exception_handler(HTTPException)
    async def http_err(request: Request, exc: HTTPException):
        # Every raise site passes {"error": ...} dicts and the phone reads
        # body["error"]; return the dict as the body instead of Starlette's
        # default {"detail": ...} envelope so clients see the documented shape.
        body = exc.detail if isinstance(exc.detail, dict) else {"error": "http_error"}
        return JSONResponse(body, status_code=exc.status_code, headers=exc.headers)

    @app.exception_handler(Exception)
    async def boom(request: Request, exc: Exception):
        logging.getLogger("milo").error("unhandled", extra={"err": type(exc).__name__})
        return JSONResponse({"error": "internal"}, status_code=500)

    from .connections import router as conn_router
    from .routes import router
    from .speak import router as speak_router
    from .sync import router as sync_router
    app.include_router(router)
    app.include_router(sync_router)
    app.include_router(conn_router)
    app.include_router(speak_router)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True}

    return app


def app_factory() -> FastAPI:  # uvicorn --factory app.main:app_factory
    return create_app()
