# Milo architecture

How the system fits together: Flutter app, FastAPI gateway, Meta models on
Modal and the Model API, BYOK routing, offline operation, and the safety
boundaries between them. For setup and workflows, see
[`DEVELOPMENT.md`](DEVELOPMENT.md); for install/runbooks,
[`docs/SETUP.md`](docs/SETUP.md), [`docs/MODAL.md`](docs/MODAL.md),
[`docs/RELEASE.md`](docs/RELEASE.md). The original pre-build blueprint is
[`Milo_Architecture_and_Build_Plan.pdf`](Milo_Architecture_and_Build_Plan.pdf);
this file describes the system as built.

## 1. System architecture

<p align="center">
  <a href="docs/images/architecture.svg"><img src="docs/images/architecture.svg" width="850" alt="Milo system architecture: Flutter app, FastAPI gateway, and model providers"></a>
</p>

<p align="center"><em>Phone, gateway, and providers. Green is staging-verified, amber needs a keyed run.</em></p>

```mermaid
flowchart TB
    Person((Person)) --> App
    subgraph Phone[Phone - Flutter app]
        App[Milo app]
        Char[Companion engine<br/>Director, v2 rig, TTS]
        Store[(Encrypted SQLite<br/>memory, ledger, settings)]
        App --- Char
        App --- Store
    end
    App -->|SSE brain turns| GW
    App -->|photos, pictures| GW
    App -->|voice websocket| GW
    App -->|E2EE blobs| GW
    subgraph Cloud[Gateway - FastAPI on Modal or VPS]
        GW[Gateway<br/>auth, contracts, safety,<br/>spend, routing]
        DB[(PostgreSQL or SQLite<br/>optional for chat)]
    end
    GW -->|hosted reasoning| Spark[Muse Spark Open 816B<br/>Modal Shared Endpoint]
    GW -->|pictures| Img[Muse Image 1.0<br/>Meta Model API]
    GW -->|transcription| Voi[Muse Voice Transcribe 1.0<br/>Meta Model API]
    GW -->|family keys| BYOK[BYOK providers<br/>Meta, OpenAI, Anthropic,<br/>Gemini-compatible, custom]
    GW --- DB
```

Design rules: the model proposes, the app disposes (every model field is
validated against closed contracts); ledger-before-send (every cloud call is
recorded on-device first); offline-first (nothing essential needs the
gateway); no silent fallbacks (a failed provider errors honestly in words).

## 2. Flutter application layers

```
lib/
  main.dart            Gate (onboarding check + intro veil), Shell (tabs, ticker, ladder speech)
  companion/           Director (single writer of companion state), emotion, greetings,
                       milo_view (touch -> reactions), v2/ (code-drawn rig: frame, renderer)
  core/                providers (router, ladder, panel, vault wiring), payload (request
                       bodies + ledger summaries), memory, pocket_brain (offline fallback),
                       ai_provider (hosted/family choice), safety
  contracts/           brain_contract (turn validator), events (SSE event model)
  genui/               spec (UI-spec validator), panel (state + ops), widgets (registry)
  data/                MiloDb (SQLCipher), SecureStore (PIN, keys)
  net/                 api (Dio client, ledger-first, timeouts), voice (mic websocket)
  media/               photo prep (resize, EXIF wipe)      sync/  E2EE sync service + crypto
  ui/                  screens, scaffold (header, dock, rail), theme, intro, brand
  voice/               TTS normalization + output lifecycle
```

- **Core router** (`core/providers.dart`): each turn tries local safety
  pre-filter → memory commands → local intents → cloud brain → pocket brain,
  in that order. Document chips (`You are reading this now`) scope follow-ups.
- **Director** (`companion/director.dart`): owns emotion, gesture, gaze,
  speech, and presence; paints only from `DirectorFrame`. Speech follows the
  audio lifecycle, never animation timers (`docs/VOICE_CHECKLIST.md`).
- **Ladder** (`full/cloudOff/offline/resting`): one status chip + spoken
  words per state; inference trouble never claims the network is down.
- **Timeouts:** connect 8 s, send 15 s, receive 30 s - the receive side stays
  above the gateway's inference deadline with room for error handling.

### Navigation and screen relationships

