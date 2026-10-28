"""Single source of truth for the brain-to-body contract: contracts/brain_contract.json."""
import json, os
from pathlib import Path

_p = Path(os.environ.get("CONTRACT_PATH") or Path(__file__).resolve().parents[2] / "contracts" / "brain_contract.json")
C = json.loads(_p.read_text())
EMOTIONS, GESTURES, SCREENS, RISKS = C["emotions"], C["gestures"], C["screens"], C["risks"]
UI_ACTIONS, GAZE, FOLLOWUPS = C["ui_actions"], C["gaze_targets"], C["followups"]
MEM_SOURCES, MEM_KEYS, CONCEPTS = C["memory_sources"], C["memory_keys"], set(C["visual_concepts"])
ALL_MEM_KEYS = {k for v in MEM_KEYS.values() for k in v}

def brain_schema(understand: bool = False) -> dict:
    props = {
        "risk": {"type": "string", "enum": RISKS},
        "emotion": {"type": "object", "properties": {"name": {"type": "string", "enum": EMOTIONS}, "intensity": {"type": "number"}}, "required": ["name", "intensity"]},
        "gesture": {"type": "string", "enum": GESTURES + ["none"]},
        "gaze": {"type": "object", "properties": {"target": {"type": "string", "enum": GAZE}, "id": {"type": "string"}}, "required": ["target"]},
        "say": {"type": "array", "items": {"type": "string"}},
        "pace": {"type": "string", "enum": ["normal", "slow"]},
        "ui": {"type": "array", "items": {"type": "object", "properties": {"action": {"type": "string", "enum": UI_ACTIONS}, "span": {"type": "string"}, "screen": {"type": "string"}, "choices": {"type": "array", "items": {"type": "string"}}, "seconds": {"type": "integer"}, "concept": {"type": "string"}, "steps": {"type": "array", "items": {"type": "string"}}, "word": {"type": "string"}}, "required": ["action"]}},
        "memory_proposals": {"type": "array", "items": {"type": "object", "properties": {"type": {"type": "string"}, "key": {"type": "string"}, "value": {"type": "string"}, "source": {"type": "string"}}, "required": ["type", "key", "value", "source"]}},
        "followup": {"type": "string", "enum": FOLLOWUPS},
    }
    if understand:
        props.update({
            "key_points": {"type": "array", "items": {"type": "string"}},
            "simple_version": {"type": "string"},
            "vocabulary": {"type": "array", "items": {"type": "object", "properties": {"word": {"type": "string"}, "meaning": {"type": "string"}}, "required": ["word", "meaning"]}},
            "check_question": {"type": "object", "properties": {"q": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}, "answer_index": {"type": "integer"}}, "required": ["q", "options", "answer_index"]},
        })
    return {"type": "object", "properties": props, "required": list(props)[:9]}

STREAM_ARRAYS = {"say", "ui", "memory_proposals", "key_points", "vocabulary"}
FIELD_ORDER = ["risk", "emotion", "gesture", "gaze", "say", "pace", "ui", "memory_proposals", "followup"]
