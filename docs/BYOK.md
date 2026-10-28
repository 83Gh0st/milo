# Family BYOK (bring your own key)

Families can pay for their own AI use with their own provider API keys
(Meta, OpenAI, Anthropic, or a custom/local endpoint) instead of the
deployer's. Verified against code; live-billing behaviour still needs a
keyed staging check (Stage B).

## How it works

1. A trusted adult turns on sync (Data and privacy). The sync vault becomes
   the family identity; no accounts, no email.
2. In the trusted-adult area, AI connections: pick a provider, paste its API
   key once, pick a model, test it. The app sends the key over TLS and never
   stores it on the phone (`lib/ui/trusted_screen.dart` `ProviderKeyScreen`,
   `MiloApi.saveConnection`). A ChatGPT/Claude/Meta *app* login is not API
   access; the family needs a real API key, billed to its own account.
3. The gateway stores one key per (vault, provider), Fernet-sealed with a KEK
   derived from `KEY_ENC_SECRET` (`gateway/app/vaultkeys.py`, table
   `vault_connections`; pre-Phase-3 `vault_keys` rows migrate lazily without
   data loss). List endpoints return provider + `…last4` hint only; keys are
   never returned, logged, or sent to any client.
4. Per capability (thinking, reading help, pictures, voice in) the family
   picks a first choice and a fallback (`PUT /v1/connections/routes`); the
   server fails over on timeout/429/5xx/unreachable only, never on auth or
   content-filter errors, and never silently changes provider.
5. When the `ai.family_key` switch is on and sync is on, every inference
   call carries vault headers (`MiloApi.vaultAuth`, voice first frame) and
   the gateway serves that turn from the family's routes
   (`gateway/app/sync.py` `VaultCtx`, `gateway/app/routing.py`).
6. Providers whose data terms are unreviewed require an explicit
   trusted-adult acknowledgement at connect time (409 `policy_ack_required`
   until then); the policy note is shown in the app
   (`gateway/app/datapolicy.py`). All live providers are currently
   `unknown` — a human must re-check the official terms before release.

## Explicit-failure rules (tested in `test_gateway.py`)

- Wrong vault credentials → 401. Valid vault without a key → 409
  `no_family_key`. Neither falls back to the deployer key.
- Family-keyed turns skip the deployer daily budget and are not metered to it;
  per-device rate limits still apply.
- A family key the provider rejects surfaces as `family_key_rejected` (Meta
  path) or `auth_failed` (registry adapters) instead of looking like a
  deployer outage; auth errors never fail over to another provider silently.
- A model whose probe failed a needed capability (e.g. pictures on a
  text-only model) is skipped before any network I/O and surfaces as
  `unsupported_capability` — Milo says what it cannot do instead of trying.
- Removing the key, turning the switch off, turning sync off, or deleting the
  vault all stop family billing; the app falls back to the shared key or to
  the on-device pocket brain and says so.

## What this is not

- Not E2EE: the gateway must hold the key in clear to call the provider.
  Keys are encrypted at rest and isolated per vault, but a gateway compromise
  exposes them. Sync payloads stay E2EE; these are different properties.
- No OAuth/delegated inference exists for Meta or OpenAI third-party apps;
  pasted keys via the gateway are the only supported path.
- Save-time validation is opt-in (Test connection) so it never spends the
  family's money unasked; the first real turn reports a bad key honestly.

## Operations

- `KEY_ENC_SECRET` (≥32 chars, required in prod) encrypts stored keys.
  Losing it means families re-enter keys; there is no recovery.
- Production should move the KEK into a managed secret manager or KMS with
  rotation; the current single-secret derivation is documented in
  `gateway/app/vaultkeys.py` and `gateway/.env.example`.
- Supabase was evaluated for sync and deliberately not adopted: the existing
  gateway sync is sound E2EE, and Supabase would only add transport/at-rest
  encryption (not E2EE) plus a second infrastructure to secure.
