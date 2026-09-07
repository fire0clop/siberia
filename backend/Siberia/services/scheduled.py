"""Отложенные сообщения: планирование, список, отмена, доставка воркером.

До отправки сообщение живёт в scheduled_messages; настоящая строка в
messages создаётся в момент доставки через create_message — со свежим id
(корректная позиция в ленте), статусами, конвертом и пушем. Идемпотентность
доставки — client_message_id: при ретрае create_message вернёт дубликат.
"""
from __future__ import annotations

import logging
import uuid as uuid_mod
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from models.chat import Chat, ChatType
from models.chat_member import ChatMember, MemberRole
from models.scheduled_message import ScheduledMessage
from services.chat import check_user_in_chat

logger = logging.getLogger("siberia.scheduled")

_MAX_DELAY_DAYS = 365


async def schedule_message(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
    *,
    text: str | None,
    entities=None,
    media_id=None,
    reply_to_message_id: int | None,
    send_at: datetime,
) -> ScheduledMessage:
    await check_user_in_chat(db, user_id, chat_id)

    chat = await db.get(Chat, chat_id)
    if chat is not None and chat.type == ChatType.secret:
        raise HTTPException(status_code=400, detail="Secret chats: scheduling not allowed")

    member = (await db.execute(
        select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
    )).scalars().first()
    if member is not None and member.role == MemberRole.subscriber:
        raise HTTPException(status_code=403, detail="Subscribers cannot post in channels")

    now = datetime.now(timezone.utc)
    if send_at.tzinfo is None:
        send_at = send_at.replace(tzinfo=timezone.utc)
    if send_at <= now:
        raise HTTPException(status_code=400, detail="send_at must be in the future")
    if send_at > now + timedelta(days=_MAX_DELAY_DAYS):
        raise HTTPException(status_code=400, detail=f"send_at too far (max {_MAX_DELAY_DAYS} days)")

    from services.message import validate_entities
    validated = validate_entities(text, entities)

    row = ScheduledMessage(
        chat_id=chat_id,
        user_id=user_id,
        text=text,
        text_entities=validated,
        media_id=media_id,
        reply_to_message_id=reply_to_message_id,
        client_message_id=uuid_mod.uuid4(),
        send_at=send_at,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


def scheduled_out(row: ScheduledMessage) -> dict:
    """Форма, совместимая с прежним message-подобным JSON (клиент декодирует
    ChatMessage и использует id/text/created_at; id — из пространства
    scheduled_messages, применим только к /messages/{id}/scheduled)."""
    return {
        "id": row.id,
        "chat_id": row.chat_id,
        "user_id": row.user_id,
        "text": row.text,
        "entities": row.text_entities,
        "media_id": str(row.media_id) if row.media_id else None,
        "reply_to_message_id": row.reply_to_message_id,
        "send_at": row.send_at,
        "created_at": row.created_at,
    }


async def list_scheduled(db: AsyncSession, user_id: int, chat_id: int) -> list[dict]:
    await check_user_in_chat(db, user_id, chat_id)
    rows = (await db.execute(
        select(ScheduledMessage)
        .where(ScheduledMessage.chat_id == chat_id, ScheduledMessage.user_id == user_id)
        .order_by(ScheduledMessage.send_at)
    )).scalars().all()
    return [scheduled_out(r) for r in rows]


async def cancel_scheduled(db: AsyncSession, user_id: int, scheduled_id: int) -> None:
    row = await db.get(ScheduledMessage, scheduled_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Scheduled message not found")
    if row.user_id != user_id:
        raise HTTPException(status_code=403, detail="Not your message")
    await db.delete(row)
    await db.commit()


async def deliver_due(db_maker, limit: int = 500) -> int:
    """Доставка «созревших» отложек. at-least-once + идемпотентный create_message.

    Каждая — в своей паре транзакций: claim FOR UPDATE SKIP LOCKED →
    create_message (свежий id, статусы, конверт, пуш; при ретрае дедуп по
    client_message_id) → delete строки. Если чат/права умерли (кик, блок) —
    строка удаляется с логом, очередь не блокируется.
    """
    from services.message import create_message

    delivered = 0
    for _ in range(limit):
        async with db_maker() as db:
            now = datetime.now(timezone.utc)
            row = (await db.execute(
                select(ScheduledMessage)
                .where(ScheduledMessage.send_at <= now)
                .order_by(ScheduledMessage.send_at)
                .with_for_update(skip_locked=True)
                .limit(1)
            )).scalars().first()
            if row is None:
                break

            row_id, cmid = row.id, row.client_message_id
            try:
                await create_message(
                    db,
                    row.user_id,
                    row.chat_id,
                    row.text,
                    client_message_id=cmid,
                    reply_to_message_id=row.reply_to_message_id,
                    media_id=row.media_id,
                    entities=row.text_entities,
                )
                delivered += 1
            except HTTPException as exc:
                # Права умерли между планированием и доставкой — дропаем
                logger.warning(
                    "Scheduled %d undeliverable (%s: %s) — dropped",
                    row_id, exc.status_code, exc.detail,
                )
                await db.rollback()
            except Exception:
                logger.exception("Scheduled %d delivery failed — will retry", row_id)
                await db.rollback()
                # Откладываем на минуту, чтобы не зациклиться на ядовитой строке
                retry = await db.get(ScheduledMessage, row_id)
                if retry is not None:
                    retry.send_at = datetime.now(timezone.utc) + timedelta(seconds=60)
                    await db.commit()
                continue

            # Строка отработана (доставлена или недоставляема) — удаляем
            gone = await db.get(ScheduledMessage, row_id)
            if gone is not None:
                await db.delete(gone)
                await db.commit()

    return delivered
