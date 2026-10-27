# Cloud sync design (end to end encrypted)

Goal: the same Milo on a person's phone and tablet, **without the server ever being able to read anything**. Sync is off by default and is a separate permission from cloud AI (both appear in the consent log and the cloud ledger).

## What syncs
Settings, support profile, memories, saved phrases, saved documents, custom board tiles. **Not synced:** keys, PIN, the sync secret, the cloud ledger and consent log (per device), explanation cache, progress counts, and any setting whose name starts with `local.`. Personal photos are not synced in this version.

## Keys
1. The first device generates a random **160-bit sync secret** (shown once as `XXXX-XXXX-…`, eight groups). High entropy means no weak-passphrase risk.
2. `root = Argon2id(secret, salt = SHA256("milo-sync-v1"), 19 MiB, 2 passes, 1 lane)` (OWASP minimum; runs in an isolate).
3. HKDF-SHA256 splits `root` into four independent 256-bit values: `vault-id` (first 128 bits), `auth`, `enc`, `record-id`.
4. A new device types the same secret and derives the same four values. **The server never sees the secret or `enc`.**

## Records
* `record_id = HMAC-SHA256(record-id key, "table:pk")`: opaque, so the server learns neither table names nor row ids.
* Payload `{"t":table,"k":pk,"row":{…}}` (or `{"del":true}` for deletions) is encrypted with **AES-256-GCM**, random 96-bit nonce, `AAD = vault_id + record_id` (a ciphertext cannot be swapped between records or vaults).
* The server stores `(vault_id, record_id, seq, updated_at, deleted, nonce, ciphertext)`.

## Protocol (`/v1/sync/*`, all need the device bearer token plus `X-Vault-Id` and `X-Vault-Key`)
| Call | Purpose |
|---|---|
| `POST /vault` | create the vault; stores only `SHA256(auth)` |
| `POST /records` | push up to 200 records; **last write wins by the client's `updated_at`**; returns accepted `seq`s and conflicts |
| `GET /changes?since=<seq>` | pull everything newer than the cursor (paged) |
| `DELETE /vault` | erase the vault immediately (right to erasure) |
Quotas: 256 KB per record, 20,000 records and 50 MB per vault. Unknown vault and wrong key return the same 401.

## Client behaviour
Every local write that touches a synced table adds an **outbox** row. Sync runs on enable, on app resume and every 3 minutes while the app is open: push the outbox, then pull from the saved cursor, applying only records newer than the local copy. Remote rows are filtered through a **column whitelist** before touching SQLite. Undecryptable or malformed records are skipped, never fatal. Forgetting a memory writes a tombstone so other devices forget it too.

## Threat model
* Server or database compromise: attacker gets ciphertext, opaque ids and timestamps only.
* Network attacker: TLS, plus AEAD integrity.
* Lost secret: the cloud copy cannot be opened (by design). Local data on each device is unaffected.
* Residual metadata: record count, sizes and write times are visible to the server.
