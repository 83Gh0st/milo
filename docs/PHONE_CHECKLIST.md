# Milo on-phone verification checklist

For weeks when CI is unavailable (or any release): install the APK from
`docs/RELEASE.md` (local build) and walk this list on a real phone. It is
ordered so each section builds on the last. Anything marked **must** is a
ship-blocker; **should** is polish.

Record at the top of your run: phone model, Android version, screen size,
APK version (`More` → `Milo Companion 1.0.0` line), online vs offline.

## 0. Install and first launch

- [ ] APK installs from file transfer (allow "install unknown apps" once).
- [ ] First launch shows onboarding, then Home. No red screen, no freeze.
- [ ] App icon is the Milo sprout (recognizable, no text needed).
- [ ] App name under the icon reads **Milo**.
- [ ] Mic/camera permission prompts appear only when first used
      (voice input, understand/chat photo), never at launch.

## A. Offline core (airplane mode ON for this whole section)

- [ ] **Must:** Home shows the character + Learn / Say / Do actions; bottom
      navigation never covers content; nothing clips at your screen size.
- [ ] **Must:** Tapping Milo says hi out loud. Mouth moves **only while
      sound plays**; silent taps never mouth (tap 10× fast: one greeting,
      no overlap, no stuck mouth).
- [ ] Express / Say board: building a strip and pressing speak reads it
      aloud promptly (<1 s to first audio).
- [ ] Character idles calmly: breathing, blinking, no constant motion.
      Background the app mid-speech: speech stops, no stuck state.
- [ ] Memory: save/recall a memory; it persists after force-stopping the
      app (all on-device, no account).
- [ ] Privacy screen: ledger shows **counts only**, never message text.

## B. Hosted online AI (airplane mode OFF)

Needs the gateway reachable (default `API_BASE` is baked in at build).

- [ ] **Must:** Chat turn streams in (risk → body → say → done), reply is
      spoken with matching mouth movement; captions match audio.
- [ ] About → Connection row reads *"Connected to Milo's server. AI
      providers are verified when Milo answers…"* — health is never
      presented as "AI works".
- [ ] Crisis wording (e.g. self-harm text) routes to the calm support
      flow immediately; the text is never sent to a model.
- [ ] With mobile data off but Wi-Fi on (or vice versa), the ladder state
      (Online / resting / offline) follows reality within seconds.
- [ ] Voice settings: each listed TTS voice previews aloud; the saved
      choice persists across restarts.

## C. Family AI keys / BYOK (needs sync ON)

`More` → Data and privacy → enable sync (write the secret down — shown
once), then AI connections.

- [ ] **Must:** Sync OFF shows the gate
      (*"Turn on sync first, in Data and privacy…"*); sync ON shows the
      four provider tiles, each starting at **Not connected**.
- [ ] Saving a key **without** ticking the data note is refused with
      *"Please confirm the data note first."* and stores nothing.
- [ ] Ticking ack + Save stores the key: tile shows `Key …<last4>`.
      The full key appears nowhere (not in the UI, not in logs).
- [ ] **Test connection** shows an honest per-check checklist (pass and
      fail both render, no crash); a passed probe stamps **Tested
      <date>**; a merely-saved key reads *Saved — not tested yet*,
      never "Connected".
- [ ] **Find** opens the models picker; picking fills the model field.
- [ ] Per-capability routes + **Save choices** persist; with no
      connection it answers *"Connect a provider first."* (no silent
      mock fallback).
- [ ] **Our family AI** switch ON routes turns through your providers
      (answers billed to your account); OFF returns to Milo hosted.
      Switching never migrates, deletes, or exposes local memory.
- [ ] **Remove this connection** disconnects (tile back to Not
      connected) and the server forgets the key.

## D. Sync and privacy

- [ ] Second enable shows the *join with secret* path; a wrong secret is
      rejected (401), a right one syncs.
- [ ] Memory pause blocks cloud writes; resume restores; local memory
      keeps working while paused.
- [ ] Deleting the vault erases cloud data (right to erasure) and the
      app keeps working locally.

## E. Character, growth, accessibility

- [ ] `More` → long-press `Milo Companion 1.0.0` (debug builds) opens
      Milo Lab: pose every expression, fire clips, flip toggles.
- [ ] Resting, listening, thinking, speaking, happy, sad, confused,
      reassuring, celebrating are distinct and calm; reduced-motion and
      quiet mode visibly calm the character further.
- [ ] Progress → **Milo is growing**: stages render; wardrobe choice
      (look A/B/C) updates Milo on Home, growth, and chat identically.
- [ ] System text size 200%: no clipped buttons, no overlapping cards,
      lists still scroll fully (check AI connections bottom).
- [ ] TalkBack smoke pass: every visible control announces and activates.

## F. Robustness and logs

- [ ] Rotate the phone on Home, chat, and AI connections: no lost
      input, no stuck sheet, no crash.
- [ ] Kill + relaunch mid-anything: launches clean, no "stuck
      listening/thinking" state.
- [ ] If anything misbehaves, capture
      `adb logcat -d | findstr /i milo flutter dart` (platform-tools)
      plus the APK version and exact steps.

## G. Known CI-only coverage (re-run when Actions return ~Nov 1)

Widget/unit suites (`flutter test`), gateway async suite (family-credential
isolation, route synthesis, budget guards), golden screenshot baselines,
release APK/AAB + iOS simulator builds. Nothing in §A–F above depends on
them, but do not cut a release without them green.
