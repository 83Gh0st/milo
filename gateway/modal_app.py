"""Milo gateway on Modal (serverless containers).

Serves the EXISTING FastAPI app (`app.main:create_app` in this directory's
package) through Modal's ASGI integration. No routes, contracts, validation,
provider adapters, safety policies, or auth are reimplemented here: this file
only packages the gateway directory + the repo's `contracts/` directory into
a Modal image and binds configuration from a Modal Secret.

Deploy from the REPO ROOT (paths below are relative to it)::

    modal deploy gateway/modal_app.py

Required Modal Secret ``milo-gateway`` (never commit these values; see
``docs/MODAL.md`` for the exact ``modal secret create`` command)::

    Stage 1 - plumbing smoke test (no vendor key needed):
        ENV=dev  PROVIDER=mock  JWT_SECRET=<48+ random chars>
        KEY_ENC_SECRET=<48+ random chars>
        DATABASE_URL=sqlite+aiosqlite:////tmp/milo-modal.db   (ephemeral; mock only)
    Stage 2 - real online mode:
        ENV=prod  PROVIDER=meta  MODEL_API_KEY=<Meta Model API key>
        JWT_SECRET=<48+ random chars>  KEY_ENC_SECRET=<48+ random chars>
        DATABASE_URL=postgresql+asyncpg://...   (free-tier Postgres, e.g. Neon)

Single-container pinning is deliberate, not a cost shortcut: the gateway's
per-device RateLimiter and the router's circuit breakers are in-process
state (see ``app/security.py``), so exactly one container serves traffic.
``min_containers=1`` keeps one warm container so a child's first question
of the day does not pay a cold start; set it to 0 in this file to trade
latency for credit savings.
"""

import modal

APP_NAME = "milo-gateway"
SECRET_NAME = "milo-gateway"

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install_from_requirements("gateway/requirements.txt")
    .add_local_dir("gateway/app", remote_path="/root/milo/app")
    .add_local_dir("contracts", remote_path="/root/milo/contracts")
)

app = modal.App(APP_NAME)


@app.function(
    image=image,
    secrets=[modal.Secret.from_name(SECRET_NAME)],
    max_containers=1,  # in-memory rate limiter + circuit breakers: never scale out
    min_containers=1,  # keep warm; set 0 to save credit at the cost of cold starts
    scaledown_window=600,
    timeout=600,
)
@modal.concurrent(max_inputs=20)  # async FastAPI multiplexes on the one container
@modal.asgi_app()
def web():
    import os
    import sys

    sys.path.insert(0, "/root/milo")
    # contract.py defaults to <repo>/contracts/brain_contract.json relative to
    # the source tree; pin it explicitly so image layout can never drift.
    os.environ.setdefault("CONTRACT_PATH", "/root/milo/contracts/brain_contract.json")
    from app.main import create_app

    return create_app()
