"""Adapter for Milo's Modal-hosted open-weight model (vLLM, OpenAI-compatible).

Deployer-only: it is registered with the deployer credentials and is never
a family provider (family route validation rejects it), so hosted GPU spend
is always attributed to the deployer budget, never silently to a family.

The served model is text-only instruction-tuned (Qwen3-4B): hybrid thinking
is switched off per request (short structured turns don't benefit, and it
halves GPU burn), and vision is declared unsupported so image turns fail
over or fail honestly instead of sending pictures to a blind model.
"""
from .capabilities import Capabilities
from .openai_compat import OpenAICompatAdapter


class ModalAdapter(OpenAICompatAdapter):
    id = "modal"
    display_name = "Milo hosted"

    def capabilities(self):
        return Capabilities(text_stream=True, json_schema=True)

    def _payload_extra(self, model):
        # Qwen3 hybrid thinking off: Milo turns are short structured JSON;
        # reasoning traces would only add latency + GPU seconds. Unknown to
        # other servers, so this hook lives only on the modal adapter.
        return {"chat_template_kwargs": {"enable_thinking": False}}
