# Milo multimodal: audit, architecture, and verification

Muse Spark Open understands images but outputs text only. Pictures children
ask for are drawn by Muse Image (`muse-image-1.0`, a separate model family)
through the Meta Model API. Milo never claims Spark drew a picture it did not.

## 1. Capability audit (verified in code, not assumed)

| Capability | Status | Evidence |
|---|---|---|
| Photo capture + prep | Working | `lib/ui/chat_screen.dart` (`Show Milo`), `lib/ui/understand_screen.dart`, `lib/media/photo.dart` (1600 px cap, EXIF/GPS wipe, original deleted) |
| Image → model (Understand) | Wired, needs live verification | `UnderstandReq.image_b64` → `build_messages` OpenAI `image_url` parts → `need="vision"` routing; vision probe in `OpenAICompatAdapter.probe` |
| Image → model (chat) | By design text-only | `BrainReq` has no image field; chat photos route to Understand instead |
| Hosted vision declaration | Staging-verified | The deployer path tries entries blindly (`routing.py` filters only the family `caps_map` path), and the staging ladder's `--photo` run returned a real description through the hosted endpoint |
| Cloud voice input (Meta) | Wired, needs keyed verification | mic → `/v1/voice` websocket → `muse-voice-transcribe-1.0` (zero retention requested); typed input always available as fallback |
| Model audio understanding / video | Unsupported | Transcription turns speech into text; the reasoning endpoint never receives raw audio or video |
| Picture generation | Implemented this pass | `POST /v1/image` → `router.generate_image` (visual entries) → `MetaImage` (`muse-image-1.0` at `api.meta.ai/v1`) |
| Generated-picture display | Implemented this pass | GenUI `genimage` node: tap-to-create, AI-made disclosure, mandatory alt text |

## 2. Multimodal input architecture (as built)

```
camera/gallery --(OS permission)--> preparePhoto --> base64
    --> /v1/understand {image_b64} --> vision entry --> Spark understands
    --> explanation spoken + shown; bytes never touch disk or memory stores
```

- Chat stays text-only on purpose: image bytes would ride every follow-up
  turn at full context cost. "What is this?" in chat uses the Understand
  route, which is the same model with the picture attached.
