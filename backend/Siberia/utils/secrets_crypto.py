"""At-rest защита чувствительных полей БД.

Две операции:
  hash_token   — необратимый SHA-256 для рефреш-токенов. Токен — это
                 высокоэнтропийный JWT, поэтому быстрый хеш достаточен
                 (перебирать нечего, соль не нужна). В базе лежит хеш;
                 сравниваем присланный токен по хешу. Дамп базы больше не
                 даёт рабочих рефреш-токенов.
  encrypt_secret / decrypt_secret — обратимое AES-GCM для TOTP-секретов
                 (их нужно ЧИТАТЬ, чтобы проверять коды). Ключ выводится из
                 SECRET_KEY через HKDF. Дамп базы без SECRET_KEY бесполезен.

Формат шифротекста: "enc:v1:<base64(nonce(12) || ct || tag)>".
"""
from __future__ import annotations

import base64
import hashlib
import hmac

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from config import settings

_ENC_PREFIX = "enc:v1:"
_HKDF_INFO = b"siberia-at-rest-v1"


def hash_token(token: str) -> str:
    """SHA-256 hex рефреш-токена (необратимо)."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _aes_key() -> bytes:
    """32-байтовый ключ из SECRET_KEY (HKDF-Extract+Expand, одна итерация)."""
    salt = b"siberia-secrets-salt-v1"
    prk = hmac.new(salt, settings.SECRET_KEY.encode("utf-8"), hashlib.sha256).digest()
    okm = hmac.new(prk, _HKDF_INFO + b"\x01", hashlib.sha256).digest()
    return okm  # 32 байта


def is_encrypted(value: str | None) -> bool:
    return bool(value) and value.startswith(_ENC_PREFIX)


def encrypt_secret(plaintext: str) -> str:
    import os
    nonce = os.urandom(12)
    ct = AESGCM(_aes_key()).encrypt(nonce, plaintext.encode("utf-8"), None)
    return _ENC_PREFIX + base64.b64encode(nonce + ct).decode("ascii")


def decrypt_secret(value: str) -> str:
    """Расшифровать enc:v1:... . Если строка не зашифрована (легаси) — вернуть как есть."""
    if not is_encrypted(value):
        return value
    raw = base64.b64decode(value[len(_ENC_PREFIX):])
    nonce, ct = raw[:12], raw[12:]
    return AESGCM(_aes_key()).decrypt(nonce, ct, None).decode("utf-8")
