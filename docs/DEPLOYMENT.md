# Deployment

## A. Production on one VPS (recommended)
Any 2 GB Linux VPS with Docker and a DNS name pointing at it.
```bash
git clone <your repo> milo && cd milo/deploy
cp ../gateway/.env.example .env
python3 -c "import secrets;print('JWT_SECRET='+secrets.token_urlsafe(48));print('POSTGRES_PASSWORD='+secrets.token_urlsafe(24))" >> .env
# edit .env: MODEL_API_KEY, API_DOMAIN=api.yourdomain.com, ENV=prod, PROVIDER=meta, DAILY_BUDGET_USD
docker compose up -d --build
curl https://api.yourdomain.com/healthz
```
Caddy obtains and renews the TLS certificate automatically and does not buffer streams. The gateway container is non-root with a read-only filesystem. `ENV=prod` makes the app **refuse to start** unless: `JWT_SECRET` is 32+ characters, a real `MODEL_API_KEY` is set, the database is PostgreSQL, and no `-contributor` model is configured. API docs are disabled in prod.

**Updates:** `git pull && docker compose up -d --build` (about 2 s of downtime; clients retry).
**Backups:** `docker compose exec db pg_dump -U milo milo | gzip > milo-$(date +%F).sql.gz` daily. The database holds no readable user content (only spend counters, cached pictures, and encrypted sync blobs), so backups are low-risk.
**Scaling:** one gateway process keeps the in-memory rate limiter exact and comfortably serves thousands of daily users because the model calls dominate. Before running more than one replica, move `RateLimiter` (`app/security.py`) to Redis and keep `Budget` as is (it is already in PostgreSQL).
**Monitoring:** logs are JSON lines on stdout with request id, latency, token counts and error class only. Never prompt or response text. Ship them to any log service and alert on `err` values, p95 `ms`, and `budget_exhausted`.

## B. Demo only: laptop + Cloudflare Tunnel (free)
```bash
cd gateway && uvicorn app.main:app_factory --factory --port 8000
cloudflared tunnel --url http://localhost:8000      # prints https://<random>.trycloudflare.com
flutter run --dart-define=API_BASE=https://<random>.trycloudflare.com
```
Keep this route ready on demo day; free hosts sleep and change terms.

## C. Other free hosts
Hugging Face Spaces (Docker, free CPU) or Oracle Cloud Always Free work with the same image: `docker build -f gateway/Dockerfile -t milo-gateway .` from the repo root. Use `DATABASE_URL=sqlite+aiosqlite:////data/milo.db` only for demos; production needs PostgreSQL.

## D. Releasing the app
* **Android:** `flutter build appbundle --release --dart-define=API_BASE=https://api.yourdomain.com --dart-define=HELPLINE=<verified>`; sign with your own upload key; Play Console -> Families policy declarations if you target children.
* **iOS:** `flutter build ipa --release --dart-define=...`; needs the Apple Developer programme; Kids Category rules apply if you market to children.
* **CI:** `.github/workflows/ci.yml` runs gateway tests, `flutter analyze`, `flutter test`, an Android release build, and an iOS no-codesign compile check on a macOS runner.
