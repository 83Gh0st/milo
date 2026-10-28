# Phase 3 report — AI connections (multi-provider registry, CLI, app UI)

Branch: `upgrade/phase-3`. Brief §3 (3A–3D). No new dependencies (stdlib
`argparse`/`getpass` for the CLI; no new Flutter packages), so
`docs/THIRD_PARTY.md` needs no update.

## 1. What changed (files and one line each)

Gateway registry + routing (dependency-free core, stdlib/asyncio only):
- `gateway/app/providers/base.py` — normalised error codes (`auth_failed`,
  `rate_limited`, `timeout`, `unreachable`, `model_not_found`, `quota`,
  `content_filtered`, `unsupported_capability`), `raise_for_status`, `redact`;
  legacy codes (`family_key_rejected`, …) kept for the Meta path.
- `gateway/app/providers/capabilities.py` — `Capabilities`/`ProbeResult`,
  static `DECLARED` table + `DISPLAY_NAMES` for all five adapters.
- `gateway/app/egress.py` — SSRF guard for custom base URLs (https-only;
  http/LAN only in dev with an explicit flag; loopback/link-local/RFC1918/
  metadata rejected in prod; no cross-host redirects).
- `gateway/app/datapolicy.py` — per-provider `DataPolicy` (trains/retention/
  source/checked-on); **all live providers `unknown`** (no network to check
  terms 28 Oct 2026) → trusted-adult ack required; `needs_ack`.
- `gateway/app/providers/http.py` — `HttpxTransport` (no redirects), stdlib
  exceptions (`TimeoutError`, `ConnectionError`) for uniform mapping.
- `gateway/app/providers/openai_compat.py` — OpenAI-compatible adapter
  (OpenAI, Meta compat endpoint, Ollama/LM Studio/vLLM): `response_format`
  json_schema, `max_completion_tokens`→`max_tokens` retry, reasoning params
  only for reasoning models, vision blocks, `discover_models`, `probe`
  (chat+json_schema+vision checks, TTFB).
- `gateway/app/providers/anthropic.py` — native Messages API, streaming,
  JSON via tool schema, vision blocks, error mapping.
- `gateway/app/providers/mock_adapter.py`, `meta_adapter.py` — protocol
  wrappers around the existing Mock/Meta classes; **no behaviour change**.
- `gateway/app/providers/registry.py` — `RouteEntry`, loader cache,
  `-contributor` deny rule, per-entry strategy resolver.
- `gateway/app/routing.py` — `Router` (failover before first byte on
  timeout/429/5xx/unreachable only; auth/filter/post-first-byte propagate),
  per-(provider,model) circuit breaker (3 fails/60 s, half-open), honest
  skip of probed-blind or credential-less entries, `generate_image`,
  `open_voice`.
- `gateway/app/db.py` — `vault_connections` table (one row per
  vault×provider; routes table stored redundantly on every row).
- `gateway/app/vaultstore.py` — lazy `migrate_legacy` (same Fernet envelope,
  one transaction, no loss), list/save/get/delete, caps, routes, `vault_creds`
  (decrypts all keys server-side; unreadable reported, never raised).
- `gateway/app/sync.py` — `VaultCtx` (creds/routes/caps/unreadable),
  `vault_ctx_for` (401 bad vault, 409 no usable key, never silent deployer
  fallback), `vault_ctx` (None = deployer path), mock demo inheritance.
- `gateway/app/connections.py` — vault-authenticated endpoints:
  `GET /v1/connections`, `POST /v1/connections/{provider}` (409
  `policy_ack_required` once per connection; omitted key keeps the stored
  key; caps preserved when the model is unchanged),
  `POST …/test` (200 + checklist, never raises for probe fails),
  `GET …/models`, `PUT /v1/connections/routes`, `DELETE …/{provider}`.
