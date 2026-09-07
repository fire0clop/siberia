from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import delete as sa_delete

from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError

from models.message import Message
from models.message_status import MessageStatus, MessageStatusEnum
from models.chat import Chat
from models.chat_member import ChatMember
from models.chat_update import ChatUpdateEventType

from services.chat import check_user_in_chat, get_private_chat_between, _check_can_message
from services.sync_engine import (
    lock_chat_row,
    log_update_on_locked_chat,
    build_envelope,
    broadcast_envelope,
)


async def _validate_reply_in_chat(
    db: AsyncSession, chat_id: int, reply_to_message_id: int | None
):
    if reply_to_message_id is None:
        return
    parent = await db.get(Message, reply_to_message_id)
    if not parent or parent.chat_id != chat_id:
        raise HTTPException(status_code=400, detail="Invalid reply_to_message_id")


async def build_message_new_payload(db: AsyncSession, message: Message) -> dict:
    """Единый payload для конверта message_new — и в live-отправке, и в воркере.

    Раньше воркер слал payload={} для scheduled-сообщений, и клиент показывал
    пустое сообщение (H-6). Теперь обе ветки строят одинаковую нагрузку.
    """
    media_type = None
    if message.media_id:
        from models.media import Media as _Media
        m = await db.get(_Media, message.media_id)
        media_type = m.type.value if m else None
    return {
        "user_id": message.user_id,
        "text": message.text,
        "media_id": str(message.media_id) if message.media_id else None,
        "media_type": media_type,
        "client_message_id": str(message.client_message_id) if message.client_message_id else None,
        "reply_to_message_id": message.reply_to_message_id,
        "forwarded_from_message_id": message.forwarded_from_message_id,
        "mention_user_ids": message.mention_user_ids,
        "send_at": None,
        "created_at": message.created_at.isoformat() if message.created_at else None,
    }


async def _add_statuses_for_new_message(
    db: AsyncSession, message_id: int, chat_id: int, sender_id: int
):
    result = await db.execute(
        select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
    )
    for (uid,) in result.all():
        status = (
            MessageStatusEnum.read if uid == sender_id else MessageStatusEnum.sent
        )
        db.add(
            MessageStatus(
                message_id=message_id,
                user_id=uid,
                status=status,
            )
        )


async def get_or_create_private_chat(db: AsyncSession, sender_id: int, recipient_id: int):
    from services.chat import lock_private_pair

    chat = await get_private_chat_between(db, sender_id, recipient_id)
    if chat:
        return chat

    # New chat: enforce messaging privacy + block check.
    # ВАЖНО: _check_can_message коммитит (через _get_privacy), что сняло бы
    # advisory-lock, поэтому лок берём ПОСЛЕ него — и держим непрерывно до
    # commit создания чата. Конкурентные «первые сообщения» иначе плодили дубли.
    await _check_can_message(db, sender_id, recipient_id)

    await lock_private_pair(db, sender_id, recipient_id)
    # Повторная проверка под локом: пока мы ждали, DM мог создать другой запрос
    chat = await get_private_chat_between(db, sender_id, recipient_id)
    if chat:
        return chat

    chat = Chat(title=None)
    db.add(chat)
    await db.flush()

    db.add_all(
        [
            ChatMember(chat_id=chat.id, user_id=sender_id),
            ChatMember(chat_id=chat.id, user_id=recipient_id),
        ]
    )

    await db.commit()
    await db.refresh(chat)
    return chat


async def _validate_media_access(
    db: AsyncSession, media_id: UUID, user_id: int
) -> None:
    """Allow using media_id if user uploaded it OR was in a chat where it was sent (forwarding)."""
    from models.media import Media
    from sqlalchemy import exists
    media = await db.get(Media, media_id)
    if not media:
        raise HTTPException(status_code=404, detail="Media not found")
    if media.uploader_id == user_id:
        return
    # Allow reuse if user has seen this media in any chat they're a member of
    stmt = select(
        exists(
            select(Message.id)
            .join(ChatMember, ChatMember.chat_id == Message.chat_id)
            .where(
                Message.media_id == media_id,
                ChatMember.user_id == user_id,
            )
        )
    )
    result = await db.execute(stmt)
    if not result.scalar():
        raise HTTPException(status_code=403, detail="Media not accessible")


