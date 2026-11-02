# Milo gateway on Modal (serverless)

This deploys the **existing** FastAPI gateway (`gateway/app/`) to Modal, so
the phone app gets online mode without Docker or a PC running 24/7. Nothing
is reimplemented: `gateway/modal_app.py` imports `app.main:create_app` and
serves it through Modal's ASGI integration. All routes, contracts,
validation, provider adapters, safety policies, consent/ledger controls, and
auth are the same code the gateway tests exercise.

> Windows `cmd` throughout. No secrets are printed by any command below.
> Anything that needs your browser/account is marked **[YOU]**; the rest the
> agent already did or `cmd` can do unattended.

## 1. Pre-deploy security audit (28 Oct 2026, code inspection)

Every route was reviewed before exposing the gateway publicly. Result: **no
code changes were required** — the controls below already exist and are
covered by `gateway/tests/`. The table names the evidence.

| Route(s) | Auth | Abuse / size protection | Notes |
|---|---|---|---|
| `POST /v1/session` | none (issues the token) | per-IP rate limit (`session_per_min_ip`, `routes.py:43`); `install_id` pattern + length checked (`models.py`) | Returns a 15-min HS256 JWT; device is hashed, never stored raw |
| `GET /v1/health`, `GET /healthz` | none | no state, no secrets in the body (provider id + model ids + budget bit only, `routes.py:47-51`) | Liveness for Modal/phone checks |
| `POST /v1/brain/turn`, `/understand`, `/plan`, `/compose`, `/visual` | Bearer [REDACTED] (`security.auth`) + per-device rate limit + daily budget guard on the deployer path (`budget_guard`) | global 3 MB body cap middleware; 2 MB JPEG-only image cap; crisis text short-circuits locally, never sent to a model | SSE validator stays the only gate to the phone |
| `POST /v1/speak` | Bearer [REDACTED] + budget guard | sentence-sized input; engine resolved per vault routes | 503 `no_voice_engine` when nothing honest exists → app falls back to platform TTS |
| `WS /v1/voice` | token in first message (5 s timeout) + per-device rate limit + budget check | per-utterance and per-session byte caps; vault STT creds optional | closes 4401 on bad token |
| `/v1/sync/*` (vault, records, changes, delete) | Bearer [REDACTED] **and** vault HMAC (`sync.vault_auth`: unknown-vs-wrong return the same 401) | 256 KB/record, 20k records / 50 MB per vault quotas; last-write-wins conflicts | Server stores opaque ciphertext only; keys never leave the phone |
| `/v1/connections/*` (save/list/test/models/routes/delete) | Bearer [REDACTED] **and** vault HMAC, per-vault isolated | key length floor; model allow-list (`check_model`); data-policy ack gate (409 until acknowledged); SSRF egress guard on every custom base URL (`egress.check_base_url`, https-only in prod, no LAN/cloud-metadata targets) | Keys are Fernet-sealed at rest, hint-only in responses, redacted from logs (`redact`, log-capture tested) |

Decisions recorded (deliberate, not omissions):

- **No admin endpoints exist**, so there is nothing privileged to lock down
  beyond the table above. Provider keys are family-scoped; the deployer key
  lives only in the Modal Secret.
- **No CORS middleware, on purpose.** The only client is the Flutter app,
  which is not bound by browser same-origin policy. Browsers calling the API
  directly get no CORS headers (default deny). Do not add permissive CORS.
- **`/docs` and `/openapi.json` are disabled when `ENV=prod`** (`main.py:41`).
  Stage 1 (`ENV=dev`) exposes them; that stage is for your own smoke test,
  not for sharing the URL.
- **Single container is a correctness requirement** (`max_containers=1` in
  `modal_app.py`): the per-device rate limiter and the router's circuit
  breakers are in-process state (`security.py:23-24`).
