"""FCM push через HTTP v1 API.

Legacy HTTP API (`fcm.googleapis.com/fcm/send` + Server Key) отключён Google
в 2024 — здесь актуальный v1 API с OAuth2-авторизацией сервис-аккаунтом.

OAuth2-токен получаем сами (JWT-bearer flow) через python-jose + httpx, без
тяжёлых google-* зависимостей.

Требования (env):
  - FCM_PROJECT_ID        — id проекта Firebase
  - FCM_CREDENTIALS_PATH  — путь к JSON сервис-аккаунта (Firebase Console →
                            Project Settings → Service accounts → Generate key)

Если креды не заданы или битые — пуши тихо пропускаются (return True).
"""
import json
import logging
import time

import httpx

from config import settings

logger = logging.getLogger("siberia.push.fcm")

_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

# Кеш service-account JSON и access-токена — на процесс.
_sa: dict | None = None
_sa_failed = False
_token: str | None = None
_token_exp: float = 0.0


def _v1_url() -> str:
    return f"https://fcm.googleapis.com/v1/projects/{settings.FCM_PROJECT_ID}/messages:send"


def _is_configured() -> bool:
    return bool(settings.FCM_PROJECT_ID and settings.FCM_CREDENTIALS_PATH)


def _load_sa() -> dict | None:
    global _sa, _sa_failed
    if _sa is not None:
        return _sa
    if _sa_failed:
        return None
    try:
        with open(settings.FCM_CREDENTIALS_PATH, encoding="utf-8") as f:
            _sa = json.load(f)
        assert _sa.get("client_email") and _sa.get("private_key")
        return _sa
    except Exception as exc:  # noqa: BLE001
        _sa_failed = True
        logger.error("FCM: не удалось загрузить сервис-аккаунт (%s) — Android-пуши отключены", exc)
        return None


async def _access_token() -> str | None:
    """OAuth2 access-token с кешем (рефреш за 60с до истечения)."""
    global _token, _token_exp
    now = time.time()
    if _token and now < _token_exp - 60:
        return _token

    sa = _load_sa()
    if sa is None:
        return None

    from jose import jwt as jose_jwt

    token_uri = sa.get("token_uri", "https://oauth2.googleapis.com/token")
    iat = int(now)
    assertion = jose_jwt.encode(
        {
            "iss": sa["client_email"],
            "scope": _SCOPE,
            "aud": token_uri,
            "iat": iat,
            "exp": iat + 3600,
        },
        sa["private_key"],
        algorithm="RS256",
    )

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                token_uri,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    "assertion": assertion,
                },
            )
    except Exception as exc:  # noqa: BLE001
        logger.error("FCM: ошибка запроса OAuth2-токена: %s", exc)
        return None

    if resp.status_code != 200:
        logger.error("FCM: OAuth2 token error %s: %s", resp.status_code, resp.text[:200])
        return None

    body = resp.json()
    _token = body["access_token"]
    _token_exp = now + int(body.get("expires_in", 3600))
    return _token


def _stringify(data: dict) -> dict[str, str]:
    # v1 требует, чтобы все значения в data были строками
    return {k: str(v) for k, v in (data or {}).items() if v is not None}


async def _post(message: dict, device_token: str) -> bool:
    """POST в v1 endpoint. Возвращает False только если токен явно невалиден."""
    if not _is_configured():
        logger.debug("FCM не настроен, пропускаем пуш")
        return True

    token = await _access_token()
    if not token:
        return True  # проблема конфигурации, не токена — не удаляем токен

    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(_v1_url(), json={"message": message}, headers=headers)
    except Exception as exc:  # noqa: BLE001
        logger.error("FCM request error device=%s: %s", device_token[:16], exc)
        return True

    if resp.status_code == 200:
        return True

    # 404 / UNREGISTERED → токен мёртв, удалить из БД
    if resp.status_code in (400, 403, 404):
        try:
            err = resp.json().get("error", {})
            status = err.get("status", "")
            codes = {d.get("errorCode") for d in err.get("details", []) if isinstance(d, dict)}
        except Exception:  # noqa: BLE001
            status, codes = "", set()
        if resp.status_code == 404 or "UNREGISTERED" in codes or status == "NOT_FOUND":
            logger.info("FCM invalid token: %s", device_token[:16])
            return False

    logger.warning("FCM HTTP error %s device=%s: %s", resp.status_code, device_token[:16], resp.text[:200])
    return True


async def send(device_token: str, title: str, body: str, data: dict[str, str]) -> bool:
    """Alert-пуш на Android. False → токен невалиден (удалить из БД)."""
    message = {
        "token": device_token,
        "notification": {"title": title, "body": body},
        "android": {
            "priority": "HIGH",
            "notification": {"sound": "default"},
        },
        "data": _stringify(data),
    }
    return await _post(message, device_token)


async def send_silent(device_token: str, badge: int) -> bool:
    """Тихий data-only пуш — обновление бейджа."""
    message = {
        "token": device_token,
        "android": {"priority": "NORMAL"},
        "data": {"badge": str(badge), "silent": "1"},
    }
    return await _post(message, device_token)