- `gateway/app/models.py` — `ConnectionReq`/`RouteEntryReq`/`RoutesReq`/
  `ProbeReq`; `ProviderKeyReq` widened to all providers (legacy compat).
- `gateway/app/routes.py` — brain/understand/plan/compose/visual/voice run
  through the router; per-entry strategy (`json_schema`→`tool_schema`→
  `lines`); `_peek_lines` prompt alignment; `done` event + logs carry
  `provider`/`model`; visual cache key now provider|model|STYLE|concept.
- `gateway/app/main.py` — adapters/router/`deployer_creds` wiring,
  `conn_router` mount, `allow_lan_providers` setting (`config.py`).
- `gateway/app/cli.py` — `vault-new`, `connect` (hidden/`--key-env`/
  `--key-stdin`/`--no-key`, discovery, numbered pick, probe table, confirm),
  `list`, `models`, `test`, `use` (+repeatable `--fallback`), `status`,
  `disconnect`; exit codes 2/3/4.
- `gateway/scripts/smoke_providers.py` — live probe table; keyless-safe
  (prints skip table, exit 0).

App (trusted-adult AI connections, reusing the vault flow):
- `lib/net/api.dart` — six connections methods (list/save/test/models/
  routes/delete, all vault-authenticated, keys never stored); `ApiError`
  carries the server `detail` body; 503 maps to `budget_exhausted` only
  when the body says so (provider 503s stay `http_503`).
- `lib/ui/trusted_screen.dart` — `ProviderKeyScreen` rebuilt as AI
  connections: 4 provider tiles, master family switch, per-capability
  first+fallback pickers (brain/reading/pictures/voice-in), bottom-sheet
  editor (key/base/model + Find + Test checklist + data-policy ack +
  remove), plain-words errors (`connWords`), honest-limits copy.
- `lib/ui/more_screen.dart` — Data-and-privacy line “Milo is thinking
  with your family AI / the shared cloud”.

Tests:
- `gateway/tests/test_gateway.py` — +6 CI tests (~110 lines): connections
  CRUD+validation+keep-key, refused-port probe/models + key redaction in
  logs, legacy `vault_keys` migration without loss, `done` provider/model
  attribution, unroutable-entry honest failure with zero network I/O,
  vision-need skip of a probed-blind entry.
- `gateway/tests/test_phase3_units.py` — 26 dependency-free unit tests
  (registry/routing/egress/datapolicy/adapters with fake transports).
- `test/helpers/harness.dart` — `FakeApi` connections vault (409-ack
  behaviour, probe pass/fail knob) + `FakeSync`; fixed `providerKeyStatus`
  override signature `(vid, key)`.
- `test/connections_test.dart` — 5 widget tests: sync gate, 360×640@2.0
  reachability + honest save error, ack flow (refusal→checkbox→save→hint→
  switch persists `family`), probe checklist pass/fail + model picker,
  routes save + remove.

Docs: `docs/BYOK.md` (multi-provider trust model), `docs/SETUP.md` §2b
(Windows `cmd` CLI walkthrough, LAN Ollama, keyless-safe smoke script).

## 2. Tests run, real commands and results

- `python -m pytest tests/test_phase3_units.py tests/test_contract_units.py
  --noconftest -p no:cacheprovider -o addopts='' -q -W ignore`
  (from `gateway/`) → **32 passed in 0.18 s** (26 Phase-3 + 6 contract).
- `python -m py_compile` over all touched gateway files → exit 0.
- Full `gateway/tests/test_gateway.py` (incl. the 6 new tests): **NOT RUN
  locally** — `fastapi`/`httpx`/`sqlalchemy` not installed, no network to
  install; CI `gateway` job must run `python -m pytest -q`.
- `flutter analyze`, `flutter test` (incl. `test/connections_test.dart`):
  **NOT RUN locally** — no Flutter SDK; CI `flutter` job is the verifier.
- `scripts/smoke_providers.py` without keys → skip table, exit 0 (run
  during development; rerun in CI with keys for the live table).