Five tabs in the shell (`main.dart`): Home (companion stage, continue card,
Understand/Express/Do entry cards), Explore (section cards with offline
badges), Milo (chat), Progress (counts and charts), More (profile,
accessibility, language, offline switch, privacy, about). Feature screens
(Understand, Express, Do, Learn, Calm, check-in, trusted adult) push on top;
Break and Help me live in every header (`ui/scaffold.dart`); the trusted-adult
area sits behind a PIN gate (`ui/pin.dart`). The as-built map is
[`docs/images/app-wireflow.svg`](docs/images/app-wireflow.svg).

## 3. Gateway and provider abstraction

```
gateway/app/
  main.py        app factory, lifespan, default routes per capability
  routes.py      /v1/session|health|brain/turn|understand|plan|compose|visual|image|voice|sync/*|connections/*
  prompts.py     five-layer prompt builder (persona, context, history, document, media note)
  contract.py    brain + UI contracts loaded from contracts/ (single source of truth)
  models.py      request shapes (BrainReq, UnderstandReq, VisualReq, ImageReq, ...)
  ui_spec.py     UI-spec sanitizer (returns None on unusable specs - never breaks a turn)
  safety.py      crisis screen, Assembler (streams validated SSE events), PII/URL stripping
  routing.py     capability router: ordered entries, pre-first-byte failover, circuit breakers
  providers/     meta (Model API suite), modal_hosted (Spark Shared Endpoint),
                 openai_compat, anthropic, mock + registry, capabilities, probes
  spend.py       daily/monthly ledger (postgres → Modal Dict → memory, always capped)
  security.py    JWT sessions, rate limits      sync.py  vault contexts + E2EE blob store
  streaming.py   SSE/JSON parsers               datapolicy.py  per-vendor training/retention terms
```

Capabilities route independently: `brain`, `understand`, `plan`, `compose`
need `text_stream` (+ `vision` when a photo rides along); `visual` needs
`image_gen`; `stt` needs `audio_in`. Each capability has an ordered route
list of `(provider, model)`; failover retries the next entry only before the
first byte and only for timeout/429/5xx/unreachable. Auth, content-filter,
and post-first-byte errors propagate immediately. Circuits open after 3
failures in 60 s. Clients never choose providers; the server uses saved routes.

## 4. Modal-hosted Muse Spark Open

Primary reasoning: `meta-models/Muse-Spark-Open-816B-A42B` behind a
Modal-managed Shared Endpoint (OpenAI-compatible chat completions, proxy-token
auth, server-side only). No weights are deployed by this repo; the endpoint is
created in the Modal dashboard. The `ModalAdapter` sends a stock OpenAI
payload (reasoning-cap bumped to 2000 tokens - Spark reasons out loud and the
shared 900-token default truncated live turns mid-JSON).

Staging and production are separate Modal apps (`modal_staging.py`,
`modal_app.py`) with separate secrets; staging sets `MODAL_FALLBACK=false`
and `INFERENCE_TIMEOUT_S=20` so hosted behaviour is tested loudly. Full
runbook and the 7-step verification ladder: [`docs/MODAL.md`](docs/MODAL.md).

## 5. Image generation (separate capability)

Pictures are drawn by `muse-image-1.0` (Meta Model API), never by Spark, and
Milo never claims otherwise. Flow: Spark writes a `genimage` UI node →
gateway + client validators check it → the panel shows a Create button
(explicit consent; nothing auto-draws) → tap → `POST /v1/image` screens the
prompt (deny-list, 140-char cap) and wraps it in a fixed child-safe cartoon
style (never photorealistic, no text, no real people) → provider bytes return
with an `X-Milo-Image: ai-generated` header → panel shows the picture with an
"AI-made picture" label and model-written alt text (fallback synthesized when
missing). Bytes live in a memory-only provider; the server caches by content
hash for cost control with no user link. Agentic tool use (web/image search,
shell) is disabled and reasoning is low: a picture request must not browse or
run code. Credential: deployer `MODEL_API_KEY` or family BYOK Meta key; with
neither, Milo says drawing needs a grown-up to set it up.

## 6. Image understanding (vision turns)

