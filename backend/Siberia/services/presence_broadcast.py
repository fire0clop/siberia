"""Рассылка событий presence_change друзьям и собеседникам по DM-чатам.

Вызывается из routes/ws.py при первом коннекте/последнем дисконнекте пользователя.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

from sqlalchemy import or_, and_
from sqlalchemy.future import select

from db import async_session_maker
from models.user import User
from models.friend import Friend, FriendStatus
from models.chat import Chat, ChatType
from models.chat_member import ChatMember
from utils.redis import publish

logger = logging.getLogger(__name__)


async def _interested_user_ids(user_id: int) -> list[int]:
    """Возвращает уникальный набор user_id, который должен узнать про presence-изменение:
    - все друзья (Friend.status == accepted)
    - все участники приватных чатов (DM) с этим user_id
    """
    ids: set[int] = set()
    async with async_session_maker() as db:
        # 1) Друзья
        friend_rows = await db.execute(
            select(Friend.requester_id, Friend.addressee_id).where(
                Friend.status == FriendStatus.accepted,
                or_(
                    Friend.requester_id == user_id,
                    Friend.addressee_id == user_id,
                ),
            )
        )
        for req_id, addr_id in friend_rows.all():
            ids.add(addr_id if req_id == user_id else req_id)

        # 2) Партнёры по DM (приватные чаты — ChatType.private)
        my_dm_chats = (
            select(ChatMember.chat_id)
            .join(Chat, Chat.id == ChatMember.chat_id)
            .where(
                ChatMember.user_id == user_id,
                Chat.type == ChatType.private,
            )
        )
        partners = await db.execute(
            select(ChatMember.user_id)
            .where(
                ChatMember.chat_id.in_(my_dm_chats),
                ChatMember.user_id != user_id,
            )
            .distinct()
        )
        for (pid,) in partners.all():
            ids.add(pid)

    ids.discard(user_id)
    return list(ids)


async def broadcast_presence(user_id: int, is_online: bool, last_seen_at: datetime | None = None) -> None:
    """Публикует событие presence_change в `user:{recipient}` каналы Redis."""
    try:
        recipients = await _interested_user_ids(user_id)
    except Exception as exc:
        logger.exception("Failed to fetch presence recipients for %s: %s", user_id, exc)
        return
    if not recipients:
        return

    payload = {
        "v": 1,
        "event": "presence_change",
        "type": "presence_change",  # для совместимости с iOS handlers, которые читают "type"
        "payload": {
            "user_id": user_id,
            "online": is_online,
            "last_seen_at": (last_seen_at or datetime.now(timezone.utc)).isoformat(),
        },
    }
    raw = json.dumps(payload)
    for rid in recipients:
        try:
            await publish(f"user:{rid}", raw)
        except Exception as exc:
            logger.exception("Failed to publish presence to user:%s — %s", rid, exc)
