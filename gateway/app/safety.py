"""Server-side safety (defence in depth; the app has its own local pre-filter that runs first)."""
import re
from .contract import (ALL_MEM_KEYS, CONCEPTS, EMOTIONS, FOLLOWUPS, GAZE, GESTURES, MEM_SOURCES, RISKS, SCREENS)

# English + Hindi + Malayalam starter patterns. HAVE A FLUENT SPEAKER REVIEW THESE before real users (docs/LAUNCH_CHECKLIST.md).
CRISIS = re.compile(
    r"(hurt myself|kill myself|want to die|wanna die|end my life|suicid|self[- ]?harm|cut myself|hurting me|abus(e|ing) me|touch(es|ed|ing) me|(told|telling) me to keep (it|this|that) (a )?secret|hit(s|ting)? me|(don'?t|do not) want to be here|want to disappear|no reason to live|better off without me|nobody would miss me|wish i (was|were) dead)"
    r"|आत्महत्या|मरना चाहता|मरना चाहती|खुद को नुकसान"
    r"|ആത്മഹത്യ|മരിക്കണം|മരിക്കാൻ", re.I)
_URL = re.compile(r"(https?://\S+|www\.\S+|\b[\w.+-]+@[\w-]+\.[\w.]+\b|\+?\d[\d\s\-]{6,}\d)")
_BANNED = re.compile(
    r"\b(sex|sexy|naked|kiss me|i love you|boyfriend|girlfriend)\b|(don'?t|do not|never) tell (your |the )?(mom|dad|mum|parents?|teacher|anyone)|"
    r"keep (this|it) (a )?secret|\bdiagnos|you (have|are suffering from) (adhd|autism|dyslexia|depression|anxiety)", re.I)
MEM_CUE = re.compile(r"\b(remember|call me|my name is|i (like|prefer|need|want you to)|please (use|always|speak|read))\b", re.I)
CAPS = {"playful": 10, "friendly": 14, "discreet": 20}  # max words per sentence


def is_crisis(text: str) -> bool:
    return bool(CRISIS.search(text.replace("’", "'")))


def clean(text, limit: int = 300) -> str:
    return re.sub(r"\s+", " ", _URL.sub("", str(text))).strip()[:limit]


def cap_sentence(s: str, cap: int) -> tuple[str, bool]:
    w = s.split()
    if len(w) <= cap:
        return s, False
    head = " ".join(w[:cap])
    if "," in head:
        head = head[: head.rfind(",")]
    return head.rstrip(",;:") + ".", True


_FEEL = {"happy", "sad", "angry", "love", "hate", "scared", "sorry", "worried", "excited"}
_CONSENT = {"agree", "agrees", "consent", "promise", "allow", "yes"}


def no_new_content(strip: list[str], cand: str) -> bool:
    """Heuristic guard: wording help may rephrase but not add facts, names, numbers, feelings or consent."""
    src = {w.lower().strip(".,!?") for s in strip for w in s.split()}
    words = [w.strip(".,!?") for w in cand.split()]
    if any(any(ch.isdigit() for ch in w) and w not in src for w in words):
        return False
    if any(w[:1].isupper() and i > 0 and w.lower() not in src for i, w in enumerate(words)):
        return False
    low = {w.lower() for w in words}
    return not ((low & _FEEL) - src) and not ((low & _CONSENT) - src)


