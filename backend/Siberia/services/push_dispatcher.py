"""
Диспетчер push-уведомлений.

Логика:
1. Получаем всех участников чата кроме отправителя.
2. Для каждого участника:
   a. Проверяем онлайн-статус в Redis.
   b. Если онлайн  → тихий пуш (только обновление бейджа).
   c. Если офлайн  → полный пуш с текстом сообщения.
   d. Проверяем мут чата — если замьючен, пуш не шлём.
3. После отправки удаляем невалидные токены из БД.
"""
import asyncio
import logging
from datetime import datetime, timezone

from sqlalchemy import delete as sa_delete
from sqlalchemy.future import select

from db import async_session_maker
from models.chat_member import ChatMember
from models.message_status import MessageStatus, MessageStatusEnum
from models.push_token import PushToken, PushPlatform, PushTokenKind
from models.chat_mute import ChatMuteSetting
from utils.redis import redis_client
from services import push_apns, push_fcm

logger = logging.getLogger("siberia.push.dispatcher")


async def _is_online(user_id: int) -> bool:
    """True если у пользователя есть активное WS-соединение."""
    val = await redis_client.get(f"ws:conn:{user_id}")
    return int(val or 0) > 0


async def _is_muted(db, user_id: int, chat_id: int) -> bool:
    """True если чат замьючен для пользователя."""
    result = await db.execute(
        select(ChatMuteSetting).where(
            ChatMuteSetting.user_id == user_id,
            ChatMuteSetting.chat_id == chat_id,
        )
    )
    mute = result.scalars().first()
    if not mute:
        return False
    if mute.muted_until is None:
        return True  # замьючен навсегда
    return mute.muted_until > datetime.now(timezone.utc)


async def _get_badge(db, user_id: int) -> int:
    """Суммарное число непрочитанных сообщений для пользователя."""
    result = await db.execute(
        select(MessageStatus).where(
            MessageStatus.user_id == user_id,
            MessageStatus.status != MessageStatusEnum.read,
        )
    )
    return len(result.scalars().all())


async def _remove_invalid_token(token_id: int) -> None:
    async with async_session_maker() as db:
        await db.execute(sa_delete(PushToken).where(PushToken.id == token_id))
        await db.commit()


async def dispatch_push_for_message(
    chat_id: int,
    message_id: int,
    sender_id: int,
    sender_nickname: str,
    message_text: str | None,
    mention_user_ids: list[int] | None = None,
) -> None:
    """
    Запускается как fire-and-forget asyncio.create_task() после отправки сообщения.
    Открывает собственную DB-сессию.
    """
    mentioned = set(mention_user_ids or [])
    try:
        async with async_session_maker() as db:
            # Все участники чата кроме отправителя
            result = await db.execute(
                select(ChatMember.user_id).where(
                    ChatMember.chat_id == chat_id,
                    ChatMember.user_id != sender_id,
                )
            )
            recipient_ids = [r[0] for r in result.all()]

            for user_id in recipient_ids:
                is_mention = user_id in mentioned
                await _dispatch_to_user(
                    db, user_id, chat_id, message_id,
                    sender_nickname, message_text,
                    force_alert=is_mention,
                )
    except Exception:
        logger.exception("push_dispatcher error chat=%d msg=%d", chat_id, message_id)


async def _dispatch_to_user(
    db,
    user_id: int,
    chat_id: int,
    message_id: int,
    sender_nickname: str,
    message_text: str | None,
    force_alert: bool = False,
) -> None:
    # Проверяем мут — мьют блокирует любые пуши (кроме упоминаний)
    if await _is_muted(db, user_id, chat_id) and not force_alert:
        return

    online = await _is_online(user_id)
    badge = await _get_badge(db, user_id)

    # Получаем все ALERT/FCM токены пользователя (VoIP — отдельный канал, только для звонков)
    result = await db.execute(
        select(PushToken).where(
            PushToken.user_id == user_id,
            PushToken.kind != PushTokenKind.voip,
        )
    )
    tokens = result.scalars().all()

    if not tokens:
        return

    # Формируем тело уведомления
    if message_text:
        body = message_text[:200]  # не слать весь текст в пуше
    else:
        body = "Новое сообщение"  # голосовое/медиа

    apns_payload_alert = {
        "aps": {
            "alert": {"title": sender_nickname, "body": body},
            "badge": badge,
            "sound": "default",
            "mutable-content": 1,
        },
        "chat_id": chat_id,
        "message_id": message_id,
    }
    apns_payload_silent = {
        "aps": {"content-available": 1, "badge": badge},
        "chat_id": chat_id,
    }

    fcm_data = {
        "chat_id": str(chat_id),
        "message_id": str(message_id),
        "badge": str(badge),
    }

    invalid_ids: list[int] = []

    for token in tokens:
        valid: bool
        send_alert = not online or force_alert
        if token.platform == PushPlatform.ios:
            if send_alert:
                valid = await push_apns.send(token.device_token, apns_payload_alert)
            else:
                valid = await push_apns.send(token.device_token, apns_payload_silent)
        else:
            if send_alert:
                valid = await push_fcm.send(
                    token.device_token, sender_nickname, body, fcm_data
                )
            else:
                valid = await push_fcm.send_silent(token.device_token, badge)

        if not valid:
            invalid_ids.append(token.id)

    # Удаляем невалидные токены
    for tid in invalid_ids:
        asyncio.create_task(_remove_invalid_token(tid))