async def _resolve_mentions(db: AsyncSession, text: str | None, chat_id: int) -> list[int]:
    """Extract @username mentions and resolve to user IDs within the chat."""
    if not text:
        return []
    import re
    from models.user import User
    from models.chat_member import ChatMember
    handles = re.findall(r"@(\w{3,32})", text)
    if not handles:
        return []
    from sqlalchemy import func as sqlfunc
    # @handle — это User.username (уникальный, [a-zA-Z0-9_]); раньше матчился
    # nickname (произвольная строка с пробелами) — упоминания не работали.
    result = await db.execute(
        select(User.id)
        .join(ChatMember, ChatMember.user_id == User.id)
        .where(
            ChatMember.chat_id == chat_id,
            User.username.isnot(None),
            sqlfunc.lower(User.username).in_([h.lower() for h in handles]),
        )
    )
    return [row[0] for row in result.all()]


async def create_message(
    db: AsyncSession,
    user_id: int,
    chat_id: int,
    text: str | None,
    client_message_id: UUID | None = None,
    reply_to_message_id: int | None = None,
    media_id: UUID | None = None,
    forward_message_id: int | None = None,
    send_at=None,
) -> tuple[Message, bool]:
    await check_user_in_chat(db, user_id, chat_id)

    # Channels: only owner/admin can post
    from models.chat_member import ChatMember as _ChatMember, MemberRole as _MemberRole
    _chat_type_check = await db.execute(
        select(_ChatMember).where(_ChatMember.chat_id == chat_id, _ChatMember.user_id == user_id)
    )
    _member = _chat_type_check.scalars().first()
    if _member and _member.role == _MemberRole.subscriber:
        raise HTTPException(status_code=403, detail="Subscribers cannot post in channels")

    # Private chats: blocking must also stop messages in an *existing* DM,
    # not only prevent creating a new one (block check used to live solely
    # in _check_can_message, which runs only on chat creation).
    from models.chat import ChatType as _ChatType
    from services.block_service import check_not_blocked
    _chat_row = await db.get(Chat, chat_id)
    if _chat_row is not None and _chat_row.type == _ChatType.private:
        _other = await db.execute(
            select(_ChatMember.user_id).where(
                _ChatMember.chat_id == chat_id,
                _ChatMember.user_id != user_id,
            )
        )
        _other_id = _other.scalars().first()
        if _other_id is not None:
            await check_not_blocked(db, user_id, _other_id)

    await _validate_reply_in_chat(db, chat_id, reply_to_message_id)

    forwarded_from_message_id = None
    forwarded_from_user_id = None
    forwarded_from_chat_id = None

    if forward_message_id is not None:
        original = await db.get(Message, forward_message_id)
        if not original or original.deleted_at is not None:
            raise HTTPException(status_code=404, detail="Original message not found")
        await check_user_in_chat(db, user_id, original.chat_id)
        forwarded_from_message_id = original.id
        forwarded_from_user_id = original.user_id
        forwarded_from_chat_id = original.chat_id
        if text is None:
            text = original.text
        if media_id is None and original.media_id is not None:
            media_id = original.media_id

    if media_id is not None:
        await _validate_media_access(db, media_id, user_id)

    mention_user_ids = await _resolve_mentions(db, text, chat_id) or None

    chat = await lock_chat_row(db, chat_id)

    if client_message_id is not None:
        r = await db.execute(
            select(Message).where(
                Message.chat_id == chat_id,
                Message.user_id == user_id,
                Message.client_message_id == client_message_id,
            )
        )
        existing = r.scalar_one_or_none()
        if existing:
            await db.commit()
            return existing, True

    message = Message(
        chat_id=chat_id,
        user_id=user_id,
        text=text,
        media_id=media_id,
        client_message_id=client_message_id,
        reply_to_message_id=reply_to_message_id,
        forwarded_from_message_id=forwarded_from_message_id,
        forwarded_from_user_id=forwarded_from_user_id,
        forwarded_from_chat_id=forwarded_from_chat_id,
        mention_user_ids=mention_user_ids,
        send_at=send_at,
    )
    db.add(message)
    try:
        await db.flush()
    except IntegrityError:
        await db.rollback()
        if client_message_id is None:
            raise HTTPException(
                status_code=409,
                detail="Message persistence conflict",
            ) from None
        r = await db.execute(
            select(Message).where(
                Message.chat_id == chat_id,
                Message.user_id == user_id,
                Message.client_message_id == client_message_id,
            )
        )
        dup = r.scalar_one_or_none()
        if dup is not None:
            return dup, True
        raise HTTPException(
            status_code=409,
            detail="Message conflict (duplicate client_message_id)",
        ) from None

    is_scheduled = send_at is not None

    if not is_scheduled:
        chat.last_message_id = message.id
        # Статусы (unread) создаём ТОЛЬКО для уже отправленных сообщений.
        # Раньше их получали и scheduled-сообщения → они считались непрочитанными
        # в badge/списке чатов ещё до отправки (H-6). Для scheduled статусы
        # создаёт воркер в момент доставки.
        await _add_statuses_for_new_message(db, message.id, chat_id, user_id)

    _media_type = None
    if media_id:
        from models.media import Media as _Media
        _m = await db.get(_Media, media_id)
        _media_type = _m.type.value if _m else None

    payload = {
        "user_id": user_id,
        "text": text,
        "media_id": str(media_id) if media_id else None,
        "media_type": _media_type,
        "client_message_id": str(client_message_id) if client_message_id else None,
        "reply_to_message_id": reply_to_message_id,
        "forwarded_from_message_id": forwarded_from_message_id,
        "mention_user_ids": mention_user_ids,
        "send_at": send_at.isoformat() if send_at else None,
        "created_at": message.created_at.isoformat() if message.created_at else None,
    }

    if not is_scheduled:
        seq, _ = await log_update_on_locked_chat(
            db,
            chat,
            ChatUpdateEventType.message_new,
            message.id,
            payload,
        )

    await db.commit()
    await db.refresh(message)

    if not is_scheduled:
        env = build_envelope(
            chat_id,
            seq,
            ChatUpdateEventType.message_new,
            message.id,
            payload,
        )
        await broadcast_envelope(chat_id, env)

        from services.push_dispatcher import dispatch_push_for_message
        from models.user import User as _User
        _sender = await db.get(_User, user_id)
        sender_nick = _sender.nickname if _sender else str(user_id)

        push_text = text or ("📎 Media" if media_id else "")
        asyncio.create_task(
            dispatch_push_for_message(
                chat_id=chat_id,
                message_id=message.id,
                sender_id=user_id,
                sender_nickname=sender_nick,
                message_text=push_text,
                mention_user_ids=mention_user_ids,
            )
        )

    return message, False


