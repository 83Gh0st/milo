#!/usr/bin/env python3
"""Milo voice bake-off (Phase 4A): synthesize the 12 fixed Milo lines through
each enabled engine, blind-name the WAVs, and emit RESULTS.md + scores.csv.

Honest by construction:
- No engine runs without its key/model present AND its current terms recorded
  (terms_url + terms_date in engines.json). Anything else is listed as
  SKIPPED with the reason — never synthesized, never scored.
- No prices, terms, or API shapes are asserted here. The OpenAI/Piper request
  shapes below are first hypotheses, flagged UNVERIFIED until a run with a
  real key/model succeeds; azure/google/elevenlabs are unimplemented stubs
  awaiting a verified API shape.
- Keys come only from the environment, never from engines.json or argv.

Usage (Windows cmd):
  cd eval\\voice_bakeoff
  python run.py --list                  # engines + availability, no synthesis
  python run.py --dry-run               # validate lines, write scores.csv skeleton
  copy engines.json my-engines.json     # enable engines, record terms
  python run.py --config my-engines.json
"""
import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import wave

HERE = os.path.dirname(os.path.abspath(__file__))

# The 12 fixed Milo lines. en + hi + ml; styles cover the whole product.
LINES = [
    ("01_greeting", "en", "Hi! I'm Milo. Want to read something tricky together?", "warm greeting"),
    ("02_encourage", "en", "You did it! That was a hard one, and you kept going.", "encouragement"),
    ("03_hint", "en", "Look at the first sound. Buh… buh… what word starts like that?", "playful hint"),
    ("04_correct", "en", "Almost! Let's try that word once more, slowly.", "gentle correction"),
    ("05_breathe", "en", "Breathe with me. In… and out. Good. Let's slow down.", "calm breathing"),
    ("06_celebrate", "en", "Wow, you finished the whole page! I'm doing a happy wiggle!", "excited celebration"),
    ("07_question", "en", "What do you think happens next in the story?", "curious question"),
    ("08_explain", "en", "A paragraph is a group of sentences about one idea. When the idea changes, we start a new line.", "long explanation"),
    ("09_numbers", "en", "On Tuesday the 3rd of March, at half past 4, we read 12 pages!", "numbers and dates"),
    ("10_hindi", "hi", "बहुत बढ़िया! तुमने बहुत अच्छा पढ़ा।", "hindi encouragement"),
    ("11_malayalam", "ml", "നന്നായി! നമുക്ക് ഒന്നുകൂടി വായിക്കാം.", "malayalam encouragement"),
    ("12_bedtime", "en", "Time to rest now. Sleep tight, little reader.", "very quiet bedtime"),
]


class Engine:
    id = "?"
    display = "?"
    key_env = None  # env var holding the key, if hosted

    def available(self):
        """Returns (ok, reason). No network, no key reads beyond presence."""
        raise NotImplementedError

    def synthesize(self, text, lang, voice, wav_path):
        """Writes wav_path. Returns dict(first_audio_ms, total_ms, bytes,
        format, voice, stream). first_audio_ms == total_ms when the engine
        only returns whole files (flagged stream=False)."""
        raise NotImplementedError


class OpenAIEngine(Engine):
    id = "openai"
    display = "OpenAI TTS"
    key_env = "OPENAI_API_KEY"

    def available(self):
        if not os.environ.get("OPENAI_API_KEY"):
            return False, "OPENAI_API_KEY not set"
        return True, "UNVERIFIED request shape until first success"

    def synthesize(self, text, lang, voice, wav_path):
        # UNVERIFIED hypothesis (no network 28 Oct 2026): if the first keyed
        # run fails, fix the shape here and record the docs URL + date.
        body = json.dumps({"model": "gpt-4o-mini-tts",
                           "input": text, "voice": voice or "alloy",
                           "response_format": "wav"}).encode()
        req = urllib.request.Request("https://api.openai.com/v1/audio/speech",
                                     data=body, headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"],
                                                           "Content-Type": "application/json"})
        t0 = time.monotonic()
        with urllib.request.urlopen(req, timeout=60) as r:
            blob = r.read()
        ms = int((time.monotonic() - t0) * 1000)
        with open(wav_path, "wb") as f:
            f.write(blob)
        return {"first_audio_ms": ms, "total_ms": ms, "bytes": len(blob),
                "format": "wav?", "voice": voice or "alloy", "stream": False}


class PiperEngine(Engine):
    id = "piper"
    display = "Piper (local, open source)"
    # NOTE: each Piper voice model carries its own licence — record the
    # voice file's licence in engines.json ("voice_licence") before scoring.

    def available(self):
        if shutil.which("piper") is None:
            return False, "'piper' binary not on PATH"
        v = os.environ.get("PIPER_VOICE", "")
        if not v or not os.path.exists(v):
            return False, "PIPER_VOICE model file not set/found"
        return True, "local, no key, no network"

    def synthesize(self, text, lang, voice, wav_path):
        t0 = time.monotonic()
        p = subprocess.run(["piper", "--model", os.environ["PIPER_VOICE"],
                            "--output_file", wav_path],
                           input=text.encode(), capture_output=True, timeout=120)
        ms = int((time.monotonic() - t0) * 1000)
        if p.returncode != 0 or not os.path.exists(wav_path):
            raise RuntimeError("piper failed: " + p.stderr.decode()[-300:])
        return {"first_audio_ms": ms, "total_ms": ms,
                "bytes": os.path.getsize(wav_path), "format": "wav",
                "voice": os.path.basename(os.environ["PIPER_VOICE"]), "stream": False}