- **TLS is terminated by Modal** (automatic `https://…modal.run` URL).
- **Logs** use the JSON formatter whose key allow-list excludes prompt and
  response text (`main.py:10-16`); `modal app logs` therefore stays safe to
  keep.

## 2. Persistence, keys, and restarts

| State | Where it lives on Modal | Restart behaviour |
|---|---|---|
| Sync blobs, vault rows, family connections, spend ledger, picture cache | Free-tier **PostgreSQL** via `DATABASE_URL` in the Modal Secret (Stage 2). Tables are created at startup (`main.py:31-38`); no migration step. | Survives restarts and redeploys. |
| Family BYOK keys | Same Postgres, Fernet-sealed with a KEK derived from `KEY_ENC_SECRET` (`vaultkeys.py`). | **Keep `KEY_ENC_SECRET` stable across redeploys.** Rotating it orphans stored keys (families re-enter them; the API answers `family_key_unreadable`, never garbage). Back the value up offline. |
| Device JWTs | Stateless HS256, verified against `JWT_SECRET`. | Rotating `JWT_SECRET` logs every device out once; the app re-sessions automatically on the next call. |
| Rate limits, circuit breakers, `Router.last_route` | In-process memory on the one container. | Reset on restart/redeploy — safe direction (limits restart full; breakers re-probe). |
| `CONTRACT_PATH` | Pinned to `/root/milo/contracts/brain_contract.json` in `modal_app.py`. | Image layout can never drift from the validator. |
| Piper voice files | Not shipped. `piper_voice` is empty on Modal, so `resolve_engine` skips Piper honestly. | Neural TTS comes from a vault/deployer OpenAI-compatible key; otherwise the app uses platform TTS. |

SQLite-on-a-Modal-Volume was considered and **rejected** for production:
Modal Volumes do not sync a DB+WAL pair atomically (preemption can corrupt
the file), and `validate_runtime` already refuses sqlite when `ENV=prod`.
Stage 1 below uses an **ephemeral** `/tmp` SQLite file for the mock smoke
test only — losing it costs nothing.

## 3. Honest-health note (requirement: gateway health ≠ provider health)

`/v1/health` reports the **gateway** (reachable, budget left). It does not
call the vendor, so the app must not present it as "AI works". Two things
enforce this:

1. The About → Connection row now reads *"Connected to Milo's server. AI
   providers are verified when Milo answers, or via AI connections → Test
   connection."* (`lib/net/api.dart:connectionWords`).
2. Provider health is proven only by a real probe: AI connections → **Test
   connection** (runs `adapter.probe`: a tiny streamed call, a JSON-schema
   conformance fixture, and a 1×1 vision call when applicable), or by an
   actual turn — a failed turn demotes the ladder to resting/offline
   (`LadderNotifier.failed`).

## 4. Deploy runbook (Windows `cmd`)

### 4.0 Install + authenticate — **[YOU]**, one time

```cmd
pip install modal
modal setup
```

`modal setup` prints a URL and waits: open it in your browser, sign in to
Modal (this links your workspace with the $100 grant), and press Enter back
in `cmd`. Verify with `modal secret list` (empty is fine).

### 4.1 Stage 1 — plumbing smoke test (no vendor key, ~5 min)

Make two secrets (run each line; the values print once — save them in a
password manager, never in a file):

```cmd
python -c "import secrets;print(secrets.token_urlsafe(48))"
python -c "import secrets;print(secrets.token_urlsafe(48))"
```

Create the Modal Secret (paste the two values; `cmd` quoting: no spaces
around `=`):

```cmd
modal secret create milo-gateway ENV=dev PROVIDER=mock JWT_SECRET=PASTE_FIRST_VALUE KEY_ENC_SECRET=PASTE_SECOND_VALUE DATABASE_URL=sqlite+aiosqlite:////tmp/milo-modal.db
```

Deploy from the **repo root**:

```cmd
cd C:\Users\Hydra\Downloads\milo_app_redesigned\milo
modal deploy gateway/modal_app.py
```

