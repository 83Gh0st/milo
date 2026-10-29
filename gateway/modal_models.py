"""Milo's hosted open-weight model on Modal (vLLM, OpenAI-compatible).

Serves Qwen3-4B-Instruct (Apache 2.0, ungated) on a single T4 as an
OpenAI-compatible HTTPS endpoint that the gateway calls like any other
OpenAI-compatible provider. This is a SEPARATE Modal app (``milo-models``)
from the gateway: deploying it never touches the ``milo-gateway`` app or
the ``milo-gateway`` secret.

Why this model: 4B parameters (~8 GB bf16) fit a T4 (16 GB) with room for
KV cache; Apache 2.0 + ungated means no Hugging Face token and no license
review; instruction-tuned for short structured turns; vLLM-supported.
Qwen2.5-VL was rejected (research-only license); Gemma-3-4B-it is the
documented multimodal upgrade (gated: needs HF_TOKEN + terms acceptance).

Cost controls (all deliberate, see docs/MODAL.md):
- exactly one T4 (``max_containers=1``), scale-to-zero (``min_containers=0``),
  5-minute scaledown: GPU burns only while serving + short idle tail
- T4 list price $0.000164/s (~$0.59/hr); weights cached on a Modal Volume so
  cold starts skip the ~8 GB download (volume ~$0.55/mo)
- ``--enforce-eager`` trades peak throughput for fast cold boots (Milo turns
  are short; latency-to-first-token matters more than batch throughput)
- bounded context (8192) and concurrency (4) cap per-request GPU work

Auth: the endpoint URL is public but every request needs the vLLM API key
(``VLLM_API_KEY`` in the ``milo-models`` secret). The gateway holds the key
server-side (``milo-models-client`` secret); the Flutter app never sees it.

Deploy from the REPO ROOT::

    modal secret create milo-models VLLM_API_KEY=<64+ random chars>
    modal deploy gateway/modal_models.py

Then point the gateway at it (staging first — see docs/MODAL.md)::

    modal secret create milo-models-client `
        MODAL_MODELS_URL=https://<workspace>--milo-models-serve.us-east.modal.run `
        MODAL_MODELS_KEY=<same VLLM_API_KEY value>

Verify without deploying the gateway (runs on your machine, needs the
endpoint URL + key)::

    modal run gateway/modal_models.py
"""

import json
import os

import modal

APP_NAME = "milo-models"
SECRET_NAME = "milo-models"

MODEL_NAME = "Qwen/Qwen3-4B-Instruct-2507"
MODEL_REVISION = "cdbee75f17c01a7cc42f958dc650907174af0554"  # pinned: no surprise weight updates
VLLM_PORT = 8000

vllm_image = (
    modal.Image.from_registry("nvidia/cuda:12.9.0-devel-ubuntu22.04", add_python="3.12")
    .entrypoint([])
    .uv_pip_install("vllm==0.21.0")
    .env({"HF_XET_HIGH_PERFORMANCE": "1", "VLLM_LOG_STATS_INTERVAL": "60"})
)

hf_cache_vol = modal.Volume.from_name("milo-hf-cache", create_if_missing=True)
vllm_cache_vol = modal.Volume.from_name("milo-vllm-cache", create_if_missing=True)

app = modal.App(APP_NAME)


@app.server(
    image=vllm_image,
    gpu="T4",  # cheapest GPU that fits 4B bf16 + KV cache; L4 is the one-line fallback
    secrets=[modal.Secret.from_name(SECRET_NAME, required_keys=["VLLM_API_KEY"])],
    scaledown_window=300,  # GPU released 5 min after the last request
    startup_timeout=600,  # cold start: image + weights (cached) + engine init
    max_containers=1,  # cost pin: never scale out
    min_containers=0,  # scale to zero when idle
    target_concurrency=4,  # small queue per replica; Milo turns are short
    volumes={"/root/.cache/huggingface": hf_cache_vol, "/root/.cache/vllm": vllm_cache_vol},
    port=VLLM_PORT,
    routing_region="us-east",  # same region as the gateway: low latency, no egress surprises
    unauthenticated=True,  # URL is public; vLLM --api-key enforces auth per request
)
class Serve:
    @modal.enter()
    def start(self):
        import subprocess

        key = os.environ.get("VLLM_API_KEY", "")
        if not key:
            raise RuntimeError("VLLM_API_KEY missing from the milo-models secret")
        cmd = ["vllm", "serve", MODEL_NAME, "--revision", MODEL_REVISION,
               "--served-model-name", MODEL_NAME, "--host", "0.0.0.0", "--port", str(VLLM_PORT),
               "--api-key", key, "--enforce-eager", "--gpu-memory-utilization", "0.88",
               "--max-model-len", "8192", "--max-num-seqs", "8", "--uvicorn-log-level=warning"]
        print("vllm serve", MODEL_NAME, MODEL_REVISION, flush=True)
        self.process = subprocess.Popen(cmd)

    @modal.exit()
    def stop(self):
        self.process.terminate()


@app.local_entrypoint()
async def test(url: str = "", key: str = ""):
    """Health + genuine keyed inference (chat + streaming) against the
    deployed endpoint. Pass url=/key= explicitly, or set MODAL_MODELS_URL /
    MODAL_MODELS_KEY in your shell; nothing here reads the Modal secret."""
    import asyncio

    import aiohttp

    url = url or os.environ.get("MODAL_MODELS_URL", "")
    key = key or os.environ.get("MODAL_MODELS_KEY", "")
    if not url:
        try:
            url = await Serve.get_url.aio()
        except Exception as e:
            raise SystemExit(f"pass url= explicitly (auto-resolve failed: {e})")
    if not key:
        raise SystemExit("pass key= explicitly or set MODAL_MODELS_KEY")
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    async with aiohttp.ClientSession(base_url=url) as session:
        for _ in range(60):  # cold starts take minutes; poll /health
            async with session.get("/health", timeout=aiohttp.ClientTimeout(total=30)) as r:
                if r.status == 200:
                    break
                print("health:", r.status, flush=True)
            await asyncio.sleep(10)
        else:
            raise SystemExit("endpoint never became healthy")
        print("health: 200", flush=True)
        payload = {"model": MODEL_NAME, "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
                   "max_tokens": 8, "stream": False}
        async with session.post("/v1/chat/completions", json=payload, headers=headers,
                                timeout=aiohttp.ClientTimeout(total=120)) as r:
            body = await r.text()
            print("chat:", r.status, body[:300], flush=True)
            assert r.status == 200 and "ok" in body.lower(), "no genuine model response"
        payload["stream"] = True
        n = 0
        async with session.post("/v1/chat/completions", json=payload, headers=headers,
                                timeout=aiohttp.ClientTimeout(total=120)) as r:
            assert r.status == 200, await r.text()
            async for raw in r.content:
                line = raw.decode().strip()
                if line.startswith("data:") and "[DONE]" not in line:
                    n += 1
        print(f"streaming chunks: {n}", flush=True)
        assert n > 0, "no streamed chunks"
        print("MODEL OK: genuine keyed inference + streaming", flush=True)