class _StubEngine(Engine):
    """A named candidate with no verified API shape. Implement synthesize()
    from the vendor's current docs, record terms_url + terms_date, then run."""

    def __init__(self, id, display, key_env):
        self.id, self.display, self.key_env = id, display, key_env

    def available(self):
        return False, "adapter not implemented (needs a verified API shape)"

    def synthesize(self, text, lang, voice, wav_path):
        raise RuntimeError("not implemented")


ENGINES = [OpenAIEngine(), PiperEngine(),
           _StubEngine("azure", "Azure Neural TTS", "AZURE_SPEECH_KEY"),
           _StubEngine("google", "Google Cloud TTS", "GOOGLE_APPLICATION_CREDENTIALS"),
           _StubEngine("elevenlabs", "ElevenLabs", "ELEVENLABS_API_KEY")]


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg.get("engines"), dict):
        raise ValueError("config needs an 'engines' object")
    return cfg


def wav_seconds(path):
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / (w.getframerate() or 1)
    except Exception:
        return -1.0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Milo voice bake-off")
    ap.add_argument("--config", default=os.path.join(HERE, "engines.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--list", action="store_true", help="availability only")
    ap.add_argument("--dry-run", action="store_true", help="validate + score sheet, no synthesis")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    rows = []
    for e in ENGINES:
        want = cfg["engines"].get(e.id, {})
        ok, reason = e.available()
        terms_ok = bool(want.get("terms_url")) and want.get("terms_date") not in (None, "", "UNVERIFIED")
        enabled = bool(want.get("enabled")) and ok and terms_ok
        status = "READY" if enabled else "SKIPPED"
        why = "ready" if enabled else "; ".join(
            [r for r in ["" if want.get("enabled") else "not enabled",
                         "" if ok else reason,
                         "" if terms_ok else "terms not recorded (terms_url + terms_date)"] if r])
        rows.append((e, want, enabled, status, why))

    if args.list:
        print(f"{'engine':<12}{'status':<9}reason")
        for e, _, _, status, why in rows:
            print(f"{e.id:<12}{status:<9}{why}")
        return 0

    os.makedirs(args.out, exist_ok=True)
    letters, stats = {}, []
    for i, (e, want, enabled, _, _) in enumerate([r for r in rows if r[2] or args.dry_run and r[1].get("enabled")]):
        letters[e.id] = chr(ord("A") + i)
    if args.dry_run:
        letters = {e.id: chr(ord("A") + i) for i, e in enumerate(ENGINES)}
    with open(os.path.join(args.out, "scores.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["line_id", "engine_letter", "naturalness_1_5", "warmth_1_5", "clarity_1_5", "notes"])
        for lid, _, _, _ in LINES:
            for letter in sorted(set(letters.values())) or ["A"]:
                w.writerow([lid, letter, "", "", "", ""])
    if args.dry_run:
        print(f"dry run ok: {len(LINES)} lines, score sheet at out/scores.csv")
        return 0
    ready = [(e, want) for e, want, enabled, _, _ in rows if enabled]
    if not ready:
        print("no engines ready (see --list); nothing synthesized.")
        return 2
    with open(os.path.join(args.out, "key.json"), "w") as f:
        json.dump({"note": "open AFTER blind scoring", "letters": letters}, f, indent=1)
    for e, want in ready:
        letter, voice = letters[e.id], want.get("voice", "")
        for lid, lang, text, style in LINES:
            if lang != "en" and lang not in want.get("langs", ["en"]):
                stats.append((letter, lid, "skipped", "engine not configured for " + lang, 0, 0, 0))
                continue
            path = os.path.join(args.out, f"{letter}_{lid}.wav")
            try:
                m = e.synthesize(text, lang, voice, path)
                dur = wav_seconds(path)
                rtf = (m["total_ms"] / 1000 / dur) if dur > 0 else -1
                stats.append((letter, lid, "ok", m["voice"], m["first_audio_ms"], m["total_ms"],
                              round(rtf, 2) if rtf >= 0 else "n/a"))
            except Exception as ex:
                stats.append((letter, lid, "ERROR", str(ex)[:120], 0, 0, 0))
            print(f"{letter}_{lid}: {stats[-1][2]}")
    with open(os.path.join(args.out, "RESULTS.md"), "w") as f:
        f.write("# Voice bake-off results\n\nBlind letters: see `key.json` AFTER scoring.\n\n")
        f.write("| letter | engine | voice | terms (URL, date) | price/1k chars | streaming | word timings |\n|---|---|---|---|---|---|---|\n")
        for e, want in ready:
            f.write(f"| {letters[e.id]} | {e.display} | {want.get('voice', '')} | {want.get('terms_url', '')} ({want.get('terms_date', '')}) | {want.get('price_per_1k_chars', 'TBD')} | {want.get('streaming', 'TBD')} | {want.get('word_timings', 'TBD')} |\n")
        f.write("\n| file | result | detail | first_audio_ms | total_ms | RTF |\n|---|---|---|---|---|---|\n")
        for letter, lid, res, detail, fa, tot, rtf in stats:
            f.write(f"| {letter}_{lid}.wav | {res} | {detail} | {fa} | {tot} | {rtf} |\n")
        f.write("\nFill `scores.csv` by blind listening, then open `key.json`.\n")
    print(f"done: {len(stats)} files attempted, results in {args.out}/RESULTS.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
