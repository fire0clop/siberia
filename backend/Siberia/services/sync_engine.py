from __future__ import annotations

import json
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from db import async_session_maker
from models.chat import Chat
from models.chat_update import ChatUpdate, ChatUpdateEventType
from services.chat_members import get_chat_member_user_ids
from utils.redis import publish


async def lock_chat_row(db: AsyncSession, chat_id: int) -> Chat:
    result = await db.execute(
        select(Chat).where(Chat.id == chat_id).with_for_update()
    )
    return result.scalar_one()


async def log_update_on_locked_chat(
    db: AsyncSession,
    chat: Chat,
    event_type: ChatUpdateEventType,
    message_id: int | None,
    payload: dict[str, Any] | None,
) -> tuple[int, ChatUpdate]:
    """ВАЖНО: chat должен быть получен через `lock_chat_row()` в той же транзакции.

    Без блокировки на уровне строки два конкурентных коммита могут
    выдать одинаковый sync_seq → клиент пропустит событие.
    """
    if chat is None:
        raise RuntimeError("log_update_on_locked_chat called with chat=None")
    chat.sync_seq = int(chat.sync_seq or 0) + 1
    seq = chat.sync_seq
    upd = ChatUpdate(
        chat_id=chat.id,
        seq=seq,
        event_type=event_type,
        message_id=message_id,
        payload=payload,
    )
    db.add(upd)
    await db.flush()
    return seq, upd


def build_envelope(
    chat_id: int,
    seq: int,
    event: ChatUpdateEventType,
    message_id: int | None,
    payload: dict[str, Any] | None,
) -> dict[str, Any]:
    return {
        "v": 1,
        "chat_id": chat_id,
        "seq": seq,
        "event": event.value,
        "message_id": message_id,
        "payload": payload or {},
    }


async def broadcast_envelope(chat_id: int, envelope: dict[str, Any]) -> None:
    raw = json.dumps(envelope, default=_json_default)
    await publish(f"chat:{chat_id}", raw)
    async with async_session_maker() as db:
        user_ids = await get_chat_member_user_ids(db, chat_id)
    for uid in user_ids:
        await publish(f"user:{uid}", raw)


def _json_default(obj: Any) -> Any:
    if isinstance(obj, UUID):
        return str(obj)
    raise TypeError(f"Object of type {type(obj)} is not JSON serializable")
