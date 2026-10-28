"""Contract-level regression tests. Stdlib-only (no fastapi/pydantic) so they run
anywhere: `cd gateway && python -m pytest tests/test_contract_units.py -q`."""
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app.contract import CONCEPTS, UI_ACTIONS, brain_schema
from app.safety import Assembler
from app.streaming import JsonStream, LineStream


def _ui_events(payloads):
    a = Assembler("friendly")
    out = []
    for i, p in enumerate(payloads):
        out += [d for e, d in a.handle("item", "ui", (i, p)) if e == "ui"]
    return out


def test_ui_schema_carries_every_action_payload():
    props = brain_schema()["properties"]["ui"]["items"]["properties"]
    assert set(UI_ACTIONS) == {"highlight", "offer_choices", "show_image", "open_screen", "set_timer", "read_aloud", "break_into_steps", "lookup_word"}
    assert props["action"]["enum"] == UI_ACTIONS
    for field in ("span", "choices", "screen", "seconds", "concept", "steps", "word"):
        assert field in props, field


def test_show_image_passes_only_allow_listed_concepts():
    assert _ui_events([{"action": "show_image", "concept": "tree"}]) == [{"action": "show_image", "concept": "tree"}]
    assert _ui_events([{"action": "show_image", "concept": " Tree "}]) == [{"action": "show_image", "concept": "tree"}]
    assert "tree" in CONCEPTS
    assert _ui_events([{"action": "show_image", "concept": "gun"}]) == []
    assert _ui_events([{"action": "show_image"}]) == []
    assert _ui_events([{"action": "show_image", "concept": 42}]) == []


def test_highlight_and_timer_still_pass_through():
    assert _ui_events([{"action": "highlight", "span": "w14"}]) == [{"action": "highlight", "span": "w14"}]
    assert _ui_events([{"action": "highlight", "span": "nope"}]) == []
    assert _ui_events([{"action": "set_timer", "seconds": 300}]) == [{"action": "set_timer", "seconds": 300}]
    assert _ui_events([{"action": "set_timer", "seconds": 3}]) == []
    assert _ui_events([{"action": "set_timer", "seconds": 99999}]) == []


def test_choices_and_open_screen_unchanged():
    assert _ui_events([{"action": "offer_choices", "choices": ["a", "b", "c", "d"]}]) == [
        {"action": "offer_choices", "choices": ["a", "b", "c"]}]
    assert _ui_events([{"action": "open_screen", "screen": "understand"}]) == [{"action": "open_screen", "screen": "understand"}]
    assert _ui_events([{"action": "open_screen", "screen": "launch_missiles"}]) == []
    assert _ui_events([{"action": "delete_files"}]) == []


def test_dart_and_json_visual_concepts_agree():
    root = pathlib.Path(__file__).resolve().parents[2]
    dart = (root / "lib" / "contracts" / "brain_contract.dart").read_text(encoding="utf-8")
    m = re.search(r"kVisualConcepts = \{(.*?)\};", dart, re.S)
    assert m, "kVisualConcepts set not found in brain_contract.dart"
    assert set(re.findall(r"'([a-z_]+)'", m.group(1))) == CONCEPTS


def test_streaming_parsers_deliver_show_image_to_assembler():
    doc = json.dumps({"risk": "none", "say": ["Look."], "ui": [{"action": "show_image", "concept": "moon"}], "followup": "none"})
    a, got = Assembler("friendly"), []
    p = JsonStream()
    for i in range(0, len(doc), 7):
        for k, key, val in p.feed(doc[i:i + 7]):
            got += a.handle(k, key, val)
    assert ("ui", {"action": "show_image", "concept": "moon"}) in got
    a, got = Assembler("friendly"), []
    for line in ('RISK:none\n', 'SAY:Look.\n', 'UI:{"action": "show_image", "concept": "moon"}\n', 'FOLLOW:none\n'):
        for k, key, val in LineStream().feed(line):
            got += a.handle(k, key, val)
    assert ("ui", {"action": "show_image", "concept": "moon"}) in got