The output ends with a `https://…modal.run` URL — that is your `API_BASE`.
Save it; every later step calls it `API_BASE`.

Health checks (Windows ships `curl`):

```cmd
curl https://PASTE_API_BASE/healthz
curl https://PASTE_API_BASE/v1/health
```

Expect `{"ok":true}` and `{"status":"ok","provider":"mock",…}`. A real
authenticated turn (mock answers deterministically, costs nothing):

```cmd
curl -X POST https://PASTE_API_BASE/v1/session -H "Content-Type: application/json" -d "{\"install_id\":\"modal-smoke-test-0001\",\"app_version\":\"smoke\",\"platform\":\"android\"}"
```

Copy the `token` from the reply, then:

```cmd
curl -N -X POST https://PASTE_API_BASE/v1/brain/turn -H "Content-Type: application/json" -H "Authorization: Bearer PASTE_TOKEN" -d "{\"text\":\"hello\",\"activity\":\"chat\"}"
```

Expect a stream of `data: {…say…}` lines. If this works, the phone can work:
point the app at the URL (§6) and the About → Connection row must read
"Connected to Milo's server…".

### 4.2 Stage 2 — real online mode — **[YOU]** for the two signups

1. **Postgres (free):** create a free Neon project (neon.tech) or Supabase
   project, open the connection string (it looks like
   `postgresql://user:password@host/db?sslmode=require`), and convert it to
   SQLAlchemy async form by inserting `+asyncpg` after `postgresql`. Keep the
   `?sslmode=require` suffix.
2. **Meta key:** copy a Meta Model API key from dev.meta.ai (hackathon
   credits). Standard model IDs only — the gateway refuses to start with
   `-contributor` IDs (those train on your data).

Update the secret with the **same** `JWT_SECRET`/`KEY_ENC_SECRET` values
(rotating them logs devices out / orphans stored family keys):

```cmd
modal secret create milo-gateway ENV=prod PROVIDER=meta MODEL_API_KEY=PASTE_META_KEY JWT_SECRET=PASTE_SAME_FIRST_VALUE KEY_ENC_SECRET=PASTE_SAME_SECOND_VALUE DATABASE_URL=postgresql+asyncpg://PASTE_CONVERTED_STRING
```

(`modal secret create` with an existing name replaces it; confirm the
overwrite prompt.) Redeploy:

```cmd
modal deploy gateway/modal_app.py
```

Re-run the two health curls (`provider` must now read `meta`), then the
session + brain-turn curls: the turn's `say` text should be a genuine model
reply, not the mock's fixed lines. Verify the ledger rule in the app: every
cloud call appears under Memory → Ledger **before** its answer arrives.

Provider proof per family happens in the app: Trusted adult → AI
connections → save the family key → **Test connection** (green checklist =
actually probed). The deployer Meta key is proven by the curl turn above and
by `gateway/scripts/smoke_providers.py` with `MILO_SMOKE_META_KEY` set.

### 4.3 Logs, rollback, teardown, cost

**Cost estimate (live rates from modal.com/pricing, fetched 2026-10-29;
re-confirm before relying on it).** CPU $0.0000131/core/s (min 0.125
cores), memory $0.00000222/GiB/s: one minimum-size warm container
(`min_containers=1`, the shipped setting) is on the order of **$5 per
month** of Modal credit — the $100 grant covers many months of hosting.
Hosted model (§8): Muse Spark is a Modal-managed Shared Endpoint, billed
per token at the rate shown on its dashboard page — there are no GPU
servers, cold starts, or weight volumes to pay for on our side. The
other variable cost is vendor inference (suite/BYOK keys), bounded by
`DAILY_BUDGET_USD` (default 20) + `MONTHLY_BUDGET_USD` (default 100), and by
`max_containers=1` (the gateway can never scale out). This agent cannot see
your Modal balance: check it at modal.com → your workspace → Usage, and
confirm the live rates on modal.com/pricing. To stretch credit to the
maximum, set `min_containers=0` (cold starts on first use) and lower the two
budget envs in the `milo-gateway` secret.

