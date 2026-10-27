"""Run on 26 Oct (section 9.6): verifies the real Meta Model API behaves as Milo assumes. Writes smoke_report.json.
  MODEL_API_KEY=... python scripts/smoke_test.py [--image worksheet.jpg] [--pcm child_24khz_mono.pcm]"""
import argparse, asyncio, base64, json, os, statistics, sys, time, uuid
from openai import AsyncOpenAI

BASE = os.environ.get("META_BASE_URL", "https://api.meta.ai/v1")
ASR = os.environ.get("META_ASR_URL", "wss://api.meta.ai/v1/asr/realtime")
KEY = os.environ["MODEL_API_KEY"]
SPARK, VOICE, IMAGE = os.environ.get("SPARK_MODEL", "muse-spark-1.3"), os.environ.get("VOICE_MODEL", "muse-voice-transcribe-1.0"), os.environ.get("IMAGE_MODEL", "muse-image-1.0")
R: dict = {}
SCHEMA = {"type": "object", "properties": {"say": {"type": "array", "items": {"type": "string"}}, "emotion": {"type": "string"}}, "required": ["say", "emotion"]}


async def step(name, fn):
    t = time.monotonic()
    try:
        R[name] = {"ok": True, "detail": await fn(), "s": round(time.monotonic() - t, 2)}
    except Exception as e:
        R[name] = {"ok": False, "detail": f"{type(e).__name__}: {str(e)[:300]}", "s": round(time.monotonic() - t, 2)}
    print(("PASS " if R[name]["ok"] else "FAIL ") + name, R[name]["detail"])


async def main(a):
    c = AsyncOpenAI(base_url=BASE, api_key=KEY, timeout=60)
    msgs = [{"role": "user", "content": 'Reply as JSON {"say":["one short greeting"],"emotion":"happy"}'}]

    async def t1(): return (await c.chat.completions.create(model=SPARK, messages=msgs, max_completion_tokens=200)).choices[0].message.content[:80]
    async def t2():
        n = 0
        async for ch in await c.chat.completions.create(model=SPARK, messages=msgs, stream=True, max_completion_tokens=200):
            n += bool(ch.choices and ch.choices[0].delta.content)
        return f"{n} chunks"
    async def t3():
        txt = ""
        async for ch in await c.chat.completions.create(model=SPARK, messages=msgs, stream=True, max_completion_tokens=300, response_format={"type": "json_schema", "json_schema": {"name": "t", "schema": SCHEMA}}):
            txt += (ch.choices[0].delta.content or "") if ch.choices else ""
        json.loads(txt); return "streaming + json_schema OK -> BRAIN_MODE=json"
    async def t4():
        if not a.image: return "SKIPPED (pass --image)"
        b = base64.b64encode(open(a.image, "rb").read()).decode()
        r = await c.chat.completions.create(model=SPARK, max_completion_tokens=300, messages=[{"role": "user", "content": [{"type": "text", "text": "What does this page say? One sentence."}, {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b}}]}])
        return r.choices[0].message.content[:120]
    async def t5():
        out = {}
        for e in ("minimal", "high"):
            t = time.monotonic(); await c.chat.completions.create(model=SPARK, messages=msgs, reasoning_effort=e, max_completion_tokens=400); out[e] = round(time.monotonic() - t, 2)
        return out
    async def t6():
        if not a.pcm: return "SKIPPED (pass --pcm). Also try an English, Hindi and Malayalam sample plus a child-like voice"
        r = await c.audio.transcriptions.create(model=VOICE, file=open(a.pcm, "rb")); return r.text[:100]
    async def t7():
        if not a.pcm: return "SKIPPED (pass --pcm)"
        import websockets
        ws = await websockets.connect(f"{ASR}?sessionId=stream-{uuid.uuid4()}")
        await ws.send(json.dumps({"authorization": {"accessToken": f"Bearer {KEY}"}, "audioEncoding": "PCM_24KHZ", "model": VOICE, "mode": "ENDPOINTING", "partialMode": "CUMULATIVE", "emitAudioProgress": False, "zdrOverride": True}))
        ack = json.loads(await asyncio.wait_for(ws.recv(), 10)); assert "sessionId" in ack, ack
        pcm = open(a.pcm, "rb").read()
        async def send():
            for i in range(0, len(pcm), 4800): await ws.send(pcm[i:i + 4800]); await asyncio.sleep(0.1)
            await ws.send(json.dumps({"type": "endStream"}))
        asyncio.create_task(send()); got = []
        try:
            async with asyncio.timeout(30):
                async for m in ws:
                    d = json.loads(m); got.append(d.get("type"))
                    if d.get("type") == "speechComplete": return {"events": sorted(set(got)), "text": d.get("transcript")}
        finally: await ws.close()
        return {"events": got}
    async def t8():
        r = await c.images.generate(model=IMAGE, prompt="Flat vector illustration of a tree, thick outlines, plain white background, no text", n=1, size="1024x1024"); return f"{len(r.data[0].b64_json)} b64 chars"
    async def t9():
        raw = await c.chat.completions.with_raw_response.create(model=SPARK, messages=msgs, max_completion_tokens=50)
        return {k: v for k, v in raw.headers.items() if "limit" in k.lower() or "remaining" in k.lower() or "credit" in k.lower() or "retry" in k.lower()} or "no rate-limit headers; check the dev.meta.ai dashboard for credits"
    async def t10(): return "MANUAL: read data retention, training and children's-data terms for the STANDARD tier at dev.meta.ai before any real child uses Milo"
    async def t11():
        ts = []
        for _ in range(10):
            t = time.monotonic()
            async for ch in await c.chat.completions.create(model=SPARK, messages=msgs, stream=True, max_completion_tokens=60, reasoning_effort="minimal"):
                if ch.choices and ch.choices[0].delta.content: break
            ts.append(time.monotonic() - t)
        ts.sort(); return {"first_token_p50_s": round(statistics.median(ts), 2), "p95_s": round(ts[-1], 2), "target": "<= 1.5 s"}
    async def t12():
        ids = [m.id for m in (await c.models.list()).data]; bad = [i for i in ids if i.endswith("-contributor")]
        return {"models": ids, "contributor_models_present(never use)": bad, "configured_ok": all(m in ids for m in (SPARK, VOICE, IMAGE))}
    for i, f in enumerate((t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12), 1):
        await step(f"{i:02d}_{f.__name__}", f)
    json.dump(R, open("smoke_report.json", "w"), indent=2)
    sys.exit(0 if all(v["ok"] for v in R.values()) else 1)

if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("--image"); p.add_argument("--pcm")
    asyncio.run(main(p.parse_args()))