- OCR runs on-device first, so read-aloud works fully offline.
- Video/audio files: unsupported honestly on BOTH paths. The cloud prompt
  forbids inventing media content ("say so plainly, offer what you can do
  instead") and the offline pocket brain has matching "I can't watch
  videos / play audio files yet" replies. Talking TO Milo is different:
  live speech is transcribed by Muse Voice Transcribe through the gateway
  websocket (zero data retention requested), and only the resulting TEXT
  goes to Spark; typed input always works as a fallback.

## 3. Image generation architecture (as built)

```
child: "draw a dinosaur" --> Spark returns ui_spec {genimage prompt+alt}
    --> Milo validates (both gateways: contract + client validators)
    --> panel shows Create button (explicit consent, nothing auto-draws)
    --> tap --> POST /v1/image --> screen + child-safe wrap
    --> Muse Image (BYOK Meta key or deployer key) --> PNG bytes
    --> panel shows picture + "AI-made picture" + visible alt text
```

- `POST /v1/image {prompt}`: 2–300 chars, URL/PII-stripped, capped at 140,
  screened against a deny-list (`prompt_not_allowed` on 422), then wrapped
  in a fixed child-safe cartoon style (never photorealistic, no text, no
  real people). Ledger-before-send; deployer turns metered at `price_image`
  ($0.01); bytes cached by content hash with no user link.
- Credentials: a Meta Model API key (`LLM|...`, from dev.meta.ai) - either
  the deployer's `model_api_key` secret or, preferably, the family's own
  BYOK key in the encrypted vault (no shared-spend abuse vector). Without
  any key the endpoint fails honestly (`image_failed`/auth error → Milo
  says drawing needs a grown-up to set up picture access).
- Muse Image is NOT on Modal and needs no Modal deployment: it is a
  Meta-hosted API, also reachable via OpenRouter/fal - any of them can be
  wired as a BYOK `custom` entry later without touching this flow.
- Agentic extras stay off: `tool_enablement` (web/image search, shell) is
  disabled and reasoning is low - a picture request must not browse or run
  code.

## 4. Safety and accessibility rules (enforced, not aspirational)

- Camera/mic: OS permission at capture + onboarding toggles; nothing
  essential requires them.
- No auto-generation, no retention: bytes live in a memory-only provider
  (`genImageProvider`), cleared with the session; server cache is
  content-hash keyed.
- Every generated picture discloses itself ("AI-made picture", header
  `X-Milo-Image: ai-generated`) and carries model-written alt text, shown
  visibly and exposed to screen readers; a fallback alt is synthesized
  when the model omits it.
- No emotion recognition anywhere; quiet mode and reduced motion are
  unaffected (pictures are static).
- The offline board never touches any of this: generation requires
  `cloud.enabled`, fails honestly offline, and is never a dependency.

## 5. Staged verification (staging only; production untouched)

1. **Vision probe** (done on staging): one JPEG to staging
   `/v1/understand` with `image_b64` returned a real description through the
   hosted endpoint. Still open: the same check from the app on a device, and
   a family-keyed (BYOK) vision turn.
2. **Picture flow**: configure a Meta API key (BYOK), say "draw a friendly
   dinosaur", tap Create, confirm PNG + disclosure + alt; then try a denied
   prompt ("dinosaur with a gun") and confirm the kind refusal.
3. **Budgets**: confirm `price_image` metering on deployer turns and no
   charge path on family turns.
4. Later, if ever: video frames-as-images and model audio input need new
   endpoint capabilities - do not fake them with the text endpoint.

## 6b. Extended Meta capabilities (registry: `meta_catalog.py`)

- **SAM 3.1 (`sam-3.1`, wired, live-unverified).** `POST /v1/segment` takes
  one photo + one noun phrase and returns normalized boxes, implemented from
  Meta's cookbook wire format (Responses API stream, parsed ONLY with
  `meta_sam_parser` - the gateway never hand-parses SAM text). The Understand
  photo flow offers "Find things in this photo" when cloud AI is on; tapping
  a box explains that object against the same photo via the Understand path.
  Verify live with `MODEL_API_KEY=... python gateway/scripts/probe_sam.py
  photo.jpg --concept heart` (exit 0 + JSON = the endpoint works), set
  `SAM_VERIFIED=true` on the server, redeploy, and then run
  `python gateway/scripts/live_probe.py --photo photo.jpg` (end-to-end
  through the gateway). Video tracking and mask rasters are deferred: the
  overlay draws boxes, which is what "point at the words" needs.
- **Muse Wonder 1.0 (wired, gated, keyed run pending).** Preview agentic
  reasoner, 1M context, effort `minimal` to `max` ($4/$20 per M tokens),
  called over Chat Completions like Spark. Routable for plans and stories
  only: `PUT /v1/connections/routes` rejects it for every other capability,
  the AI Connections screen offers it on the Plans and Stories rows, no
  default route names it, and auto-routes never place it on ordinary turns.
  A deliberate `SPARK_MODEL=muse-wonder-1.0` deployer override still
  validates, but per-capability routing is the supported path.
- **Muse Glimmer 30B (operator-run local).** Apache-2.0 open weights, NOT on
  the Model API, NOT on phones (30B/4-bit ≈ 20 GB - needs ~24 GB VRAM or an
  equipped Mac). Run `ollama run muse-glimmer:30b`, connect Milo to
  `http://<lan-ip>:11434/v1` as a Custom/local BYOK endpoint (key optional),
  and data never leaves your network. The eval harness already speaks to it
  (`JUDGE_BASE_URL=http://localhost:11434/v1 JUDGE_MODEL=glimmer`).
- **Tools, search grounding, files (declined with rationale).** Chat
  Completions function tools and Responses `web_search` exist on the Model
  API, and JSON-schema structured output already ships in Milo. Web browsing
  and arbitrary tool execution stay OFF for a children's product: unvetted
  web content + side effects contradict the closed-action safety contract.
  Enablement path if ever wanted: trusted-adult-gated allow-listed tools,
  one execute-and-feed-back loop, ledger per call - a design review, not a
  flag flip.

