"""Incremental parsers: Spark's JSON (or the fallback line protocol) -> (kind, key, value) tuples as soon as each piece completes."""
import json
from .contract import STREAM_ARRAYS


class JsonStream:
    """Feed arbitrary chunks of ONE top-level JSON object. Yields ('field',k,v) | ('item',k,(i,v)) | ('end',None,None)."""
    def __init__(self):
        self.buf, self.pos, self.state, self.key, self.idx = "", 0, "start", None, 0
        self.dec = json.JSONDecoder()

    def feed(self, chunk: str) -> list:
        self.buf += chunk
        out = []
        while (r := self._step()) is not None:
            if r != "cont":
                out.append(r)
        return out

    def _step(self):
        b = self.buf
        if self.state == "done":
            # tolerate a preamble pseudo-object: keep scanning for the real turn object
            self.state = "start"
        while self.pos < len(b) and b[self.pos] in " \n\r\t,":
            self.pos += 1
        if self.pos >= len(b):
            return None
        c = b[self.pos]
        if self.state == "start":
            if c != "{":
                self.pos += 1
                return "cont"
            j = self.pos + 1  # latch only on { opening a JSON object (brace + quoted key),
            while j < len(b) and b[j] in " \n\r\t":  # so stray braces in thinking traces don't poison the parse
                j += 1
            if j >= len(b):
                return None  # undecided at buffer end: wait for more
            self.pos += 1
            if b[j] == '"':
                self.state = "key"
            return "cont"
        if self.state == "key":
            if c == "}":
                self.pos += 1
                self.state = "done"
                return ("end", None, None)
            if c != '"':
                self.pos += 1
                return "cont"
            try:
                k, end = self.dec.raw_decode(b, self.pos)
            except json.JSONDecodeError:
                return None
            self.key, self.pos, self.state = k, end, "colon"
            return "cont"
        if self.state == "colon":
            self.pos += 1
            if c == ":":
                self.state = "value"
            return "cont"
        if self.state == "value":
            if c == "[" and self.key in STREAM_ARRAYS:
                self.pos += 1
                self.state, self.idx = "array", 0
                return "cont"
            try:
                v, end = self.dec.raw_decode(b, self.pos)
            except json.JSONDecodeError:
                return None
            self.pos, self.state = end, "key"
            return ("field", self.key, v)
        if self.state == "array":
            if c == "]":
                self.pos += 1
                self.state = "key"
                return "cont"
            try:
                v, end = self.dec.raw_decode(b, self.pos)
            except json.JSONDecodeError:
                return None
            self.pos = end
            i, self.idx = self.idx, self.idx + 1
            return ("item", self.key, (i, v))
        return None


class LineStream:
    """Fallback protocol when streaming and strict JSON do not combine, e.g.
    RISK:none / EMO:encouraging:0.6 / GEST:lean_in / GAZE:content_span:w14 / SAY:text / UI:{json} / MEM:{json} / FOLLOW:wait"""
    def __init__(self):
        self.buf, self.n = "", {}

    def _item(self, key, v):
        i = self.n.get(key, 0)
        self.n[key] = i + 1
        return ("item", key, (i, v))

    def feed(self, chunk: str) -> list:
        self.buf += chunk
        out = []
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            r = self._line(line.strip())
            if r:
                out.append(r)
        return out

    def finish(self) -> list:
        r = self._line(self.buf.strip()) if self.buf.strip() else None
        self.buf = ""
        return [r] if r else []

    def _line(self, line: str):
        tag, _, rest = line.partition(":")
        tag = tag.upper()
        try:
            if tag == "RISK": return ("field", "risk", rest.strip().lower())
            if tag == "EMO":
                name, _, i = rest.partition(":")
                return ("field", "emotion", {"name": name.strip().lower(), "intensity": float(i or 0.6)})
            if tag == "GEST": return ("field", "gesture", rest.strip().lower())
            if tag == "GAZE":
                t, _, i = rest.partition(":")
                return ("field", "gaze", {"target": t.strip(), "id": i.strip()})
            if tag == "PACE": return ("field", "pace", rest.strip().lower())
            if tag == "SAY": return self._item("say", rest.strip())
            if tag == "UI": return self._item("ui", json.loads(rest))
            if tag == "MEM": return self._item("memory_proposals", json.loads(rest))
            if tag == "KP": return self._item("key_points", rest.strip())
            if tag == "VOCAB": return self._item("vocabulary", json.loads(rest))
            if tag == "SIMPLE": return ("field", "simple_version", rest.strip())
            if tag == "CHECK": return ("field", "check_question", json.loads(rest))
            if tag == "FOLLOW": return ("field", "followup", rest.strip().lower())
        except (ValueError, json.JSONDecodeError):
            return None
        return None
