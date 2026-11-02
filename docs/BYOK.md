# Family BYOK (bring your own key)

Families can pay for their own AI use with their own provider API keys
(Meta, OpenAI, Anthropic, or a custom/local endpoint) instead of the
deployer's. Key handling is verified against code and the vendor endpoint
shapes were probed live on 2026-10-29; full keyed inference still needs
the in-app Test connection or a keyed staging check.

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
   (`gateway/app/datapolicy.py`). OpenAI/Anthropic terms were verified from
   the vendors' own pages on 2026-10-29 (no training on API data); Meta's
   standard-model retention is still unverified, so Meta still needs the
   acknowledgement. Re-check terms before every release.
7. A saved key is never shown as working: only a passed Test connection
   stamps `tested_at`, and the app shows `Tested <date>` vs `Saved - not
   tested yet`. A family that saved keys but never saved routes still gets
   working turns: the server synthesises defaults from the family's own
   providers (never the deployer's) - see `sync.py` `vault_ctx_for`.

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
  `unsupported_capability` - Milo says what it cannot do instead of trying.
- Removing the key, turning the switch off, turning sync off, or deleting the
  vault all stop family billing; the app falls back to the shared key or to
  the on-device pocket brain and says so.

## Trust boundary (deliberate design decision)

Family turns are routed **through the gateway**, not direct
client-to-provider - evaluated against direct calls and chosen because:

- Safety validation, the brain contract, crisis handling, streaming,
  cancellations, and error mapping are implemented once, server-side, and
  apply identically to every provider. Direct calls would duplicate all of
  that in the app and drift.
- Keys never touch the phone at all (not even platform secure storage):
  pasted once in the app, sent over TLS, sealed server-side, never
  returned, logged, or placed in analytics/crash reports. The key field
  disables suggestions/autocorrect so keyboards never learn it.
- One network path (app → gateway) works behind any family network; direct
  calls would need per-vendor firewall/proxy behaviour per device.

What this means honestly:

- Not E2EE: the gateway must hold the key in clear to call the provider.
  Keys are encrypted at rest and isolated per vault, but a gateway compromise
  exposes them. Sync payloads stay E2EE; these are different properties.
- No OAuth/delegated inference exists for Meta or OpenAI third-party apps;
  pasted keys via the gateway are the only supported path.
- Save-time validation is opt-in (Test connection) so it never spends the
  family's money unasked; the first real turn reports a bad key honestly.
- Hard invariant, tested: family requests can ONLY use family credentials
  (`test_hosted_async.py`). Deployer keys (vendor suite or hosted GPU) are
  unreachable from family requests, and family turns are never metered to
  the deployer budget. There is no silent deployer fallback anywhere.

## What this is not

- Not E2EE (see above).
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