## 6. Providers, credentials, costs, limits

| Need | Credential | Cost | Limit |
|---|---|---|---|
| Hosted reasoning (Spark) | Modal proxy token (server secret) | Modal inference | text out only |
| Pictures (Muse Image) | Meta Model API key (deployer secret or BYOK vault) | $0.01/image | sub-2K, no captioning; community notes on strict violence filter |
| Voice input (Transcribe) | Meta Model API key (deployer secret or BYOK vault) | $0.18/hr audio | transcription only; typed fallback always available |
| Segmentation (SAM 3.1) | Meta Model API key (deployer secret or BYOK vault) | priced per 1k images (metered $0.01/call until dashboard confirms) | wired, live-unverified |
| Long-form plans/stories (Wonder) | Meta Model API key (same one key) | $4/$20 per M tokens | wired, gated, keyed run pending |
| Local (Glimmer 30B) | none (own hardware) | ~24 GB VRAM / Mac | via Custom endpoint |
| BYOK text/vision | Family provider key (vault) | family's own | per vendor |

No PostgreSQL required for any of this; no new Modal deployment needed.

## 7. Capability evidence matrix (honest status, 2026-11-02)

Columns: implemented in code, unit-tested, mocked-provider tested, live-tested
against the real endpoint, integrated in the Flutter UI, verified on a real
device. "Staged" live results below are from the staging gateway runs; nothing
here claims production verification.

| Capability | Impl | Unit | Mock | Live | UI | Device |
|---|---|---|---|---|---|---|
| Hosted reasoning (Spark Open via Modal) | yes | yes | yes | yes (staging ladder: real turns, `done.provider=modal`) | yes (chat) | needs run |
| Structured GenUI (`ui_spec`) | yes | yes | yes | yes (staging: valid `ui_spec` events) | yes | needs run |
| Story generation (`/v1/story` + StoryTime) | yes | yes | yes | yes (staging ladder, `told_by` surfaced) | yes | no |
| Image understanding (`/v1/understand` + photo) | yes | yes | yes | yes (staging ladder incl. `--photo` run) | yes | no |
| Image generation (`/v1/image`, Muse Image) | yes | yes | yes | no - run `live_probe.py` after deploy | yes (story art, tile art, chat) | no |
| Segmentation (`/v1/segment`, SAM 3.1 boxes) | yes | yes | yes | no - run `probe_sam.py`, then `live_probe.py --photo` | yes (Find things panel) | no |
| Voice transcription (Transcribe) | yes | yes | yes | no - on-device mic check only | yes | no |
| Spoken output (platform TTS + neural `/v1/speak`) | yes | yes | yes | TTS yes (device); neural no | yes | partial |
| Custom board tiles with AI pictures | yes | yes | yes | no (uses `/v1/image`; same live gate) | yes (WordsEditor + board) | no |
| Word explanations (lookup → Understand) | yes | yes | yes | same gate as reasoning | yes (WordBuilder) | no |
| Wonder long-form routing | yes | yes | yes | no - needs key + save plan/story route | yes (Plans/Stories route rows) | no |
| Glimmer local | manual path only | n/a | via Custom endpoint | operator-dependent (judge preflights Ollama, never kills rule checks) | via Custom endpoint | n/a |
| Tools / web grounding | declined | n/a | n/a | n/a | n/a | n/a |

Live gates, in order: (1) redeploy staging with this code; (2) `python
gateway/scripts/live_probe.py --photo pic.jpg` from any machine; (3)
`MODEL_API_KEY=... python gateway/scripts/probe_sam.py pic.jpg --concept
<object>` if the segment step fails (isolates Meta API vs gateway); (4)
install the CI-built APK and walk the phone checklist (`docs/PHONE_CHECKLIST.md`).
Stages 1–3 + 5–7 of the Meta capability plan are implemented; Stage 4 (keyed
verification) is scripted above and awaits credentials + a staging deploy.
