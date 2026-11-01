"""Generative-UI protocol: contract wiring, validator, assembler, ui_context."""
from app.contract import UI_COMPONENTS, UI_LIMITS, UI_VERSION, brain_schema
from app.models import BrainReq
from app.prompts import PERSONA
from app.safety import Assembler
from app.ui_spec import validate_ui_spec


def _valid():
    return {"v": UI_VERSION, "activity": "school-prep", "intent": "guide",
            "mode": "activity", "companion": "docked",
            "root": {"id": "panel", "type": "card", "title": "Get ready for school",
                     "layout": "column",
                     "children": [
                         {"id": "t1", "type": "text", "text": "Let's pack your bag."},
                         {"id": "cl", "type": "checklist",
                          "items": [{"id": "i1", "text": "Water bottle"},
                                    {"id": "i2", "text": "Lunch box", "done": True}]},
                         {"id": "go", "type": "button", "label": "Explain this step",
                          "action": {"action": "ask", "prompt": "Which step?"}}]},
            "state": {"step": 1, "done": False, "label": "packing"}}


def test_schema_requires_ui_spec_object():
    s = brain_schema()
    assert s["properties"]["ui_spec"] == {"type": "object"}
    assert "ui_spec" in s["required"]  # strict mode: every key required
    assert UI_COMPONENTS and UI_LIMITS["max_components"] == 40 and UI_LIMITS["max_depth"] == 4


def test_valid_checklist_spec_passes():
    out = validate_ui_spec(_valid())
    assert out["v"] == UI_VERSION and out["activity"] == "school-prep"
    assert out["root"]["children"][1]["items"][1]["done"] is True
    assert out["state"] == {"step": 1, "done": False, "label": "packing"}
    assert [c["id"] for c in out["root"]["children"]] == ["t1", "cl", "go"]  # button + its ask action survive
    assert out["root"]["children"][2]["action"] == {"action": "ask", "prompt": "Which step?"}


def test_empty_or_wrong_version_is_no_panel():
    assert validate_ui_spec({}) is None
    assert validate_ui_spec({"v": 999, "root": {"id": "a", "type": "divider"}}) is None
    assert validate_ui_spec("nope") is None
    assert validate_ui_spec({"v": UI_VERSION}) is None  # no root/ops/state: nothing to show


def test_bad_enums_kill_the_spec():
    bad = _valid()
    bad["intent"] = "hypnotize"
    assert validate_ui_spec(bad) is None
    bad = _valid()
    bad["mode"] = "vr"
    assert validate_ui_spec(bad) is None


def test_unknown_root_kills_spec_unknown_child_is_dropped():
    bad = _valid()
    bad["root"]["type"] = "teleporter"
    assert validate_ui_spec(bad) is None
    drop = _valid()
    drop["root"]["children"].append({"id": "x", "type": "teleporter"})
    out = validate_ui_spec(drop)
    assert [c["id"] for c in out["root"]["children"]] == ["t1", "cl", "go"]


def test_bad_actions_dropped_node_survives():
    spec = _valid()
    spec["root"]["children"][0]["actions"] = [{"action": "launch_missiles"},
                                              {"action": "speak", "target": "t1"}]
    out = validate_ui_spec(spec)
    assert out["root"]["children"][0]["actions"] == [{"action": "speak", "target": "t1"}]
    spec = _valid()
    spec["root"]["children"].append({"id": "b", "type": "button", "label": "Go",
                                     "action": {"action": "open_screen", "screen": "narnia"}})
    out = validate_ui_spec(spec)
    assert "b" not in [c["id"] for c in out["root"]["children"]]


def test_image_concept_must_be_known():
    spec = _valid()
    spec["root"]["children"].append({"id": "im", "type": "image", "concept": "backpack"})
    assert validate_ui_spec(spec) is not None
    spec["root"]["children"][-1]["concept"] = "mystery box"
    assert validate_ui_spec(spec) is not None  # bad image dropped, panel survives
    assert "im" not in [c["id"] for c in validate_ui_spec(spec)["root"]["children"]]


def test_genimage_prompt_and_alt():
    spec = _valid()
    spec["root"]["children"].append({"id": "g1", "type": "genimage", "prompt": "a friendly dinosaur", "alt": "A green cartoon dinosaur smiling"})
    kids = validate_ui_spec(spec)["root"]["children"]
    assert kids[-1]["prompt"] == "a friendly dinosaur" and kids[-1]["alt"] == "A green cartoon dinosaur smiling"
    spec["root"]["children"][-1] = {"id": "g1", "type": "genimage", "prompt": "a butterfly"}
    assert validate_ui_spec(spec)["root"]["children"][-1]["alt"].startswith("AI-made picture")  # alt always present
    spec["root"]["children"][-1] = {"id": "g1", "type": "genimage", "prompt": "x"}
    assert "g1" not in [c["id"] for c in validate_ui_spec(spec)["root"]["children"]]  # short prompt dropped
    assert "genimage" in PERSONA  # the model is taught the node
    assert "cannot see video" in PERSONA  # and forbidden from inventing media content


