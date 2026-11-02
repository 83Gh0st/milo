# Generative UI protocol (v1)

Milo's activity panel is **model-composed, app-rendered**. The model
decides WHAT to show and HOW to arrange it; the app decides whether the
spec is valid, what renders, and what every tap may do. Anything invalid
degrades to plain chat - the turn never breaks.

Contract source of truth: `contracts/ui_contract.json` (v1).
Enforcement: `gateway/app/ui_spec.py` (server) + `lib/genui/spec.dart`
(client). State + ops: `lib/genui/panel.dart`. Widgets:
`lib/genui/widgets.dart`. Surface: chat thread (`_ActivityPanel` in
`lib/ui/chat_screen.dart`).

## Turn lifecycle

1. The app sends `ui_context`: a flat ≤12-key scalar snapshot of the
   panel (`activity`, `last_action`, state values). Never the tree.
   The gateway injects it into the prompt as "Open activity panel".
2. The model returns `ui_spec` (a required `{}`-by-default object in the
   brain schema): either `{}` (plain chat, most turns) or a spec.
3. The gateway `Assembler` validates it (`validate_ui_spec`) and emits
   at most one `ui_spec` SSE event per turn. Invalid → no event.
4. The app re-validates client-side and applies it: a `root` rebuilds
   the panel; `ops` patch the current panel (same activity only);
   `state` merges into server state.
5. The person taps: checks/answers update locally and are reported via
   the next turn's `ui_context`. `ask` sends a turn, `speak` uses TTS,
   `open_screen` navigates the closed screen list, `next` records and
   asks Milo to continue.

Stable ids across turns preserve answers: a same-activity root rebuild
keeps local values; a new activity id resets them. Ops apply
atomically - any failure keeps the previous tree.

## Components (10), actions (6), ops (6)

Components: `text card button choices checklist progress steps list
image genimage divider`. Cards nest children (column/row/card layouts,
depth ≤ 4, ≤ 40 nodes). Images use the visual-concept allow-list only;
`genimage` carries a model-written `{prompt, alt}` and the app renders an
explicit Create button - pictures are never auto-generated, always carry
the AI-made disclosure, and always have alt text (see docs/MULTIMODAL.md).

Actions: `check answer next ask speak open_screen`, each with a fixed
shape (e.g. `open_screen` allows only known screens). Node-level
actions render as small icon buttons; buttons carry one action.

Ops: `add update replace move remove state`. `update` takes scalar
props only (strings sanitized + capped); structured changes need
`replace`. Deltas may omit `intent`/`mode`/`companion` to keep the
current values.

Display: `mode` (`chat activity celebration`), `companion` (`featured`
= Milo on stage above the panel, `docked`, `hidden` = panel not
shown), `speak` (a Listen button voicing that node's text - never
autoplay).

## Safety rules

- Never executed: specs are data; the registry maps 10 known types to
  static widgets. No code, HTML, or URLs reach the renderer (all
  strings are cleaned + capped on both ends).
- Closed action set: taps can only toggle, answer, ask, speak,
  navigate allow-listed screens, or continue. Nothing touches files,
  storage, settings, or memory except through existing app paths.
- Offline board, TTS, and accessibility never depend on the panel.
  The ledger names panel state in sends (`summarizeBody`).

## Vertical slice demo (no endpoint needed)

Drive the panel through the store (see `test/genui_test.dart`):

1. Apply the school-prep checklist root → panel appears.
2. `toggle('i1')` → snapshot carries `last_action=check:i1`.
3. Apply an update `ops` delta (remove + state step 2) → tree patches.
4. A bad spec (`teleporter` type) → ignored, panel unchanged.

End-to-end against staging: ask "help me get ready for school" and
watch for the `ui_spec` SSE event (§8.3 in `docs/MODAL.md`); plain
"why is the sky blue?" must carry `{}` (no panel).