```cmd
modal app logs milo-gateway              :: tail structured JSON logs (no prompt/response text by design)
modal app logs milo-gateway --help       :: time-range / follow options
modal app stop milo-gateway              :: stop serving (secret + data untouched; redeploy to resume)
modal secret list                        :: confirm the secret exists (values never shown)
```

- **Rollback:** redeploy from git: `git checkout <last-good-sha> --
  gateway/modal_app.py gateway/app` (or stash), then `modal deploy
  gateway/modal_app.py` again. Data lives in Postgres, so rollback never
  touches user data. To roll the *secret* back, re-run `modal secret create
  milo-gateway …` with the previous values.
- **Teardown (full):** `modal app stop milo-gateway`, then delete the
  `milo-gateway` secret in the Modal dashboard (Secrets page) and delete the
  Neon/Supabase project. Local cleanup: `rmdir /s .venv-test` (test venv).
- **Cost knobs:** `min_containers=1` in `modal_app.py` keeps one warm
  container (instant answers, spends credit 24/7); set it to `0` to pay only
  per request at the cost of cold starts. `DAILY_BUDGET_USD` (secret env,
  default 20) caps deployer-path vendor spend per UTC day and
  `MONTHLY_BUDGET_USD` (default 100) caps it per UTC month; both return
  `budget_exhausted` (the app rests honestly) when spent. Family keys spend
  the family's quota, never yours. Check current Modal CPU pricing on
  modal.com/pricing before leaving `min_containers=1` for weeks, and watch
  spend at modal.com → your workspace → Usage (the $100 grant balance shows
  there; this agent cannot see your account).

## 5. Flutter wiring (no code change, no hardcoded URL)

`lib/config.dart` already takes `API_BASE` from `--dart-define` (default
stays `http://10.0.2.2:8000` for the emulator). Build the phone APK against
the deployed URL from §4.1/§4.2:

```cmd
flutter build apk --release --dart-define=API_BASE=https://PASTE_API_BASE
```

Install `build\app\outputs\flutter-apk\app-release.apk` on the phone (§6 in
`SETUP.md` still covers install + permissions). Local development is
unchanged: omit the flag for the emulator default, or pass your LAN/tunnel
URL. Never put a key in `--dart-define` — provider keys travel only through
the PIN-gated AI-connections flow (sent once over TLS, sealed server-side).

## 6. What the agent verified vs what needs you

Verified here (see §7 for commands): gateway test suite green, Modal spec
imports cleanly, endpoint audit against the code above, Flutter wording
change (CI runs `flutter analyze`/`flutter test` — no Flutter SDK on this
machine, so those two are **UNVERIFIED** until CI runs).

29 Oct round (hosted model + providers + DB-optional): vendor endpoint
shapes probed live (OpenAI/Anthropic/Meta 401 envelopes match the
adapters); OpenAI/Anthropic data terms verified from official pages;
all three Modal specs import cleanly; gateway sync gate green (56
passed); family-creds isolation, route synthesis, tested_at, and
database-optional paths covered by new tests (async ones run in CI —
this sandbox cannot create an event loop). Nothing was deployed from
here: the Modal CLI needs asyncio, which this sandbox blocks, so every
`modal` command below is **[YOU]** (or the `modal-deploy` workflow).

**[YOU]**: `modal setup` (browser sign-in), Neon/Supabase signup + connection
string, Meta key, the two `modal deploy` runs, the curl checks, and the APK
install — plus §8 (hosted model secrets + staging ladder) for real online
AI. Nothing is deployed until you run those commands.

## 7. Verification appendix (agent-run, 28 Oct 2026)