`POST /v1/understand` takes text plus an optional photo and streams back an
explanation (`risk`/`say`/`done` events). The gateway builds a vision-capable
chat payload (`image_url` parts) and sends it down the Spark route; the same
closed-contract validation applies as for brain turns. On the phone,
`media/photo.dart` resizes, strips EXIF/GPS, and deletes the original before
anything is sent, while on-device OCR (ML Kit) feeds read-aloud so the words
on the page are available even offline. Exercised on staging with a photo run
(`live_probe.py --photo`); see [`docs/MULTIMODAL.md`](docs/MULTIMODAL.md) for
the endpoint analysis behind the wiring.

## 7. SAM segmentation (object boxes)

`POST /v1/segment` takes a photo plus one noun phrase ("the red ball") and
returns normalized boxes the `SegmentOverlay` renderer draws over the image
for tap-a-box explanations. The gateway path is wired to the SAM 3.1 wire
format from Meta's cookbook, but no keyed run has passed yet, so staging
serves deterministic mock boxes (`model: "mock"`) and says so in the payload.
`gateway/scripts/probe_sam.py` is the promotion check: exit 0 plus JSON with
a real key flips the catalog row to live. Video and masks are deferred.

## 8. Voice: transcription in, speech out

Speech-to-text and text-to-speech are separate systems that meet only in the
conversation. Input is push-to-talk: the app streams 16 kHz PCM frames over
the realtime Transcribe socket (`muse-voice-transcribe-1.0`, zero-retention
flag, language and vocabulary hints in the first frame) and renders partials
live, with typed input always available as the fallback. Output today is
platform TTS (`flutter_tts`) driven through the voice router in
`lib/voice/voice_output.dart`, with text normalization (`normalize.dart`) and
word-level read-aloud callbacks; the `/v1/speak` endpoint plus the neural
pipeline exist as the online-voice hook, and with no engine configured the app
says plainly that online voice is not set up yet. Mouth movement follows the
audio envelope and shuts in silence.

## 9. BYOK vault and routing

Families connect their own provider keys in-app (Trusted adult → AI
Connections, PIN-gated): pick provider, paste key, run a real probe (text,
schema, vision checks), activate per capability. Keys are sealed at rest with
`KEY_ENC_SECRET`, travel per-request in vault headers over TLS, and never
appear in logs, bundles, analytics, or crash reports. Family turns spend the
family's quota and skip the deployer budget; there is no deployer fallback on
family requests. Status shows configured / tested / active separately - a
saved key alone never reads "connected". Trust model:
[`docs/BYOK.md`](docs/BYOK.md).

First-party Meta surface (endpoint, model, creds, cost, honesty status per
capability) is data, not prose: `gateway/app/providers/meta_catalog.py`
(`live` only for staging-verified rows, enforced by tests).

## 10. Local and offline functionality

Without any connection: the Express board, composer, quick help, routines,
memories, read-aloud (platform TTS + on-device OCR), the full character, and
the pocket brain (hand-written local flows incl. crisis support) all run from
encrypted on-device SQLite. Cloud sync is optional, off by default, E2EE
(server sees opaque blobs only), and a separate permission from cloud AI
(`docs/SYNC_DESIGN.md`, `docs/DATA_MAP.md`). The gateway itself is
database-optional: with no `DATABASE_URL`, chat, hosted AI, and BYOK work;
vault/sync report honestly unavailable.

## 11. Generative UI contract and validation

Spark may attach a `ui_spec` object to any turn: `{v, activity, intent,
mode, companion, speak, state, root, ops}`. Eleven component types (`text`,
`card`, `button`, `choices`, `checklist`, `progress`, `steps`, `list`,
`image`, `genimage`, `divider`), six closed actions, six patch ops
(`add/update/replace/move/remove/state`), stable ids preserved across turns,
atomic batches, ≤40 nodes, depth ≤4, flat scalar `ui_context` (≤12 keys).
Both validators (gateway `ui_spec.py`, client `genui/spec.dart`, parity-tested)
sanitize every string; anything malformed degrades to classic chat - the turn
never breaks. `image` nodes use the visual-concept allow-list; `genimage`
nodes carry `{prompt, alt}` for the flow in §5. Full protocol:
[`docs/GENUI.md`](docs/GENUI.md).

