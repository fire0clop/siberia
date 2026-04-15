from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import desc, func, and_

from models.message import Message
from models.message_status import MessageStatus, MessageStatusEnum
from models.message_reaction import MessageReaction
from models.media import Media


async def _get_reactions_map(db: AsyncSession, message_ids: list[int]) -> dict[int, dict[str, int]]:
    if not message_ids:
        return {}
    stmt = (
        select(MessageReaction.message_id, MessageReaction.emoji, func.count(MessageReaction.id))
        .where(MessageReaction.message_id.in_(message_ids))
        .group_by(MessageReaction.message_id, MessageReaction.emoji)
    )
    result = await db.execute(stmt)
    reactions: dict[int, dict[str, int]] = {}
    for mid, emoji, count in result.all():
        reactions.setdefault(mid, {})[emoji] = count
    return reactions


async def get_messages_with_status(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
    limit: int,
    offset: int = 0,
    include_scheduled: bool = False,
    before_id: int | None = None,
    after_id: int | None = None,
):
    now = datetime.now(timezone.utc)
    base_filter = [Message.chat_id == chat_id]
    if not include_scheduled:
        base_filter.append(
            (Message.send_at.is_(None)) | (Message.send_at <= now)
        )
    if before_id is not None:
        base_filter.append(Message.id < before_id)
    if after_id is not None:
        base_filter.append(Message.id > after_id)

    order = Message.id.asc() if after_id is not None else desc(Message.id)

    stmt = (
        select(
            Message,
            MessageStatus.status,
            Media,
        )
        .outerjoin(
            MessageStatus,
            and_(
                MessageStatus.message_id == Message.id,
                MessageStatus.user_id == user_id,
            ),
        )
        .outerjoin(Media, Media.id == Message.media_id)
        .where(*base_filter)
        .order_by(order)
        .limit(limit)
        .offset(offset if before_id is None and after_id is None else 0)
    )

    result = await db.execute(stmt)
    raw_rows = result.all()

    if not raw_rows:
        return []

    message_ids = [msg.id for msg, _, _ in raw_rows]
    reactions_map = await _get_reactions_map(db, message_ids)

    rows = []
    for msg, status, media in raw_rows:
        deleted = msg.deleted_at is not None
        media_out = None
        if media:
            media_out = {
                "id": str(media.id),
                "type": media.type.value,
                "mime_type": media.mime_type,
                "size_bytes": media.size_bytes,
                "duration_sec": media.duration_sec,
                "width": media.width,
                "height": media.height,
                "original_name": media.original_name,
            }
        rows.append(
            {
                "id": msg.id,
                "chat_id": msg.chat_id,
                "user_id": msg.user_id,
                "type": msg.type.value if msg.type else "text",
                "text": msg.text if not deleted else None,
                "media_id": str(msg.media_id) if msg.media_id else None,
                "media_type": media.type.value if media else None,
                "media": media_out,
                "created_at": msg.created_at,
                "edited_at": msg.edited_at,
                "deleted_at": msg.deleted_at,
                "deleted": deleted,
                "reply_to_message_id": msg.reply_to_message_id,
                "forwarded_from_message_id": msg.forwarded_from_message_id,
                "forwarded_from_user_id": msg.forwarded_from_user_id,
                "forwarded_from_chat_id": msg.forwarded_from_chat_id,
                "mention_user_ids": msg.mention_user_ids,
                "send_at": msg.send_at,
                "reactions": reactions_map.get(msg.id) or None,
                "client_message_id": str(msg.client_message_id)
                if msg.client_message_id
                else None,
                "status": status.value if status is not None else None,
            }
        )
    return rows


async def get_messages_around(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
    pivot_id: int,
    half: int = 25,
) -> list:
    """Return up to `half` messages before + pivot + up to `half` messages after."""
    now = datetime.now(timezone.utc)

    before_stmt = (
        select(Message, MessageStatus.status, Media)
        .outerjoin(
            MessageStatus,
            and_(MessageStatus.message_id == Message.id, MessageStatus.user_id == user_id),
        )
        .outerjoin(Media, Media.id == Message.media_id)
        .where(
            Message.chat_id == chat_id,
            Message.id < pivot_id,
            (Message.send_at.is_(None)) | (Message.send_at <= now),
        )
        .order_by(Message.id.desc())
        .limit(half)
    )
    after_stmt = (
        select(Message, MessageStatus.status, Media)
        .outerjoin(
            MessageStatus,
            and_(MessageStatus.message_id == Message.id, MessageStatus.user_id == user_id),
        )
        .outerjoin(Media, Media.id == Message.media_id)
        .where(
            Message.chat_id == chat_id,
            Message.id >= pivot_id,
            (Message.send_at.is_(None)) | (Message.send_at <= now),
        )
        .order_by(Message.id.asc())
        .limit(half + 1)
    )

    before_res = await db.execute(before_stmt)
    after_res = await db.execute(after_stmt)

    before_rows = list(reversed(before_res.all()))
    after_rows = after_res.all()

    all_rows = before_rows + after_rows
    if not all_rows:
        return []

    message_ids = [msg.id for msg, _, _ in all_rows]
    reactions_map = await _get_reactions_map(db, message_ids)

    rows = []
    for msg, status, media in all_rows:
        deleted = msg.deleted_at is not None
        media_out = None
        if media:
            media_out = {
                "id": str(media.id), "type": media.type.value,
                "mime_type": media.mime_type, "size_bytes": media.size_bytes,
                "duration_sec": media.duration_sec, "width": media.width,
                "height": media.height, "original_name": media.original_name,
            }
        rows.append({
            "id": msg.id, "chat_id": msg.chat_id, "user_id": msg.user_id,
            "type": msg.type.value if msg.type else "text",
            "text": msg.text if not deleted else None,
            "media_id": str(msg.media_id) if msg.media_id else None,
            "media_type": media.type.value if media else None,
            "media": media_out,
            "created_at": msg.created_at, "edited_at": msg.edited_at,
            "deleted_at": msg.deleted_at, "deleted": deleted,
            "reply_to_message_id": msg.reply_to_message_id,
            "forwarded_from_message_id": msg.forwarded_from_message_id,
            "forwarded_from_user_id": msg.forwarded_from_user_id,
            "forwarded_from_chat_id": msg.forwarded_from_chat_id,
            "mention_user_ids": msg.mention_user_ids,
            "send_at": msg.send_at,
            "reactions": reactions_map.get(msg.id) or None,
            "client_message_id": str(msg.client_message_id) if msg.client_message_id else None,
            "status": status.value if status is not None else None,
            "is_pivot": msg.id == pivot_id,
        })
    return rows


async def get_unread_count(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
):
    stmt = (
        select(func.count(Message.id))
        .outerjoin(
            MessageStatus,
            and_(
                MessageStatus.message_id == Message.id,
                MessageStatus.user_id == user_id,
            ),
        )
        .where(
            Message.chat_id == chat_id,
            Message.deleted_at.is_(None),
            (MessageStatus.status != MessageStatusEnum.read)
            | (MessageStatus.status.is_(None)),
        )
    )

    result = await db.execute(stmt)
    return result.scalar()
