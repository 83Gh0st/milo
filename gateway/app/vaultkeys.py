"""Family BYOK keys at rest: Fernet-sealed with a KEK derived from KEY_ENC_SECRET.

The KEK lives only in the gateway environment (use a real secret manager or
KMS in production; losing it means stored family keys must be re-entered).
Dev/test may run without a secret; production refuses to start without one.
"""
import base64

from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

_DEV_KEK = "milo-dev-only-not-for-production-use-00"


def _kek(secret: str, env: str) -> bytes:
    raw = secret.encode() if secret else (_DEV_KEK.encode() if env != "prod" else None)
    if raw is None:
        raise RuntimeError("KEY_ENC_SECRET is required in prod")
    out = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"milo-byok-v1", info=b"vault-key-encryption").derive(raw)
    return base64.urlsafe_b64encode(out)


def seal_vault_key(secret: str, env: str, api_key: str) -> str:
    return Fernet(_kek(secret, env)).encrypt(api_key.encode()).decode()


def open_vault_key(secret: str, env: str, token: str) -> str:
    try:
        return Fernet(_kek(secret, env)).decrypt(token.encode()).decode()
    except InvalidToken:
        raise ValueError("stored family key cannot be decrypted")


def key_hint(api_key: str) -> str:
    return "…" + api_key.strip()[-4:]