def test_strings_sanitized_and_capped():
    spec = _valid()
    spec["root"]["children"][0]["text"] = "see https://evil.example/x " + "y" * 900
    out = validate_ui_spec(spec)
    txt = out["root"]["children"][0]["text"]
    assert "evil.example" not in txt and len(txt) <= UI_LIMITS["max_text"]


def test_duplicate_ids_depth_and_size_caps():
    dup = _valid()
    dup["root"]["children"].append({"id": "t1", "type": "text", "text": "clone"})
    assert [c["id"] for c in validate_ui_spec(dup)["root"]["children"]] == ["t1", "cl", "go"]
    deep = {"id": "d0", "type": "card", "children": []}
    node = deep
    for i in range(1, 7):  # 7 deep > max_depth 4
        kid = {"id": f"d{i}", "type": "card", "children": []}
        node["children"] = [kid]
        node = kid
    leaf = {"id": "leaf", "type": "text", "text": "buried"}
    node["children"] = [leaf]
    out = validate_ui_spec({"v": UI_VERSION, "root": deep})
    assert out is None or "leaf" not in str(out)  # deep branch dropped (or card emptied)
    big = {"v": UI_VERSION, "root": {"id": "p", "type": "card",
                                    "children": [{"id": f"c{i}", "type": "divider"}
                                                 for i in range(60)]}}
    assert validate_ui_spec(big) is None  # > 40 components


def test_ops_apply_only_to_current_activity_and_validate():
    ops = {"v": UI_VERSION, "activity": "school-prep",
           "ops": [{"op": "update", "target": "cl",
                    "props": {"label": "see https://evil.example", "n": 3, "ok": True}},
                   {"op": "state", "patch": {"step": 2}},
                   {"op": "remove", "target": "t1"}]}
    out = validate_ui_spec(ops)
    assert out["activity"] == "school-prep" and len(out["ops"]) == 3
    assert "evil.example" not in out["ops"][0]["props"]["label"]  # props sanitized
    assert out["ops"][0]["props"]["n"] == 3
    bad = {"v": UI_VERSION, "ops": [{"op": "teleport", "target": "x"}]}
    assert validate_ui_spec(bad) is None  # one bad op kills the batch, not the turn
    nested = {"v": UI_VERSION, "ops": [{"op": "update", "target": "x", "props": {"items": [1]}}]}
    assert validate_ui_spec(nested) is None  # structured values need replace
    over = {"v": UI_VERSION, "ops": [{"op": "remove", "target": f"t{i}"} for i in range(20)]}
    assert validate_ui_spec(over) is None  # > max_ops


def test_delta_preserves_unsent_display_keys():
    out = validate_ui_spec({"v": UI_VERSION, "activity": "a", "ops": [{"op": "remove", "target": "t1"}]})
    assert "intent" not in out and "mode" not in out and "companion" not in out  # client keeps current


def test_add_op_embeds_valid_node():
    spec = {"v": UI_VERSION, "activity": "a",
            "ops": [{"op": "add", "parent": "panel", "index": 0,
                     "node": {"id": "n1", "type": "text", "text": "hello"}}]}
    out = validate_ui_spec(spec)
    assert out["ops"][0]["node"] == {"id": "n1", "type": "text", "text": "hello"}
    bad = {"v": UI_VERSION, "ops": [{"op": "add", "parent": "panel",
                                     "node": {"id": "n1", "type": "teleporter"}}]}
    assert validate_ui_spec(bad) is None


def test_assembler_emits_ui_spec_once_per_turn():
    asm = Assembler()
    valid = _valid()
    ev = asm.handle("field", "ui_spec", valid)
    assert ("ui_spec", validate_ui_spec(valid)) in ev  # alongside the leading body event
    assert asm.handle("field", "ui_spec", valid) == []  # second spec same turn: capped
    asm2 = Assembler()
    ev2 = asm2.handle("field", "ui_spec", {"v": 999})
    assert [e for e, _ in ev2] == ["body"]  # invalid: no ui_spec event, turn continues
    assert asm2.handle("field", "ui_spec", "junk") == []


def test_ui_context_flattens_and_caps():
    req = BrainReq(ui_context={"activity": "school-prep", "step": 2, "spoken": True,
                               "nested": {"a": 1}, "lst": [1], "bad id!": "x",
                               **{f"k{i}": "v" for i in range(20)}})
    ctx = req.ui_context
    assert ctx["activity"] == "school-prep" and ctx["step"] == 2 and ctx["spoken"] is True
    assert "nested" not in ctx and "lst" not in ctx and "bad id!" not in ctx
    assert len(ctx) <= 12
    long = BrainReq(ui_context={"t": "x" * 900}).ui_context
    assert len(long["t"]) == 500


def test_prompt_teaches_ui_spec_shape():
    assert "ui_spec" in PERSONA and "checklist" in PERSONA and "CURRENT activity" in PERSONA
    assert "first character must be {" in PERSONA  # reasoning models must not preamble
