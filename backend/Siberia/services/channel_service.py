"""Channel management service."""
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import func

from models.chat import Chat, ChatType
from models.chat_member import ChatMember, MemberRole
from models.user import User
from models.chat_update import ChatUpdateEventType
from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope

_ROLE_RANK = {
    MemberRole.owner: 3,
    MemberRole.admin: 2,
    MemberRole.member: 1,
    MemberRole.subscriber: 0,
}


async def _get_channel(db: AsyncSession, channel_id: int) -> Chat:
    chat = await db.get(Chat, channel_id)
    if not chat or chat.type != ChatType.channel:
        raise HTTPException(status_code=404, detail="Channel not found")
    return chat


async def _get_member(db: AsyncSession, channel_id: int, user_id: int) -> ChatMember | None:
    result = await db.execute(
        select(ChatMember).where(
            ChatMember.chat_id == channel_id,
            ChatMember.user_id == user_id,
        )
    )
    return result.scalars().first()


async def create_channel(
    db: AsyncSession,
    creator_id: int,
    title: str,
    description: str | None,
    is_public: bool,
) -> Chat:
    chat = Chat(
        type=ChatType.channel,
        title=title,
        description=description,
        is_public=is_public,
        subscribers_count=1,
    )
    db.add(chat)
    await db.flush()

    db.add(ChatMember(
        chat_id=chat.id,
        user_id=creator_id,
        role=MemberRole.owner,
        joined_at=datetime.now(timezone.utc),
    ))
    await db.commit()
    await db.refresh(chat)
    return chat


async def subscribe_channel(db: AsyncSession, channel_id: int, user_id: int) -> Chat:
    chat = await _get_channel(db, channel_id)

    existing = await _get_member(db, channel_id, user_id)
    if existing:
        return chat  # already subscribed, idempotent

    if not chat.is_public:
        raise HTTPException(status_code=403, detail="This channel is private. Use an invite link to join.")

    db.add(ChatMember(
        chat_id=channel_id,
        user_id=user_id,
        role=MemberRole.subscriber,
        joined_at=datetime.now(timezone.utc),
    ))
    chat.subscribers_count = (chat.subscribers_count or 0) + 1
    await db.flush()

    locked_chat = await lock_chat_row(db, channel_id)
    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_added, None,
        {"added_user_ids": [user_id]},
    )
    await db.commit()
    await db.refresh(locked_chat)

    env = build_envelope(channel_id, seq, ChatUpdateEventType.member_added, None,
                         {"added_user_ids": [user_id]})
    await broadcast_envelope(channel_id, env)
    return locked_chat


async def subscribe_by_invite(db: AsyncSession, slug: str, user_id: int) -> Chat:
    result = await db.execute(select(Chat).where(Chat.invite_link == slug))
    chat = result.scalars().first()
    if not chat or chat.type != ChatType.channel:
        raise HTTPException(status_code=404, detail="Invalid or expired invite link")

    existing = await _get_member(db, chat.id, user_id)
    if existing:
        return chat

    db.add(ChatMember(
        chat_id=chat.id,
        user_id=user_id,
        role=MemberRole.subscriber,
        joined_at=datetime.now(timezone.utc),
    ))
    chat.subscribers_count = (chat.subscribers_count or 0) + 1
    await db.commit()
    await db.refresh(chat)
    return chat


async def unsubscribe_channel(db: AsyncSession, channel_id: int, user_id: int) -> None:
    chat = await _get_channel(db, channel_id)
    member = await _get_member(db, channel_id, user_id)

    if not member:
        return  # not a member, idempotent

    if member.role == MemberRole.owner:
        raise HTTPException(status_code=400, detail="Owner cannot unsubscribe. Transfer ownership first.")

    await db.delete(member)
    if chat.subscribers_count and chat.subscribers_count > 0:
        chat.subscribers_count -= 1
    await db.flush()

    locked_chat = await lock_chat_row(db, channel_id)
    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_left, None,
        {"user_id": user_id},
    )
    await db.commit()

    env = build_envelope(channel_id, seq, ChatUpdateEventType.member_left, None,
                         {"user_id": user_id})
    await broadcast_envelope(channel_id, env)


async def update_channel(
    db: AsyncSession,
    channel_id: int,
    actor_id: int,
    title: str | None,
    description: str | None,
    is_public: bool | None,
    avatar_media_id: str | None,
) -> Chat:
    member = await _get_member(db, channel_id, actor_id)
    if not member or _ROLE_RANK[member.role] < _ROLE_RANK[MemberRole.admin]:
        raise HTTPException(status_code=403, detail="Insufficient permissions")

    locked_chat = await lock_chat_row(db, channel_id)
    if locked_chat.type != ChatType.channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    if title is not None:
        locked_chat.title = title
    if description is not None:
        locked_chat.description = description
    if is_public is not None:
        locked_chat.is_public = is_public
    if avatar_media_id is not None:
        import uuid as _uuid
        locked_chat.avatar_media_id = _uuid.UUID(avatar_media_id)

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.chat_updated, None,
        {"title": title, "description": description, "is_public": is_public},
    )
    await db.commit()
    await db.refresh(locked_chat)

    env = build_envelope(channel_id, seq, ChatUpdateEventType.chat_updated, None,
                         {"title": title, "description": description})
    await broadcast_envelope(channel_id, env)
    return locked_chat


async def search_channels(db: AsyncSession, query: str, limit: int) -> list[Chat]:
    like = f"%{query}%"
    result = await db.execute(
        select(Chat)
        .where(Chat.type == ChatType.channel, Chat.is_public.is_(True), Chat.title.ilike(like))
        .order_by(Chat.subscribers_count.desc())
        .limit(limit)
    )
    return result.scalars().all()


async def get_channel_for_user(db: AsyncSession, channel_id: int, user_id: int) -> Chat:
    """Return channel if public or if user is a member."""
    chat = await _get_channel(db, channel_id)
    if chat.is_public:
        return chat
    member = await _get_member(db, channel_id, user_id)
    if not member:
        raise HTTPException(status_code=403, detail="This channel is private")
    return chat