```cmd
cd gateway
..\.venv-test\Scripts\python -m pytest -q -m "not asyncio" --ignore=tests/test_meta_adapter.py --deselect tests/test_gateway.py::test_voice_websocket_end_to_end -p no:cacheprovider
cd ..
.\.venv-test\Scripts\python -W ignore -c "import sys; sys.path.insert(0, 'gateway'); import modal_app; print(modal_app.app.name, modal_app.SECRET_NAME)"
.\.venv-test\Scripts\modal secret create --help
```

Results (measured, not claimed):

- **50 passed** in 11.6 s: every test this sandbox can execute (routing,
  contract parity incl. the fixed `test_dart_and_python_contracts_agree`,
  egress/SSRF, vaultkeys, voicecore, adapter conformance units, safety).
  Deps were installed with `uv` (system `pip` spins CPU-bound on this
  machine); `cryptography`/`pydantic`/`websockets`/`SQLAlchemy` were left
  unpinned and `asyncpg` omitted because their pinned versions have no
  CPython 3.14 wheels — the Modal image uses Python 3.12 where the pinned
  `gateway/requirements.txt` holds exactly.
- **21 tests UNVERIFIED locally, not failing**: all `async` tests plus the
  real-socket `test_meta_adapter.py` and the TestClient voice test. Cause
  is environmental and proven: this sandbox denies localhost `listen()`
  (WinError 10013), which Windows asyncio needs to create *any* event
  loop. No gateway runtime code was changed by this deployment work, and
  these same tests are green in CI (Linux); CI re-confirms on push.
- **`modal_app.py` imports cleanly** under `modal` 1.6.3 (spec
  construction only — no auth, no network, no deploy): app name
  `milo-gateway`, secret ref `milo-gateway`, image chain
  (`pip_install_from_requirements` + two `add_local_dir`) accepted. The
  check caught one real drift and it is fixed in the file:
  `allow_concurrent_inputs=` raises `DeprecationError` on 1.6.x, replaced
  by `@modal.concurrent(max_inputs=20)`.
- **CLI names verified** against `modal --help`: `setup`, `deploy`,
  `secret create SECRET_NAME [KEYVALUES]...`, `secret list`, `app logs`,
  `app stop`, `app list` — exactly as used in §4.
- **Flutter UNVERIFIED here** (no Flutter SDK on this machine): the only
  app change is the one-line `connectionWords` reword plus its test
  expectation; the existing `contains('Connected')` assertion still
  matches. CI runs `flutter analyze` / `flutter test` on push.
- **Fix found by testing**: `test_dart_and_python_contracts_agree` built
  its path with a forward-slash `str.replace`, which silently misses on
  Windows and then crashed on cp1252 decoding. It now uses
  `pathlib` + explicit UTF-8 (identical behaviour on Linux CI).
- **No deployment exists yet**: nothing was pushed, no secret created, no
  `modal deploy` run. The first deploy is yours (§4.1).

## 8. Hosted model: Muse Spark Shared Endpoint + staging (rewritten 31 Oct 2026)

Milo's hosted thinking is **Meta Muse Spark Open
(`meta-models/Muse-Spark-Open-816B-A42B`) served by Modal as a managed
Shared Endpoint** — Modal hosts the weights, we never deploy model
servers. There is deliberately no `models` deploy target anymore
(`gateway/modal_models.py` and its workflow step were deleted): the only
Modal-hosted model work is (a) creating the Shared Endpoint + proxy
token in the dashboard, (b) pointing staging/prod at it, (c) verifying
real inference. Two apps, three secrets:

| # | Modal app | Source | Secrets it reads | Serves |
|---|-----------|--------|------------------|--------|
| 1 | `milo-gateway-staging` | `gateway/modal_staging.py` | `milo-gateway-staging` + `milo-models-client` | full gateway, `REASONING_PROVIDER=modal`, `MODAL_FALLBACK=false`, scale-to-zero |
| 2 | `milo-gateway` (prod) | `gateway/modal_app.py` | `milo-gateway` (UNCHANGED) + `milo-models-client` + `milo-gateway-switches` | same, after staging verifies |

