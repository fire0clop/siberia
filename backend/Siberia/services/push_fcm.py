"""
FCM push через Legacy HTTP API.

Требования:
  - FCM_SERVER_KEY — Server Key из Firebase Console
    (Project Settings → Cloud Messaging → Server key)

Зависимость: только httpx (уже есть в проекте).
"""
import logging
from typing import Any

import httpx

from config import settings

logger = logging.getLogger("siberia.push.fcm")

_FCM_URL = "https://fcm.googleapis.com/fcm/send"


def _is_configured() -> bool:
    return bool(settings.FCM_SERVER_KEY)


async def send(device_token: str, title: str, body: str, data: dict[str, str]) -> bool:
    """
    Отправляет пуш на Android-устройство.
    Возвращает False если токен невалиден (нужно удалить из БД).
    """
    if not _is_configured():
        logger.debug("FCM не настроен, пропускаем пуш")
        return True

    payload = {
        "to": device_token,
        "notification": {"title": title, "body": body, "sound": "default"},
        "data": data,
        "priority": "high",
    }
    headers = {
        "Authorization": f"key={settings.FCM_SERVER_KEY}",
        "Content-Type": "application/json",
    }

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(_FCM_URL, json=payload, headers=headers)
    except Exception as exc:
        logger.error("FCM request error device=%s: %s", device_token[:16], exc)
        return True

    if resp.status_code != 200:
        logger.warning("FCM HTTP error %s device=%s", resp.status_code, device_token[:16])
        return True

    result = resp.json()
    if result.get("failure") == 0:
        return True

    # Проверяем каждый результат (хотя у нас один токен)
    for res in result.get("results", []):
        err = res.get("error", "")
        if err in ("NotRegistered", "InvalidRegistration"):
            logger.info("FCM invalid token: %s", device_token[:16])
            return False  # сигнал удалить токен

    return True


async def send_silent(device_token: str, badge: int) -> bool:
    """Тихий data-only пуш — только обновление бейджа."""
    if not _is_configured():
        return True

    payload = {
        "to": device_token,
        "data": {"badge": str(badge), "silent": "1"},
        "priority": "normal",
    }
    headers = {
        "Authorization": f"key={settings.FCM_SERVER_KEY}",
        "Content-Type": "application/json",
    }

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.post(_FCM_URL, json=payload, headers=headers)
    except Exception as exc:
        logger.error("FCM silent error: %s", exc)
    return True