async def create_message_auto(
    db: AsyncSession,
    sender_id: int,
    target_user_id: int,
    text: str | None,
    client_message_id: UUID | None = None,
    reply_to_message_id: int | None = None,
    media_id: UUID | None = None,
) -> dict[str, Any]:
    chat = await get_or_create_private_chat(db, sender_id, target_user_id)
    message, idempotent = await create_message(
        db,
        sender_id,
        chat.id,
        text,
        client_message_id=client_message_id,
        reply_to_message_id=reply_to_message_id,
        media_id=media_id,
        forward_message_id=None,
        send_at=None,
    )
    return {
        "chat_id": chat.id,
        "message": message,
        "idempotent": idempotent,
    }


async def edit_message(
    db: AsyncSession, user_id: int, message_id: int, new_text: str
) -> Message:
    from models.message_edit_history import MessageEditHistory

    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.user_id != user_id:
        raise HTTPException(status_code=403, detail="Can only edit own messages")
    if message.deleted_at is not None:
        raise HTTPException(status_code=400, detail="Message was deleted")

    await check_user_in_chat(db, user_id, message.chat_id)

    chat = await lock_chat_row(db, message.chat_id)
    # Сохраняем предыдущий текст в history до изменения
    history_row = MessageEditHistory(
        message_id=message.id,
        text=message.text,
        edited_at=message.edited_at or message.created_at,
    )
    db.add(history_row)

    message.text = new_text
    message.edited_at = datetime.now(timezone.utc)
    await db.flush()

    seq, _ = await log_update_on_locked_chat(
        db,
        chat,
        ChatUpdateEventType.message_edit,
        message.id,
        {"text": new_text, "edited_at": message.edited_at.isoformat()},
    )

    await db.commit()
    await db.refresh(message)

    env = build_envelope(
        message.chat_id,
        seq,
        ChatUpdateEventType.message_edit,
        message.id,
        {"text": new_text, "edited_at": message.edited_at.isoformat()},
    )
    await broadcast_envelope(message.chat_id, env)

    return message


