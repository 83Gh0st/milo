# Milo data map (verified against code, Oct 2026)

Where each category of data lives, what leaves the phone, and what was checked.
"Verified" means traced through the cited code; runtime/device checks are marked.

## On the phone

| Store | Holds | Protection |
|---|---|---|
| SQLCipher `milo.db` (`lib/data/db.dart`) | settings, support profile, memories, board tiles, phrases, saved documents, explanation cache, progress counts, consent log, cloud ledger, sync outbox | AES-256 via SQLCipher; 256-bit key in secure storage (`SecureStore.dbKey`), never in the db |
| Secure storage (`lib/data/secure_store.dart`) | db key, install id, sync secret, PIN salt+hash | Keychain (`first_unlock_this_device`) / Keystore (encrypted prefs) |
| Memory only | chat thread (`chatProvider`), explainer pictures (`visualProvider`), mic amplitude, TTS state | Gone when the app closes; pictures re-fetched, never cached to disk |
| App cache (transient) | camera/gallery pick until read | Original (with EXIF/GPS) is deleted right after resize+OCR (`understand_screen.dart` `_photo`); only the stripped JPEG stays in memory |
| `local.*` settings keys | recent items, tasks, trusted/doctor phones, sync cursor, memory pointer, child flag | Local-only by prefix: `put()` never queues them for sync |

Never stored: raw voice audio (streamed PCM, never written), check-in answers,
photo originals, conversation transcripts, crisis text beyond the local filter.

## What leaves the phone, and why

| Destination | Payload | Gate |
|---|---|---|
| Gateway `/v1/brain/turn`, `/v1/understand`, `/v1/plan`, `/v1/compose` | message + visible chips + ≤5 approved memories + support axes; first name only if `cloud.name` | `cloud.enabled` on, `offline.forced` off, ledger entry first (`MiloApi._ledger`) |
| Gateway `/v1/visual` | one allow-listed concept word | Same gate; response PNG kept in memory only |
| Gateway `/v1/voice` (WebSocket) | live PCM16 audio + device token | Same gate; ledger notes "not kept" |
| Gateway `/v1/sync/*` | AES-256-GCM ciphertext + opaque ids + timestamps | Separate `local.sync` permission; server cannot read payloads |

Every send is built from the exact request body by the same code that sends it
(`lib/core/payload.dart` + `lib/net/api.dart`); the cloud ledger stores
summaries (lengths, labels, counts), never content. No print/debug logging,
no crash reporting, no analytics in `lib/` (searched).

## Sync (E2EE, verified design)

- Client derives vault/auth/enc/record keys from a 160-bit secret via
  Argon2id + HKDF (`lib/sync/sync_crypto.dart`); the secret never leaves the phone.
- Record ids are HMACs; payloads are AES-GCM with `vault+record` AAD
  (`seal`/`open`); records carry envelope version `v` (unknown versions skipped).
- Server (`gateway/app/sync.py`) stores ciphertext + metadata only, checks
  `SHA256(auth)` with constant-time compare, answers 401 identically for
  unknown/wrong vaults, enforces LWW + quotas, deletes whole vaults on request.
- Push clears the outbox only after the server accepts; the server batch is one
  transaction, so an interrupted upload retries cleanly.
- Remote rows pass a column whitelist (`kCols`) with `profile_id` forced local.

Known limits (by design, not defects): no per-device revocation under the
shared secret - to remove a device, turn sync off (deletes the vault), turn it
back on (new secret), and re-enrol the kept devices; a lost secret means the
cloud copy is unopenable; record counts/sizes/write times are visible to the
server. Cross-device E2EE still needs a two-client runtime check (Stage C).

## Lifecycle

- Logout: no accounts; "logout" is Delete-everything (`db.deleteEverything` +
  `store.wipe` + vault delete when sync is on).
- Reinstall: secure-storage keys are device-bound (`first_unlock_this_device`);
  a reinstall loses the db key and sync secret, so old data/cloud copies stay sealed.
- Device loss: local data is behind device lock + SQLCipher; revoke cloud
  access via the rotation procedure above from a kept device.
- Backups: excluded via `allowBackup=false` (Android) and
  `isExcludedFromBackup` (iOS) - verify on generated platforms (Stage A/C).

## Still needs a device

SQLCipher open/wipe on real Keychain/Keystore, backup exclusion flags,
EXIF-strip confirmation, TTS word-callback timing, and the two-client sync
proof. Nothing above claims runtime verification.