class Assembler:
    """Turns parsed (kind, key, value) tuples into validated SSE events. Nothing unvalidated leaves the gateway."""
    BODY = ("emotion", "gesture", "gaze", "pace")

    def __init__(self, presentation: str = "friendly", user_text: str = ""):
        self.user_text = user_text
        self.cap = CAPS.get(presentation, 14)
        self.ceil = {"playful": 1.0, "friendly": 0.8, "discreet": 0.5}.get(presentation, 0.8)
        self.body: dict = {}
        self.sent_body = False
        self.n = {"say": 0, "mem": 0, "kp": 0, "vocab": 0}
        self.followup, self.halted, self.blocked, self.capped = "none", False, 0, 0

    def _flush(self):
        if self.sent_body:
            return []
        self.sent_body = True
        return [("body", self.body)]

    def handle(self, kind: str, key: str, val) -> list:
        if self.halted:
            return []
        out: list = []
        if key not in self.BODY and key != "risk" and not self.sent_body and kind != "end":
            out += self._flush()
        if kind == "field":
            if key == "risk":
                lvl = val if val in RISKS else "none"
                out.append(("risk", {"level": lvl}))
                self.halted = lvl != "none"
            elif key == "emotion" and isinstance(val, dict):
                name = val.get("name") if val.get("name") in EMOTIONS else "calm"
                try:
                    i = float(val.get("intensity", 0.6))
                except (TypeError, ValueError):
                    i = 0.6
                self.body["emotion"] = {"name": name, "intensity": round(max(0.0, min(i, self.ceil)), 2)}
            elif key == "gesture":
                if val in GESTURES:
                    self.body["gesture"] = val
            elif key == "gaze" and isinstance(val, dict):
                t, i = val.get("target"), str(val.get("id", ""))
                if t in GAZE and re.fullmatch(r"(w\d{1,4})?", i):
                    self.body["gaze"] = {"target": t, "id": i}
                if not self.sent_body:
                    out += self._flush()
            elif key == "pace" and val in ("normal", "slow"):
                self.body["pace"] = val
            elif key == "followup":
                self.followup = val if val in FOLLOWUPS else "none"
            elif key == "simple_version":
                out.append(("simple", {"text": clean(val, 1500)}))
            elif key == "check_question" and isinstance(val, dict) and isinstance(val.get("options"), list) and val["options"]:
                opts = [clean(o, 120) for o in val["options"][:3]]
                ai = val.get("answer_index")
                out.append(("check", {"q": clean(val.get("q", ""), 200), "options": opts, "answer_index": ai if isinstance(ai, int) and 0 <= ai < len(opts) else 0}))
        elif kind == "item":
            i, v = val
            if key == "say" and isinstance(v, str) and self.n["say"] < 4:
                s = clean(v)
                if not s:
                    return out
                if _BANNED.search(s):
                    self.blocked += 1
                    return out
                s, c = cap_sentence(s, self.cap)
                self.capped += c
                out.append(("say", {"i": self.n["say"], "text": s}))
                self.n["say"] += 1
            elif key == "ui" and isinstance(v, dict):
                a = v.get("action")
                if a == "offer_choices" and isinstance(v.get("choices"), list):
                    ch = [clean(c, 40) for c in v["choices"][:3] if clean(c, 40)]
                    if ch:
                        out.append(("ui", {"action": a, "choices": ch}))
                elif a == "open_screen" and v.get("screen") in SCREENS:
                    out.append(("ui", {"action": a, "screen": v["screen"]}))
                elif a == "highlight" and re.fullmatch(r"w\d{1,4}", str(v.get("span", ""))):
                    out.append(("ui", {"action": a, "span": v["span"]}))
                elif a == "set_timer" and isinstance(v.get("seconds"), int) and 5 <= v["seconds"] <= 3600:
                    out.append(("ui", {"action": a, "seconds": v["seconds"]}))
                elif a == "show_image" and isinstance(v.get("concept"), str) and v["concept"].strip().lower() in CONCEPTS:
                    out.append(("ui", {"action": a, "concept": v["concept"].strip().lower()}))
                elif a == "read_aloud" and re.fullmatch(r"w\d{1,4}", str(v.get("span", ""))):
                    out.append(("ui", {"action": a, "span": v["span"]}))
                elif a == "break_into_steps" and isinstance(v.get("steps"), list):
                    steps = [s for s in (clean(s, 140) for s in v["steps"] if isinstance(s, str)) if s][:8]
                    if steps:
                        out.append(("ui", {"action": a, "steps": steps}))
                elif a == "lookup_word" and re.fullmatch(r"[A-Za-z][A-Za-z'’-]{0,39}", str(v.get("word", "")).strip()):
                    out.append(("ui", {"action": a, "word": str(v["word"]).strip()}))
            elif key == "memory_proposals" and isinstance(v, dict) and self.n["mem"] < 3:
                # Proposals only, and only for things the person said or confirmed. Inferred facts are rejected.
                if MEM_CUE.search(self.user_text) and v.get("source") in MEM_SOURCES and v.get("key") in ALL_MEM_KEYS and v.get("type") in ("preference", "approved_fact") and clean(v.get("value", ""), 80):
                    out.append(("memory", {"type": v["type"], "key": v["key"], "value": clean(v["value"], 80), "source": v["source"]}))
                    self.n["mem"] += 1
            elif key == "key_points" and isinstance(v, str) and self.n["kp"] < 6 and clean(v, 220):
                out.append(("key_point", {"i": self.n["kp"], "text": clean(v, 220)}))
                self.n["kp"] += 1
            elif key == "vocabulary" and isinstance(v, dict) and self.n["vocab"] < 5 and clean(v.get("word", ""), 30):
                out.append(("vocab", {"word": clean(v["word"], 30), "meaning": clean(v.get("meaning", ""), 120)}))
                self.n["vocab"] += 1
        return out

    def finish(self) -> list:
        return [] if self.sent_body or self.halted else self._flush()
