"""Validates model-generated UI specs (contracts/ui_contract.json).

A spec arrives as the brain turn's ``ui_spec`` object. This module sanitizes
it (all strings pass through safety.clean, so URLs and PII patterns never
reach the renderer) and returns a canonical dict — or None when the spec is
unusable. None is not an error: the turn continues with say/actions and the
client keeps its previous panel (classic chat), so a confused model degrades
instead of breaking the turn.
"""
import re

from .contract import (
    CONCEPTS,
    SCREENS,
    UI_COMP_ACTIONS,
    UI_COMPANION,
    UI_COMPONENTS,
    UI_INTENTS,
    UI_LAYOUTS,
    UI_LIMITS,
    UI_MODES,
    UI_OPS,
    UI_VERSION,
)
from .safety import clean

_ID = re.compile(r"[A-Za-z0-9_-]{1,32}")


def _ok_id(v) -> bool:
    return isinstance(v, str) and _ID.fullmatch(v) is not None and len(v) <= UI_LIMITS["max_id"]


def _text(v, cap):
    return clean(v, cap) if isinstance(v, str) else ""


def _action(a):
    """Sanitize one closed-vocabulary action object; None when malformed."""
    if not isinstance(a, dict):
        return None
    name = a.get("action")
    if name not in UI_COMP_ACTIONS:
        return None
    if name == "check":
        return {"action": name, "target": a["target"]} if _ok_id(a.get("target")) else None
    if name == "answer":
        if not _ok_id(a.get("target")):
            return None
        out = {"action": name, "target": a["target"]}
        if a.get("option") is not None:
            if not _ok_id(a["option"]):
                return None
            out["option"] = a["option"]
        return out
    if name == "next":
        return {"action": name}
    if name == "ask":
        p = _text(a.get("prompt", ""), UI_LIMITS["max_text"])
        return {"action": name, "prompt": p} if p else None
    if name == "speak":
        out = {"action": name}
        if a.get("target") is not None:
            if not _ok_id(a["target"]):
                return None
            out["target"] = a["target"]
        return out
    if name == "open_screen":
        return {"action": name, "screen": a["screen"]} if a.get("screen") in SCREENS else None
    return None  # unreachable: name in UI_COMP_ACTIONS


def _items(raw, cap, with_flag=None):
    """Sanitize [{id, text(, done|detail)}]; None when empty after cleaning."""
    if not isinstance(raw, list):
        return None
    out = []
    for it in raw[:cap]:
        if not isinstance(it, dict) or not _ok_id(it.get("id")):
            continue
        text = _text(it.get("text", ""), UI_LIMITS["max_text"])
        if not text:
            continue
        row = {"id": it["id"], "text": text}
        if with_flag == "done" and isinstance(it.get("done"), bool):
            row["done"] = it["done"]
        if with_flag == "detail":
            d = _text(it.get("detail", ""), UI_LIMITS["max_text"])
            if d:
                row["detail"] = d
        out.append(row)
    return out or None


def _actions(raw):
    if raw is None:
        return []
    if not isinstance(raw, list):
        return None
    out = []
    for a in raw[: UI_LIMITS["max_actions_per_node"]]:
        s = _action(a)
        if s is not None:
            out.append(s)
    return out


def _node(n, seen: set, depth: int):
    """Sanitize one component node; None when the node must be dropped."""
    if not isinstance(n, dict) or depth > UI_LIMITS["max_depth"]:
        return None
    t = n.get("type")
    if t not in UI_COMPONENTS or not _ok_id(n.get("id")) or n["id"] in seen:
        return None
    out = {"id": n["id"], "type": t}
    if t == "text":
        out["text"] = _text(n.get("text", ""), UI_LIMITS["max_text"])
        if not out["text"]:
            return None
    elif t == "card":
        title = _text(n.get("title", ""), UI_LIMITS["max_title"])
        if title:
            out["title"] = title
        if n.get("layout", "column") not in UI_LAYOUTS:
            return None
        out["layout"] = n.get("layout", "column")
        kids = _children(n.get("children", []), seen, depth + 1)
        if not kids:
            return None
        out["children"] = kids
    elif t == "button":
        out["label"] = _text(n.get("label", ""), UI_LIMITS["max_title"])
        act = _action(n.get("action"))
        if not out["label"] or act is None:
            return None
        out["action"] = act
    elif t == "choices":
        opts = _items(n.get("options", []), UI_LIMITS["max_items"])
        if not opts:
            return None
        out["options"] = [{"id": o["id"], "label": o["text"]} for o in opts]
        ans = n.get("answer")
        if ans is not None:
            if not _ok_id(ans) or ans not in {o["id"] for o in opts}:
                return None
            out["answer"] = ans
    elif t == "checklist":
        items = _items(n.get("items", []), UI_LIMITS["max_items"], with_flag="done")
        if not items:
            return None
        out["items"] = items
    elif t == "progress":
        v = n.get("value")
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        out["value"] = max(0.0, min(1.0, float(v)))
        label = _text(n.get("label", ""), UI_LIMITS["max_title"])
        if label:
            out["label"] = label
    elif t == "steps":
        steps = _items(n.get("steps", []), UI_LIMITS["max_items"], with_flag="detail")
        if not steps:
            return None
        out["steps"] = steps
        if n.get("current") is not None:
            if not _ok_id(n["current"]) or n["current"] not in {s["id"] for s in steps}:
                return None
            out["current"] = n["current"]
    elif t == "list":
        items = _items(n.get("items", []), UI_LIMITS["max_items"])
        if not items:
            return None
        out["items"] = items
    elif t == "image":
        c = n.get("concept", "")
        if not isinstance(c, str) or c.strip().lower() not in CONCEPTS:
            return None
        out["concept"] = c.strip().lower()
    elif t == "genimage":
        p, a = _text(n.get("prompt", ""), 140), _text(n.get("alt", ""), 200)
        if len(p) < 2:
            return None
        out["prompt"] = p
        out["alt"] = a if len(a) >= 2 else f"AI-made picture: {p}"
    elif t == "divider":
        pass
    acts = _actions(n.get("actions"))
    if acts is None:
        return None
    if acts:
        out["actions"] = acts
    seen.add(n["id"])
    return out


