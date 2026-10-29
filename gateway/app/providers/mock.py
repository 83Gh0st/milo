"""Deterministic offline provider for tests, CI and local development without a key."""
import asyncio, base64, json
from .base import Usage

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


class MockReasoning:
    def __init__(self, delay: float = 0.0):
        self.delay, self.calls = delay, 0

    async def stream(self, messages, *, schema=None, effort="low", max_tokens=900, api_key=None):
        self.calls += 1
        self.last_api_key = api_key  # mock ignores keys, but tests can observe which key was routed
        last = messages[-1]["content"]
        text = last if isinstance(last, str) else last[0]["text"]
        t = text.lower()
        props = (schema or {}).get("properties", {})
        if "steps" in props:
            payload = json.dumps({"steps": [{"emoji": "🪥", "text": "Brush your teeth"}, {"emoji": "👕", "text": "Put on your clothes with a very long extra sentence that goes on and on past the limit"}, {"emoji": "🎒", "text": "Pack your bag"}]})
            for i in range(0, len(payload), 11):
                yield payload[i:i + 11]
            yield Usage(300, 0, 80)
            return
        if "options" in props:
            payload = json.dumps({"options": ["Can I have water, please?", "I want water.", "Sam loves water and is sad."]})
            yield payload
            yield Usage(200, 0, 40)
            return
        understand = "key_points" in props
        lines = "OUTPUT FORMAT" in messages[0]["content"]
        risk = "crisis" if "trigger_risk" in t else "none"
        emo, gest = ("encouraging", "lean_in") if ("tricky" in t or "don't get" in t) else ("happy", "wave")
        obj = {"risk": risk, "emotion": {"name": emo, "intensity": 0.6}, "gesture": gest, "gaze": {"target": "content_span", "id": "w3"},
               "say": ["That one is tricky.", "Let us look at just this little part. Visit https://evil.example now."], "pace": "slow",
               "ui": [{"action": "offer_choices", "choices": ["Easier words", "Show a picture", "Let me try", "extra"]}, {"action": "open_screen", "screen": "launch_missiles"}],
               "memory_proposals": [{"type": "preference", "key": "explanation_style", "value": "visual", "source": "user_stated"},
                                    {"type": "approved_fact", "key": "call_name", "value": "Sam", "source": "inferred"}], "followup": "wait"}
        if understand:
            obj.update({"key_points": ["The ocean is big.", "Many animals live there."], "simple_version": "The ocean is very big. Many animals live in it.",
                        "vocabulary": [{"word": "plankton", "meaning": "tiny living things in water"}], "check_question": {"q": "What is big?", "options": ["Ocean", "Cup", "Pen"], "answer_index": 0}})
        if lines:
            L = [f"RISK:{risk}", f"EMO:{emo}:0.6", f"GEST:{gest}", "GAZE:content_span:w3", "SAY:That one is tricky.", "SAY:Let us try a small part.", "UI:" + json.dumps(obj["ui"][0]), "FOLLOW:wait"]
            payload = "\n".join(L) + "\n"
        else:
            payload = json.dumps(obj)
        for i in range(0, len(payload), 7):
            if self.delay:
                await asyncio.sleep(self.delay)
            yield payload[i:i + 7]
        yield Usage(900, 700, 120)

    async def complete_json(self, messages, schema, effort):  # used by plan/compose in tests
        raise NotImplementedError


class MockImage:
    def __init__(self):
        self.calls = 0

    async def generate(self, prompt: str, size: str = "1024x1024", api_key=None) -> bytes:
        self.calls += 1
        self.last_api_key = api_key
        return PNG


class MockGround:
    """Deterministic stand-in for SAM-style visual grounding (P2): one centred
    box labelled with the asked phrase, normalised 0..1 coordinates."""

    def __init__(self):
        self.calls = 0

    async def ground(self, image_b64: str, phrase: str, api_key=None) -> dict:
        self.calls += 1
        self.last_api_key = api_key
        return {"boxes": [{"x": 0.3, "y": 0.3, "w": 0.4, "h": 0.4, "label": phrase[:40]}], "model": "mock"}


class _S:
    def __init__(self):
        self.n = 0

    async def send(self, pcm: bytes):
        self.n += 1

    async def events(self):
        yield {"type": "partial", "text": "hello"}
        while self.n < 2:
            await asyncio.sleep(0.01)
        yield {"type": "final", "text": "hello milo"}
        await asyncio.sleep(5)

    async def close(self):
        pass


class MockVoice:
    async def open(self, language_bias=None, keywords=None, api_key=None):
        self.last_api_key = api_key
        return _S()
