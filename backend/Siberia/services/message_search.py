from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import func, and_, or_, not_, exists

from models.message import Message
from models.chat import Chat
from models.chat_member import ChatMember
from models.user import User
from models.block import Block

from services.chat import check_user_in_chat


async def search_messages(
    db: AsyncSession,
    user_id: int,
    query: str,
    chat_id: int | None,
    limit: int,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
):
    if chat_id is not None:
        await check_user_in_chat(db, user_id, chat_id)

    member_subq = select(ChatMember.chat_id).where(ChatMember.user_id == user_id)

    ts = func.to_tsvector("simple", func.coalesce(Message.text, ""))
    q_ts = func.plainto_tsquery("simple", query)

    filters = [
        Message.chat_id.in_(member_subq),
        Message.deleted_at.is_(None),
        ts.op("@@")(q_ts),
    ]

    if chat_id is not None:
        filters.append(Message.chat_id == chat_id)
    if date_from is not None:
        filters.append(Message.created_at >= date_from)
    if date_to is not None:
        filters.append(Message.created_at <= date_to)

    stmt = (
        select(Message)
        .where(*filters)
        .order_by(Message.id.desc())
        .limit(limit)
    )

    result = await db.execute(stmt)
    messages = result.scalars().all()

    return [
        {
            "id": m.id,
            "chat_id": m.chat_id,
            "user_id": m.user_id,
            "text": m.text,
            "created_at": m.created_at,
            "edited_at": m.edited_at,
        }
        for m in messages
    ]


async def global_search(
    db: AsyncSession,
    user_id: int,
    query: str,
    limit: int = 20,
) -> dict:
    """Search users, messages, and chats simultaneously."""
    like = f"%{query}%"
    bare_like = f"%{query.lstrip('@')}%"

    # Users — not deleted, not blocked
    block_filter = not_(
        exists(
            select(Block.id).where(
                or_(
                    and_(Block.blocker_id == user_id, Block.blocked_id == User.id),
                    and_(Block.blocker_id == User.id, Block.blocked_id == user_id),
                )
            )
        )
    )
    users_stmt = (
        select(User)
        .where(
            User.deleted_at.is_(None),
            User.id != user_id,
            block_filter,
            or_(User.nickname.ilike(like), User.username.ilike(bare_like)),
        )
        .limit(limit)
    )
    users_result = await db.execute(users_stmt)
    users = users_result.scalars().all()

    # Messages — full-text, only accessible chats
    member_subq = select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
    ts = func.to_tsvector("simple", func.coalesce(Message.text, ""))
    q_ts = func.plainto_tsquery("simple", query)
    msgs_stmt = (
        select(Message)
        .where(
            Message.chat_id.in_(member_subq),
            Message.deleted_at.is_(None),
            ts.op("@@")(q_ts),
        )
        .order_by(Message.id.desc())
        .limit(limit)
    )
    msgs_result = await db.execute(msgs_stmt)
    messages = msgs_result.scalars().all()

    # Chats (groups) — only ones the user is a member of, by title
    chats_stmt = (
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(
            ChatMember.user_id == user_id,
            Chat.title.ilike(like),
        )
        .limit(limit)
    )
    chats_result = await db.execute(chats_stmt)
    chats = chats_result.scalars().all()

    return {
        "users": [
            {"id": u.id, "nickname": u.nickname, "username": u.username,
             "avatar_media_id": str(u.avatar_media_id) if u.avatar_media_id else None}
            for u in users
        ],
        "messages": [
            {"id": m.id, "chat_id": m.chat_id, "user_id": m.user_id,
             "text": m.text, "created_at": m.created_at}
            for m in messages
        ],
        "chats": [
            {"id": c.id, "type": c.type, "title": c.title,
             "avatar_media_id": str(c.avatar_media_id) if c.avatar_media_id else None}
            for c in chats
        ],
    }