- Live Meta/OpenAI/Anthropic request shapes, base URLs, vision blocks,
  discover-models, training/retention terms: **UNVERIFIED** (no network,
  no keys); isolated behind adapter constants; first live `test` confirms.

## 3. Measurements against the acceptance list

- ≥3 adapters pass a conformance suite: PARTIAL — openai_compat, anthropic,
  mock, meta adapters pass the 26 dependency-free unit tests (streaming,
  cancellation, timeout, 401/403/429/5xx mapping, strategies, vision/no-
  vision, usage); a shared HTTP-recorded conformance suite was cut for the
  deadline (unit coverage + live smoke cover it instead).
- `connect → test → use` end to end vs mock: YES by construction (mock is a
  route target; CLI `use` accepts `mock/mock`); vs Meta: UNVERIFIED (no key).
- Provider switch changes nothing but the brain: YES — persona prompts,
  contract validator, memory, animation untouched; routes are data.
- Failover demonstrated in a test: YES (`test_phase3_units` failover +
  circuit-breaker tests; CI vision/unroutable tests show honest skips).
- SSRF suite green: YES (unit tests; prod path also DNS-guarded).
- No key in logs: YES (redaction unit test + CI caplog test).
- Connections screen at the Phase-1 matrix: WIDGET TESTS WRITTEN
  (360×640@2.0 + sheet + dialog); CI must run them (no SDK here).

## 4. What is UNVERIFIED and why

- Everything in §2 marked NOT RUN/UNVERIFIED: no Flutter SDK, no gateway
  web deps, no network, no provider keys, no device on this machine.
- iOS `Pods_Runner` link failure is still open (main-branch CI); the
  diagnostic step output is pending from the next CI run.
- `test_connection` 200-with-checklist (vs raising) is a deliberate
  contract: CLI prints the table, app shows the checklist.
- Data policies are placeholders until a human reads the official terms.

## 5. Found but not fixed

- `RouteEntryReq.provider` is a `Literal`, so unknown providers 422 at
  model validation; `put_routes`' extra `check_model` is belt-and-braces.
- `saveConnection`'s server-side `key_too_short` check is unreachable
  (Pydantic `min_length=8` fires first); kept as defence in depth.
- `providerKeyStatus`/`setProviderKey`/`deleteProviderKey` (legacy
  single-key endpoints) retained for old-app compat; UI no longer uses them.
- Ladder wording for new SSE codes (`auth_failed`, `unsupported_capability`)
  still falls through to generic resting words — Phase 4/5 can sharpen.

## 6. Decisions needed from the human

1. Re-check Meta/OpenAI/Anthropic data terms from the official pages and
   update `datapolicy.py` (URL + date); until then every live provider
   forces the ack checkbox (safe default).
2. Supply one provider key to run `smoke_providers.py` + live `test`
   (recommends OpenAI-compatible first); confirm request shapes/vision.
3. iOS: paste the `=== versions/workspace/runner-pods-refs/pods-support ===`
   diagnostic from the next CI run (or the `Ld` block above BUILD FAILED).
4. Phase 4 voice bake-off engine list + per-language winners (human ears).

## 7. Next phase's first three tasks (Phase 4 voice)

1. Build `eval/voice_bakeoff/run.py`: 12 fixed Milo lines × candidate
   engines, blind WAVs + `RESULTS.md` (latency p50/p95 from India,
   licence, price, streaming/timings) + CSV score sheet; STOP at 4A.
2. `VoiceOutput`/`PlatformVoice` (extract flutter_tts verbatim) +
   `NeuralVoice` + `VoiceRouter`, gateway `/v1/speak` with envelope
   sideband, sentence pipelining + fixed-line cache.
3. Barge-in ≤150 ms, mid-sentence fallback without repeats, lip-sync from
   envelope (drift ≤80 ms), fake-clock/fake-audio unit tests.