## 12. Privacy, consent, safety, spending

- Ledger-before-send for every cloud call; per-device consent log; PIN-gated
  grown-up area; no ads/analytics; crash reports carry no content.
- Crisis/check-in flows are local and hand-written; the model never sees
  crisis turns as normal input.
- `-contributor` model IDs refused at startup; voice requests zero data
  retention; photo originals (EXIF/GPS) deleted right after prep.
- Spend: daily + monthly deployer guards, per-request metering, persistent
  ledger when a database exists, capped ephemeral memory ledger otherwise
  (`EPHEMERAL_DAY_USD=5`), Modal Dict backend on serverless. Family keys
  exempt by design. Budget trips speak plainly and drop to the pocket brain.

## 13. Error handling, timeouts, provider failure

Timeout chain (whole-completion unless noted): Flutter receive 30 s >
gateway `INFERENCE_TIMEOUT_S` (staging 20 s, prod 8 s) wrapping provider
selection + the full token stream > httpx connect 10 s + read/write at the
deadline. `POST /v1/brain/turn` always returns HTTP 200 with mid-stream
`error` events on failure - the app maps codes to spoken words
(`timeout`, `budget_exhausted`, `auth_failed`, `quota`, Spark-specific
wording for hosted timeouts) and the pocket brain keeps helping. Image turns
get 60 s; voice sockets 5–15 s per leg. Gateway offline vs inference trouble
stay separate in both UI and words.

## 14. Request sequences

### Text reasoning turn (hosted Spark)

```mermaid
sequenceDiagram
    participant P as Person
    participant A as Flutter app
    participant G as Gateway
    participant S as Spark Shared Endpoint
    P->>A: speaks or types
    A->>A: router, safety screen, ledger entry
    A->>G: POST /v1/brain/turn SSE
    G->>G: auth, budget, contract build
    G->>S: chat completions, stream
    S-->>G: tokens
    G-->>A: risk, body, say, ui, memory, ui_spec, done
    A->>A: validate, emote, speak, render panel
    A->>P: voice, face, activity
```

### Image generation turn (Muse Image)

```mermaid
sequenceDiagram
    participant P as Person
    participant A as Flutter app
    participant G as Gateway
    participant M as Muse Image API
    P->>A: draw a friendly dinosaur
    A->>G: brain turn SSE
    G-->>A: ui_spec genimage prompt plus alt
    A->>P: Create button, no autodraw
    P->>A: taps Create
    A->>G: POST /v1/image
    G->>G: screen prompt, wrap style, budget
    G->>M: generate, tools off
    M-->>G: PNG bytes
    G-->>A: PNG plus AI-generated header
    A->>P: picture, disclosure, alt text
```

### BYOK provider routing

```mermaid
sequenceDiagram
    participant P as Trusted adult
    participant A as Flutter app
    participant G as Gateway
    participant V as Vendor API
    P->>A: paste key, Test connection
    A->>G: probe with sealed key
    G->>V: text, schema, vision checks
    V-->>G: probe results
    G-->>A: tested status
    P->>A: activate for brain
    A->>G: brain turn with vault headers
    G->>G: unseal key, family route
    G->>V: inference, family quota
    G-->>V: inference, family quota
    V-->>G: tokens
    G-->>A: validated SSE events
```

## 15. Deployment and environment

Two Modal serverless apps: `gateway/modal_staging.py` (deploy freely, verify
with the [`docs/MODAL.md`](docs/MODAL.md) ladder) and `gateway/modal_app.py`
(production, only after staging passes; `modal-deploy.yml` needs
`confirm_prod=DEPLOY-PROD`). Each app attaches three named secrets: the
gateway settings secret (`milo-gateway-staging` / `milo-gateway`), the Shared
Endpoint client (`milo-models-client`: URL, proxy token, model id), and the
routing switches (`milo-gateway-switches`: `REASONING_PROVIDER`,
`MODAL_FALLBACK`). The variable table lives in the README's installation
section; the VPS alternative (Caddy + Compose in `deploy/`) is documented in
`docs/DEPLOYMENT.md`. CI (`.github/workflows/`) runs gateway tests, analyze,
the full Flutter suite, a staging APK, and an iOS simulator build on every
push.
