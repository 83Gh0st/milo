# Family BYOK (bring your own key)

Families can pay for their own AI use with their own Meta API key instead of
the deployer's. Verified against code; live-billing behaviour still needs a
keyed staging check (Stage B).

## How it works

1. A trusted adult turns on sync (Data and privacy). The sync vault becomes
   the family identity; no accounts, no email.
2. In the trusted-adult area, Family AI key: paste the Meta API key once.
   The app sends it over TLS and never stores it on the phone
   (`lib/ui/trusted_screen.dart` `ProviderKeyScreen`, `MiloApi.setProviderKey`).
3. The gateway stores one key per vault, Fernet-sealed with a KEK derived from
   `KEY_ENC_SECRET` (`gateway/app/vaultkeys.py`, table `vault_keys`).
   Status endpoints return provider + `…last4` hint only; the key is never
   returned, logged, or sent to any client.
4. When the `ai.family_key` switch is on (synced to all family devices) and
   sync is on, every inference call carries vault headers
   (`MiloApi.vaultAuth`, voice first frame) and the gateway bills that turn
   to the family key (`gateway/app/sync.py` `vault_api_key`, per-call
   `api_key` override in `gateway/app/providers/meta.py`).

## Explicit-failure rules (tested in `test_gateway.py`)

- Wrong vault credentials → 401. Valid vault without a key → 409
  `no_family_key`. Neither falls back to the deployer key.
- Family-keyed turns skip the deployer daily budget and are not metered to it;
  per-device rate limits still apply.
- A family key the provider rejects surfaces as `family_key_rejected`
  (chat/understand) instead of looking like a deployer outage.
- Removing the key, turning the switch off, turning sync off, or deleting the
  vault all stop family billing; the app falls back to the shared key or to
  the on-device pocket brain and says so.

## What this is not

- Not E2EE: the gateway must hold the key in clear to call the provider.
  Keys are encrypted at rest and isolated per vault, but a gateway compromise
  exposes them. Sync payloads stay E2EE; these are different properties.
- No OAuth/delegated inference exists for Meta or OpenAI third-party apps;
  pasted keys via the gateway are the only supported path.
- No live key validation at save time (that would spend the family's money);
  the first real turn reports a bad key honestly.

## Operations

- `KEY_ENC_SECRET` (≥32 chars, required in prod) encrypts stored keys.
  Losing it means families re-enter keys; there is no recovery.
- Production should move the KEK into a managed secret manager or KMS with
  rotation; the current single-secret derivation is documented in
  `gateway/app/vaultkeys.py` and `gateway/.env.example`.
- Supabase was evaluated for sync and deliberately not adopted: the existing
  gateway sync is sound E2EE, and Supabase would only add transport/at-rest
  encryption (not E2EE) plus a second infrastructure to secure.