def _children(raw, seen: set, depth: int):
    if not isinstance(raw, list):
        return []
    return [s for n in raw for s in [_node(n, seen, depth)] if s is not None]


def _count(n) -> int:
    return 1 + sum(_count(c) for c in n.get("children", []))


def _state_patch(raw):
    if not isinstance(raw, dict) or len(raw) > UI_LIMITS["max_state_keys"]:
        return None
    out = {}
    for k, v in raw.items():
        if not _ok_id(k) or isinstance(v, (dict, list)):
            return None
        out[k] = _text(v, UI_LIMITS["max_state_value"]) if isinstance(v, str) else v
        if not isinstance(out[k], (str, int, float, bool)) or out[k] is None:
            return None
    return out


def _op(o, seen: set):
    if not isinstance(o, dict) or o.get("op") not in UI_OPS:
        return None
    name = o["op"]
    if name == "add":
        if not _ok_id(o.get("parent")):
            return None
        node = _node(o.get("node"), set(seen), 1)
        if node is None:
            return None
        out = {"op": name, "parent": o["parent"], "node": node}
        if o.get("index") is not None:
            if not isinstance(o["index"], int) or isinstance(o["index"], bool) or o["index"] < 0:
                return None
            out["index"] = o["index"]
        return out
    if name in ("update", "replace", "move", "remove"):
        if not _ok_id(o.get("target")):
            return None
        if name == "update":
            props = o.get("props")
            if not isinstance(props, dict) or not props:
                return None
            safe = {}
            for k, v in props.items():
                if not isinstance(k, str) or _ID.fullmatch(k) is None:
                    return None
                if isinstance(v, str):
                    safe[k] = _text(v, UI_LIMITS["max_text"])
                elif isinstance(v, bool) or isinstance(v, (int, float)):
                    safe[k] = v
                else:  # structured values need replace, not update
                    return None
            return {"op": name, "target": o["target"], "props": safe}
        if name == "replace":
            node = _node(o.get("with"), set(seen), 1)
            return {"op": name, "target": o["target"], "with": node} if node else None
        if name == "move":
            if not _ok_id(o.get("parent")):
                return None
            out = {"op": name, "target": o["target"], "parent": o["parent"]}
            if o.get("index") is not None:
                if not isinstance(o["index"], int) or isinstance(o["index"], bool) or o["index"] < 0:
                    return None
                out["index"] = o["index"]
            return out
        return {"op": name, "target": o["target"]}
    if name == "state":
        patch = _state_patch(o.get("patch"))
        return {"op": name, "patch": patch} if patch is not None else None
    return None


def validate_ui_spec(obj):
    """Return the sanitized spec dict, or None when there is nothing usable.

    ``{}`` (the model's "no interface this turn") returns None by design:
    callers treat None as "keep the previous panel".
    """
    if not isinstance(obj, dict) or not obj:
        return None
    if obj.get("v") != UI_VERSION:
        return None
    out = {"v": UI_VERSION}
    activity = obj.get("activity", "")
    if activity is None:
        activity = ""
    if not isinstance(activity, str) or (activity and not _ok_id(activity)):
        return None
    out["activity"] = activity
    for key, vocab in (("intent", UI_INTENTS), ("mode", UI_MODES), ("companion", UI_COMPANION)):
        if key in obj:  # delta specs omit these: the client keeps its current values
            if obj[key] not in vocab:
                return None
            out[key] = obj[key]
    if obj.get("speak") is not None:
        if not _ok_id(obj["speak"]):
            return None
        out["speak"] = obj["speak"]
    if obj.get("state") is not None:
        patch = _state_patch(obj["state"])
        if patch is None:
            return None
        out["state"] = patch
    seen: set = set()
    root = _node(obj.get("root"), seen, 1) if obj.get("root") is not None else None
    if obj.get("root") is not None and root is None:
        return None
    if root is not None:
        if _count(root) > UI_LIMITS["max_components"]:
            return None
        out["root"] = root
    ops_raw = obj.get("ops")
    if ops_raw is not None:
        if not isinstance(ops_raw, list) or len(ops_raw) > UI_LIMITS["max_ops"]:
            return None
        ops = []
        for o in ops_raw:
            s = _op(o, seen)
            if s is None:
                return None
            ops.append(s)
        if ops:
            out["ops"] = ops
    if "root" not in out and "ops" not in out and "state" not in out:
        return None
    return out
