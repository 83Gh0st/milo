"""Adapter for Milo's Modal-hosted model: Muse Spark Open behind a Modal
Shared Endpoint (OpenAI-compatible Chat Completions).

Deployer-only: it is registered with the deployer credentials and is never
a family provider (family route validation rejects it), so hosted spend
is always attributed to the deployer budget, never silently to a family.
The endpoint is managed by Modal (no GPU of ours); credentials are the
endpoint URL plus a proxy token, both server-side only.

Vision stays declared unsupported until it is tested against the real
endpoint: image turns fail over or fail honestly instead of assuming a
capability the contract never verified.
"""
from .capabilities import Capabilities
from .openai_compat import OpenAICompatAdapter


class ModalAdapter(OpenAICompatAdapter):
    id = "modal"
    display_name = "Milo hosted"

    def capabilities(self):
        return Capabilities(text_stream=True, json_schema=True)

    def _payload_extra(self, model):
        # Qwen3 hybrid thinking off — but ONLY for Qwen-family ids. The
        # default hosted model (Muse Spark) gets a stock OpenAI payload;
        # vendor-specific extras must never leak onto other servers.
        if "qwen" in str(model).lower():
            return {"chat_template_kwargs": {"enable_thinking": False}}
        return {}