Model choice: Muse Spark Open is the ONLY Modal-hosted model. Do not
deploy Qwen3-4B or any other self-hosted server; do not silently
substitute another model if Spark is unavailable — the gateway fails
loudly (`MODAL_FALLBACK=false` on staging) or falls back to the
configured suite (prod, `MODAL_FALLBACK=true`). The gateway speaks plain
OpenAI-compatible `/v1/chat/completions` (+ `/v1/models` for the
connection test) to the endpoint; the request `model` is the documented
model id `meta-models/Muse-Spark-Open-816B-A42B` (NOT the endpoint
hostname — the proxy rejects unknown ids), and auth is the complete
proxy token (`Authorization: Bearer <id.secret>`), held server-side
only. Shared Endpoint per-token pricing is shown on the
endpoint page in the dashboard — confirm it there before relying on it
(this agent cannot see your balance or live rates).

### 8.1 [YOU] Shared Endpoint + secrets (Modal dashboard, one time)

Dashboard path (no CLI needed for the endpoint itself):

1. modal.com → your workspace → **Shared Endpoints** (or Models) →
   find `meta-models/Muse-Spark-Open-816B-A42B` → **Create endpoint**
   (or Enable). Note the endpoint base URL (ends `/v1`); the request
   `model` is always the documented id above, not the hostname.
2. On the same page, create a **proxy auth token** for the endpoint.
   This token is a server credential: it lives in the Modal secret
   below, never in the app, repo, or logs.
3. Secrets → **New secret**, names + keys exactly:
   - `milo-models-client`: `MODAL_MODELS_URL` = the endpoint base URL
     (must end `/v1`), `MODAL_MODELS_KEY` = the complete proxy token
     (`id.secret`, exactly as issued), `MODAL_MODEL` =
     `meta-models/Muse-Spark-Open-816B-A42B`.
   - `milo-gateway-staging`: `ENV=dev`, `PROVIDER=mock`,
     `REASONING_PROVIDER=modal`, `MODAL_FALLBACK=false`,
     `INFERENCE_TIMEOUT_S=20` (Spark needs room; prod keeps the 8 s default),
     `JWT_SECRET` (48+ random), `KEY_ENC_SECRET` (48+ random),
     `SPEND_BACKEND=modal_dict`, `SPEND_DICT_NAME=milo-spend-staging`,
     `DATABASE_URL=` (leave empty to exercise database-optional chat,
     or a throwaway Postgres URL to also test vault/sync).
   - `milo-gateway-switches` (prod only): `REASONING_PROVIDER=modal`,
     `MODAL_FALLBACK=true`. Keeps the `milo-gateway` secret
     byte-identical — create this before the first production deploy
     that uses hosted reasoning.

CLI equivalents for the secrets only (from the repo root, after `modal
setup` — the endpoint itself is dashboard-created):

```cmd
modal secret create milo-models-client MODAL_MODELS_URL=<endpoint base /v1> MODAL_MODELS_KEY=<proxy token id.secret> MODAL_MODEL=meta-models/Muse-Spark-Open-816B-A42B
modal secret create milo-gateway-staging ENV=dev PROVIDER=mock REASONING_PROVIDER=modal MODAL_FALLBACK=false INFERENCE_TIMEOUT_S=20 JWT_SECRET=<48+ random> KEY_ENC_SECRET=<48+ random> SPEND_BACKEND=modal_dict SPEND_DICT_NAME=milo-spend-staging
```

Or deploy via GitHub instead of local CLI: add repository secrets
`MODAL_TOKEN_ID` + `MODAL_TOKEN_SECRET` (from `modal token new` on your
machine), then Actions → `modal-deploy` → Run workflow → target
`staging`. Production additionally requires typing `DEPLOY-PROD` and
only passes with green gateway tests. The workflow deploys gateway
code only — it never creates the Shared Endpoint.

