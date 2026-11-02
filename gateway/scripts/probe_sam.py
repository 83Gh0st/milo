#!/usr/bin/env python3
"""SAM 3.1 live-endpoint probe (Meta Model API). Run with a real key:

    pip install openai meta_sam_parser
    MODEL_API_KEY=... python probe_sam.py photo.jpg --concept "heart"
    MODEL_API_KEY=... python probe_sam.py clip.mp4 --concept "ping pong ball"

Exit 0 prints a JSON summary when the endpoint completes (even with zero
records - "no match" is a valid answer). Exit 2 on auth/refusal/error with
the sanitized upstream message. No key is ever printed.

Request shape follows Meta's own cookbook (07_sam/01_api_basics, fetched
2026-11-01): Responses API via the OpenAI SDK, image as data URL, video via
Files API (purpose=user_data), stream parsed ONLY with meta_sam_parser.
"""
import argparse
import asyncio
import base64
import json
import mimetypes
import os
import sys
from pathlib import Path

try:
    from meta_sam_parser import (
        image_segmentation_format,
        parse_responses_stream,
        video_segmentation_format,
    )
    from openai import AsyncOpenAI
except ImportError:
    print("need: pip install openai meta_sam_parser", file=sys.stderr)
    sys.exit(3)

BASE_URL = "https://api.meta.ai/v1"
MODEL = "sam-3.1"


def media_type(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    if guessed is None:
        raise ValueError(f"cannot infer media type for {path}")
    return guessed


async def coerce_events(stream):
    """Plain-dict events + synthesized output_text.done (see cookbook: the API
    streams content_part.done but not output_text.done, which closes a lane)."""
    done = set()
    async for ev in stream:
        d = ev.model_dump() if hasattr(ev, "model_dump") else dict(ev)
        lane = (d.get("item_id"), d.get("output_index"), d.get("content_index"))
        if d.get("type") == "response.output_text.done":
            if lane not in done:
                done.add(lane)
                yield d
            continue
        yield d
        part = d.get("part")
        if (d.get("type") == "response.content_part.done" and lane not in done
                and isinstance(part, dict) and part.get("type") == "output_text"
                and isinstance(part.get("text"), str)):
            done.add(lane)
            yield {"type": "response.output_text.done", "item_id": d.get("item_id"),
                   "output_index": d.get("output_index"),
                   "content_index": d.get("content_index"), "text": part["text"]}


async def run_image(api, path: Path, concept: str):
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    stream = await api.responses.create(
        model=MODEL, stream=True,
        input=[{"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": concept.strip()},
            {"type": "input_image", "image_url": f"data:{media_type(path)};base64,{data}"}]}])
    return await parse_responses_stream(coerce_events(stream), image_segmentation_format()).final_result()


async def run_video(api, path: Path, concept: str):
    up = await api.files.create(file=(path.name, path.read_bytes(), media_type(path)), purpose="user_data")
    if not str(up.id).startswith("file-"):
        raise ValueError("Files API returned an invalid file id")
    stream = await api.responses.create(
        model=MODEL, stream=True,
        input=[{"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": concept.strip()},
            {"type": "input_video", "file_id": up.id}]}])
    return await parse_responses_stream(coerce_events(stream), video_segmentation_format()).final_result()


def summarize(result, concept: str) -> dict:
    boxes = [r for r in result.records if r.kind == "box"]
    masks = [r for r in result.records if r.kind == "mask"]
    return {"outcome": result.outcome.status,
            "reason": getattr(result.outcome, "reason", None),
            "concept": concept, "records": len(result.records),
            "boxes": [{"object_id": r.object_id,
                       "box": [r.left, r.top, r.right, r.bottom]} for r in boxes[:20]],
            "masks": [{"object_id": r.object_id, "width": r.mask.width,
                       "height": r.mask.height, "encoding": r.mask.encoding} for r in masks[:20]],
            "diagnostics": [{"severity": d.severity, "code": d.code, "message": d.message}
                            for d in result.diagnostics][:10]}


async def main() -> int:
    ap = argparse.ArgumentParser(description="Probe SAM 3.1 on the Meta Model API.")
    ap.add_argument("media", type=Path)
    ap.add_argument("--concept", required=True, help="one short noun phrase")
    args = ap.parse_args()
    key = os.environ.get("MODEL_API_KEY")
    if not key or not args.media.is_file() or not args.concept.strip():
        print("need MODEL_API_KEY, an existing media file, and a non-empty --concept", file=sys.stderr)
        return 3
    try:
        async with AsyncOpenAI(base_url=BASE_URL, api_key=key) as api:
            if media_type(args.media).startswith("video/"):
                result = await run_video(api, args.media, args.concept)
            else:
                result = await run_image(api, args.media, args.concept)
    except Exception as e:  # auth/refusal/network: sanitize (never print the key)
        msg = str(e)
        print(json.dumps({"outcome": "error", "error": msg[:300]}), file=sys.stderr)
        return 2
    print(json.dumps(summarize(result, args.concept.strip()), indent=2))
    return 0 if result.outcome.status == "completed" else 2


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
