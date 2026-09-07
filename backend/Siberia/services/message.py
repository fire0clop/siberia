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


_ALLOWED_ENTITY_TYPES = {"bold", "italic", "underline", "strikethrough", "code", "pre", "spoiler"}


def validate_entities(text: str | None, entities) -> list[dict] | None:
    """Проверяет entities против текста. offset/length — UTF-16 code units.

    Клиенту нельзя верить: разметка за пределами текста ломала бы рендер
    у всех получателей.
    """
    if not entities:
        return None
    if not text:
        raise HTTPException(status_code=400, detail="Entities require text")
    if len(entities) > 100:
        raise HTTPException(status_code=400, detail="Too many entities")
    text_len_utf16 = len(text.encode("utf-16-le")) // 2
    out: list[dict] = []
    for e in entities:
        etype = e.type if hasattr(e, "type") else e.get("type")
        offset = e.offset if hasattr(e, "offset") else e.get("offset")
        length = e.length if hasattr(e, "length") else e.get("length")
        if etype not in _ALLOWED_ENTITY_TYPES:
            raise HTTPException(status_code=400, detail=f"Unknown entity type: {etype}")
        if not isinstance(offset, int) or not isinstance(length, int) \
                or offset < 0 or length < 1 or offset + length > text_len_utf16:
            raise HTTPException(status_code=400, detail="Entity out of text bounds")
        out.append({"type": etype, "offset": offset, "length": length})
    out.sort(key=lambda x: (x["offset"], x["length"]))
    return out


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
    entities=None,
    encrypted_payload: str | None = None,
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
    _is_secret = _chat_row is not None and _chat_row.type == _ChatType.secret
    if _chat_row is not None and _chat_row.type in (_ChatType.private, _ChatType.secret):
        _other = await db.execute(
            select(_ChatMember.user_id).where(
                _ChatMember.chat_id == chat_id,
                _ChatMember.user_id != user_id,
            )
        )
        _other_id = _other.scalars().first()
        if _other_id is not None:
            await check_not_blocked(db, user_id, _other_id)

    # E2E: в секретном чате принимаем ТОЛЬКО шифроблоб — никакого plaintext,
    # медиа, форвардов и отложенной отправки (v1). Вне секретного чата
    # encrypted_payload запрещён.
    if _is_secret:
        if not encrypted_payload:
            raise HTTPException(status_code=400, detail="Secret chats accept only encrypted_payload")
        if text is not None or media_id is not None or forward_message_id is not None or entities:
            raise HTTPException(status_code=400, detail="Secret chats: plaintext/media/forward not allowed")
    elif encrypted_payload is not None:
        raise HTTPException(status_code=400, detail="encrypted_payload is only for secret chats")

    await _validate_reply_in_chat(db, chat_id, reply_to_message_id)

    forwarded_from_message_id = None
    forwarded_from_user_id = None
    forwarded_from_chat_id = None

    if forward_message_id is not None:
        original = await db.get(Message, forward_message_id)
        if not original or original.deleted_at is not None:
            raise HTTPException(status_code=404, detail="Original message not found")
        if original.encrypted_payload is not None:
            raise HTTPException(status_code=400, detail="Cannot forward from a secret chat")
        await check_user_in_chat(db, user_id, original.chat_id)
        forwarded_from_message_id = original.id
        forwarded_from_user_id = original.user_id
        forwarded_from_chat_id = original.chat_id
        if text is None:
            text = original.text
            if entities is None:
                entities = original.text_entities  # разметка едет вместе с текстом
        if media_id is None and original.media_id is not None:
            media_id = original.media_id

    if media_id is not None:
        await _validate_media_access(db, media_id, user_id)

    mention_user_ids = None if _is_secret else (await _resolve_mentions(db, text, chat_id) or None)
    validated_entities = None if _is_secret else validate_entities(text, entities)

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
        text_entities=validated_entities,
        encrypted_payload=encrypted_payload,
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

    chat.last_message_id = message.id
    await _add_statuses_for_new_message(db, message.id, chat_id, user_id)

    _media_type = None
    if media_id:
        from models.media import Media as _Media
        _m = await db.get(_Media, media_id)
        _media_type = _m.type.value if _m else None

    payload = {
        "user_id": user_id,
        "text": text,
        "entities": validated_entities,
        "encrypted_payload": encrypted_payload,
        "media_id": str(media_id) if media_id else None,
        "media_type": _media_type,
        "client_message_id": str(client_message_id) if client_message_id else None,
        "reply_to_message_id": reply_to_message_id,
        "forwarded_from_message_id": forwarded_from_message_id,
        "mention_user_ids": mention_user_ids,
        "send_at": None,
        "created_at": message.created_at.isoformat() if message.created_at else None,
    }

    seq, _ = await log_update_on_locked_chat(
        db,
        chat,
        ChatUpdateEventType.message_new,
        message.id,
        payload,
    )

    await db.commit()
    await db.refresh(message)

    env = build_envelope(
        chat_id,
        seq,
        ChatUpdateEventType.message_new,
        message.id,
        payload,
    )
    await broadcast_envelope(chat_id, env)

    # Link preview: первая ссылка в тексте → асинхронная OG-задача в ARQ
    from services.link_preview import extract_first_url
    _preview_url = None if _is_secret else extract_first_url(text)
    if _preview_url:
        from utils.arq_pool import enqueue_job as _enqueue
        asyncio.create_task(_enqueue("fetch_link_preview", message.id, _preview_url))

    from services.push_dispatcher import dispatch_push_for_message
    from models.user import User as _User
    _sender = await db.get(_User, user_id)
    sender_nick = _sender.nickname if _sender else str(user_id)

    push_text = "🔒 Сообщение" if _is_secret else (text or ("📎 Media" if media_id else ""))
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
    entities=None,
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
        entities=entities,
    )
    return {
        "chat_id": chat.id,
        "message": message,
        "idempotent": idempotent,
    }


async def edit_message(
    db: AsyncSession, user_id: int, message_id: int, new_text: str, entities=None
) -> Message:
    from models.message_edit_history import MessageEditHistory

    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.user_id != user_id:
        raise HTTPException(status_code=403, detail="Can only edit own messages")
    if message.deleted_at is not None:
        raise HTTPException(status_code=400, detail="Message was deleted")
    if message.encrypted_payload is not None:
        raise HTTPException(status_code=403, detail="Secret messages cannot be edited (v1)")

    await check_user_in_chat(db, user_id, message.chat_id)

    chat = await lock_chat_row(db, message.chat_id)
    # Сохраняем предыдущий текст в history до изменения
    history_row = MessageEditHistory(
        message_id=message.id,
        text=message.text,
        edited_at=message.edited_at or message.created_at,
    )
    db.add(history_row)

    validated_entities = validate_entities(new_text, entities)
    message.text = new_text
    message.text_entities = validated_entities
    message.edited_at = datetime.now(timezone.utc)
    await db.flush()

    seq, _ = await log_update_on_locked_chat(
        db,
        chat,
        ChatUpdateEventType.message_edit,
        message.id,
        {"text": new_text, "entities": validated_entities,
         "edited_at": message.edited_at.isoformat()},
    )

    await db.commit()
    await db.refresh(message)

    env = build_envelope(
        message.chat_id,
        seq,
        ChatUpdateEventType.message_edit,
        message.id,
        {"text": new_text, "entities": validated_entities,
         "edited_at": message.edited_at.isoformat()},
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