If a deploy step fails with `Token ID is malformed`, the workflow wiring
is fine — the `MODAL_TOKEN_ID` secret value itself is wrong (the check
only proves it is non-empty). Re-run `modal token new`, then re-paste:
Token ID (`ak-…`) into `MODAL_TOKEN_ID`, Token Secret (`as-…`) into
`MODAL_TOKEN_SECRET` (repo Settings → Secrets → Actions). Do not paste
a workspace/account ID, do not swap the two, and do not add whitespace
or a trailing newline. The workflow's `Validate Modal auth shape` step
reports presence, length, prefix shape and whitespace without ever
printing secret values.

### 8.2 [YOU] Deploy staging, verify each step

```cmd
modal deploy gateway/modal_staging.py
```

### 8.3 [YOU] Staging verification ladder (PowerShell)

Run against the **staging** URL (from `modal app list`). Each step must
pass before the next; anything failing here must never reach prod.

```powershell
$B = 'https://<workspace>--milo-gateway-staging-web.us-east.modal.run'
# 1. Health reports the hosted model honestly (not mock-as-hosted)
(Invoke-RestMethod "$B/v1/health") | ConvertTo-Json
# expect: reasoning_provider=modal, reasoning_model=meta-models/Muse-Spark-Open-816B-A42B,
#         vault_available=false (empty DATABASE_URL), spend_backend=modal_dict
# 2. Session + genuine streaming turn (mock suite would answer instantly with scripted text)
$tok = (Invoke-RestMethod -Method Post "$B/v1/session" -Body '{"install_id":"aaaaaaaaaaaaaaaaaaaa","app_version":"1.0.0","platform":"android"}' -ContentType 'application/json').token
$body = '{"presentation":"playful","text":"Why is the sky blue? Answer in one short sentence.","activity":"chat"}'
Invoke-RestMethod -Method Post "$B/v1/brain/turn" -Headers @{Authorization="Bearer $tok"} -Body $body -ContentType 'application/json' -TimeoutSec 240
# expect: SSE risk/body/say events with a FRESH one-sentence answer and
#         done.provider=modal — a ui_spec event may also arrive for activity-shaped
#         requests; plain chat turns carry {} (no panel)
# 3. Hosted outage fails loudly (staging has no suite fallback)
#    In the milo-models-client secret, temporarily set MODAL_MODELS_URL to
#    https://invalid.example/v1, redeploy staging, repeat step 2, and expect an
#    SSE error event (provider_error/unreachable) — NOT scripted mock text.
#    Then restore the real URL and redeploy staging.
# 4. Budget guard still bites (memory/modal_dict ledger, same code path)
#    covered by CI (test_budget_units.py); spot-check /v1/health budget_ok flips after heavy use
```

Telling the three apart: `done.provider` says which engine answered
(`mock` = scripted demo, `modal` = Muse Spark, `meta`/`openai`/… =
that vendor). Health 200 with `reasoning_provider=mock` is NOT hosted
inference; a `modal` turn with a fresh, prompt-specific answer is.

### 8.4 [YOU] Promote to production (only after 8.3 is green)

1. Confirm staging shows real `modal` turns, loud hosted-outage errors,
   and honest `vault_available=false`.
2. Create the `milo-gateway-switches` secret (§8.1). The `milo-gateway`
   secret itself stays byte-identical.
3. Deploy prod (code only): `modal deploy gateway/modal_app.py`, or the
   `modal-deploy` workflow with target `gateway-prod` + typed
   confirmation.
4. Re-run the §8.3 ladder against the production URL and confirm
   `reasoning_provider=modal`, `vault_available=true` (prod keeps its
   Postgres), `spend_backend=postgres`.
5. Rollback (hosted model misbehaving): remove `REASONING_PROVIDER` from
   `milo-gateway-switches` and redeploy — text falls back to the suite
   with zero code changes. Full rollback: redeploy the previous git SHA
   (§4.3).
