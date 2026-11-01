"""Milo gateway STAGING on Modal (verification before production).

Identical code to ``modal_app.py`` (same FastAPI app, same guards), but a
separate Modal app (``milo-gateway-staging``) with its own secrets, so the
working ``milo-gateway`` app and ``milo-gateway`` secret are never touched
until the new configuration is verified here first.

Deploy from the REPO ROOT::

    modal deploy gateway/modal_staging.py

Required Modal secrets (create once; values stay in Modal)::

    milo-gateway-staging   full gateway config, e.g.:
        ENV=dev  PROVIDER=mock  REASONING_PROVIDER=modal  MODAL_FALLBACK=false
        JWT_SECRET=<48+ random>  KEY_ENC_SECRET=<48+ random>
        DATABASE_URL=            (empty: exercises database-optional chat;
                                  or a throwaway postgres URL to test vault/sync)
        SPEND_BACKEND=modal_dict SPEND_DICT_NAME=milo-spend-staging
    milo-models-client     MODAL_MODELS_URL=<models endpoint URL>
                           MODAL_MODELS_KEY=<proxy token for the Shared Endpoint>
                           MODAL_MODEL=<endpoint hostname from the dashboard request example>

With MODAL_FALLBACK=false, text turns use ONLY the hosted model: a hosted
outage fails loudly instead of silently testing mock. Verify with the
ladder in docs/MODAL.md, then promote the same code to production.
"""

import modal

APP_NAME = "milo-gateway-staging"
SECRET_NAME = "milo-gateway-staging"
MODELS_CLIENT_SECRET = "milo-models-client"

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install_from_requirements("gateway/requirements.txt")
    .add_local_dir("gateway/app", remote_path="/root/milo/app")
    .add_local_dir("contracts", remote_path="/root/milo/contracts")
)

app = modal.App(APP_NAME)


@app.function(
    image=image,
    secrets=[modal.Secret.from_name(SECRET_NAME), modal.Secret.from_name(MODELS_CLIENT_SECRET)],
    max_containers=1,  # same single-container pinning as production
    min_containers=0,  # staging sleeps when idle; cold starts are fine here
    scaledown_window=300,
    timeout=600,
)
@modal.concurrent(max_inputs=20)
@modal.asgi_app()
def web():
    import os
    import sys

    sys.path.insert(0, "/root/milo")
    os.environ.setdefault("CONTRACT_PATH", "/root/milo/contracts/brain_contract.json")
    from app.main import create_app

    return create_app()
