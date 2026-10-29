# Milo Companion

A living, multimodal AI companion for people with learning difficulties or who need other ways to communicate. Flutter (iOS + Android) + FastAPI gateway + Meta Muse models.

| Folder | What |
|---|---|
| `lib/` | Flutter app: character engine (`companion/`), local encrypted data (`data/`), Core router, memory, safety (`core/`), API + voice (`net/`), E2EE sync (`sync/`), screens (`ui/`) |
| `gateway/` | FastAPI gateway: Meta adapters, streaming brain, safety, budget guard, E2EE sync store, tests |
| `contracts/` | `brain_contract.json`: the single source of truth for the brain-to-body contract (a test keeps the Dart copy in step) |
| `deploy/` | Docker Compose (Caddy + gateway + PostgreSQL) |
| `eval/` | AI evaluation harness (plan section 11.3) |
| `docs/` | `SETUP.md`, `DEPLOYMENT.md`, `SYNC_DESIGN.md`, `LAUNCH_CHECKLIST.md`, `DESIGN_MAP.md` (wireframe to code), `RELEASE.md` (Android + iOS builds, signing, TestFlight), `VOICE_CHECKLIST.md` (speech lifecycle + device checks), `MODAL.md` (serverless hosting + costs) |
| `assets/`, `tools/` | bundled fonts, generated app icon and splash, and the script that draws them |

Start with **docs/SETUP.md**. Honest status and remaining gaps are in **docs/LAUNCH_CHECKLIST.md**.

## How the pieces fit
1. The person talks or types. The **Core router** tries, in order: local safety pre-filter, memory commands, local intents, cloud brain, pocket brain.
2. A cloud turn is written to the **cloud ledger first**, built from exactly the visible context chips, then streamed from the gateway as server-sent events: `risk`, `body` (Milo reacts), `say` (sentences spoken as they arrive), `ui`, `memory` (a proposal only), `done`.
3. The gateway holds the Meta key, builds the cached five-layer prompt, parses Spark's JSON while it streams, and **validates every field** against closed lists before anything reaches the phone. The model proposes; the app disposes.
4. Everything the person owns lives in an encrypted SQLite database on the phone. Optional sync copies only end-to-end encrypted blobs through the gateway.
