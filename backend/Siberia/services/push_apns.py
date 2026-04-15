"""
APNs push через HTTP/2 API с JWT-аутентификацией (провайдерский токен, .p8 ключ).

Требования:
  - APNS_KEY_PATH  — путь к файлу AuthKey_XXXXXXXXXX.p8
  - APNS_KEY_ID    — 10-символьный ID ключа
  - APNS_TEAM_ID   — 10-символьный Team ID
  - APNS_BUNDLE_ID — Bundle ID приложения (apns-topic)
  - APNS_SANDBOX   — True для TestFlight/Simulator

Зависимость: httpx[http2] (pip install 'httpx[http2]').
Если h2 не установлен или конфиг не задан — тихо пропускаем.
"""
import json
import logging
import time
from typing import Any

from config import settings

logger = logging.getLogger("siberia.push.apns")

_APNS_HOST_PROD = "https://api.push.apple.com"
_APNS_HOST_SAND = "https://api.sandbox.push.apple.com"

# Кеш токена: (jwt_string, expires_at_timestamp)
_token_cache: tuple[str, float] | None = None


def _is_configured() -> bool:
    return bool(settings.APNS_KEY_PATH and settings.APNS_KEY_ID
                and settings.APNS_TEAM_ID and settings.APNS_BUNDLE_ID)


def _make_jwt() -> str:
    """Создаёт JWT-токен для APNs (ES256, валиден 1 час)."""
    global _token_cache

    now = time.time()
    if _token_cache and _token_cache[1] > now + 60:
        return _token_cache[0]

    from jose import jwt as jose_jwt

    with open(settings.APNS_KEY_PATH) as fh:
        private_key = fh.read()

    token = jose_jwt.encode(
        {"iss": settings.APNS_TEAM_ID, "iat": int(now)},
        private_key,
        algorithm="ES256",
        headers={"kid": settings.APNS_KEY_ID},
    )
    _token_cache = (token, now + 3000)  # кешируем на 50 минут
    return token


async def send(device_token: str, payload: dict[str, Any]) -> bool:
    """
    Отправляет пуш на iOS-устройство.
    Возвращает False если токен невалиден (нужно удалить из БД).
    """
    if not _is_configured():
        logger.debug("APNs не настроен, пропускаем пуш")
        return True

    try:
        import httpx
    except ImportError:
        logger.warning("httpx не установлен, APNs пуш недоступен")
        return True

    host = _APNS_HOST_SAND if settings.APNS_SANDBOX else _APNS_HOST_PROD
    url = f"{host}/3/device/{device_token}"

    try:
        jwt_token = _make_jwt()
    except Exception as exc:
        logger.error("Ошибка создания APNs JWT: %s", exc)
        return True

    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-topic": settings.APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
    }

    try:
        # http2=True требует pip install 'httpx[h2]'
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            resp = await client.post(url, headers=headers, content=json.dumps(payload))
    except Exception as exc:
        logger.error("APNs request error device=%s: %s", device_token[:16], exc)
        return True

    if resp.status_code == 200:
        return True

    reason = ""
    try:
        reason = resp.json().get("reason", "")
    except Exception:
        pass

    # Невалидный токен — удалить из БД
    if resp.status_code == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
        logger.info("APNs invalid token, removing: %s reason=%s", device_token[:16], reason)
        return False

    logger.warning("APNs error %s reason=%s device=%s", resp.status_code, reason, device_token[:16])
    return True


async def send_silent(device_token: str, badge: int) -> bool:
    """Тихий пуш — только обновляет бейдж, без уведомления."""
    payload = {"aps": {"content-available": 1, "badge": badge}}
    return await send(device_token, payload)


async def send_voip(device_token: str, payload: dict[str, Any]) -> bool:
    """
    VoIP-пуш (PushKit) — мгновенная доставка, может разбудить убитое приложение.

    КРИТИЧНО: на iOS 13+ клиент в ответ ОБЯЗАН сразу зарепортить CXProvider'у
    новый incoming call. Если этого не сделать в течение ~5 сек — Apple
    отзовёт VoIP-токен и следующие пуши перестанут доходить.

    apns-topic = bundleid.voip (отдельный от обычного APNs!)
    apns-push-type = voip
    apns-priority = 10
    """
    if not _is_configured():
        logger.debug("APNs не настроен, VoIP-пуш пропущен")
        return True

    try:
        import httpx
    except ImportError:
        logger.warning("httpx не установлен, VoIP-пуш недоступен")
        return True

    host = _APNS_HOST_SAND if settings.APNS_SANDBOX else _APNS_HOST_PROD
    url = f"{host}/3/device/{device_token}"

    try:
        jwt_token = _make_jwt()
    except Exception as exc:
        logger.error("Ошибка создания APNs JWT (VoIP): %s", exc)
        return True

    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-topic": f"{settings.APNS_BUNDLE_ID}.voip",
        "apns-push-type": "voip",
        "apns-priority": "10",
        "apns-expiration": "0",   # доставлять немедленно или никогда
    }

    try:
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            resp = await client.post(url, headers=headers, content=json.dumps(payload))
    except Exception as exc:
        logger.error("VoIP-push request error device=%s: %s", device_token[:16], exc)
        return True

    if resp.status_code == 200:
        return True

    reason = ""
    try:
        reason = resp.json().get("reason", "")
    except Exception:
        pass

    if resp.status_code == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
        logger.info("VoIP invalid token, removing: %s reason=%s", device_token[:16], reason)
        return False

    logger.warning("VoIP push error %s reason=%s device=%s",
                   resp.status_code, reason, device_token[:16])
    return True