async def soft_delete_message(db: AsyncSession, user_id: int, message_id: int) -> None:
    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.deleted_at is not None:
        return

    await check_user_in_chat(db, user_id, message.chat_id)

    if message.user_id != user_id:
        # Модерация: owner/admin группы или канала может удалять чужие
        # сообщения — раньше удаление было строго авторским.
        from models.chat_member import ChatMember as _CM, MemberRole as _MR
        actor = await db.execute(
            select(_CM).where(_CM.chat_id == message.chat_id, _CM.user_id == user_id)
        )
        actor_member = actor.scalars().first()
        if actor_member is None or actor_member.role not in (_MR.owner, _MR.admin):
            raise HTTPException(status_code=403, detail="Can only delete own messages")

    chat = await lock_chat_row(db, message.chat_id)
    message.deleted_at = datetime.now(timezone.utc)
    message.text = None

    # Чистим статусы — удалённое сообщение больше не нужно отслеживать
    await db.execute(
        sa_delete(MessageStatus).where(MessageStatus.message_id == message_id)
    )
    await db.flush()

    seq, _ = await log_update_on_locked_chat(
        db,
        chat,
        ChatUpdateEventType.message_delete,
        message.id,
        None,
    )

    await db.commit()

    env = build_envelope(
        message.chat_id,
        seq,
        ChatUpdateEventType.message_delete,
        message.id,
        {},
    )
    await broadcast_envelope(message.chat_id, env)


async def mark_read(db: AsyncSession, message_id: int, user_id: int) -> None:
    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")

    await check_user_in_chat(db, user_id, message.chat_id)

    stmt = select(MessageStatus).where(
        MessageStatus.message_id == message_id,
        MessageStatus.user_id == user_id,
    )
    result = await db.execute(stmt)
    status = result.scalars().first()

    if status:
        if status.status == MessageStatusEnum.read:
            return
        status.status = MessageStatusEnum.read
    else:
        db.add(
            MessageStatus(
                message_id=message_id,
                user_id=user_id,
                status=MessageStatusEnum.read,
            )
        )

    chat = await lock_chat_row(db, message.chat_id)
    seq, _ = await log_update_on_locked_chat(
        db,
        chat,
        ChatUpdateEventType.read_receipt,
        message_id,
        {"reader_id": user_id, "message_id": message_id},
    )

    await db.commit()

    env = build_envelope(
        message.chat_id,
        seq,
        ChatUpdateEventType.read_receipt,
        message_id,
        {"reader_id": user_id, "message_id": message_id},
    )
    await broadcast_envelope(message.chat_id, env)
