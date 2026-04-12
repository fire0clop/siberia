from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import desc, and_, or_, func

from fastapi import HTTPException

from models.chat import Chat, ChatType
from models.chat_member import ChatMember, MemberRole
from models.user import User
from models.friend import Friend, FriendStatus
from models.privacy_settings import Visibility
from services.block_service import check_not_blocked
from services.user_service import _get_privacy, _are_friends


async def get_private_chat_between(
    db: AsyncSession, user1: int, user2: int
) -> Chat | None:
    """Two-member chat with exactly user1 and user2 (not a group that contains both)."""
    if user1 == user2:
        return None

    two_member_chats = (
        select(ChatMember.chat_id)
        .group_by(ChatMember.chat_id)
        .having(func.count(ChatMember.user_id) == 2)
        .subquery()
    )

    stmt = (
        select(Chat)
        .join(two_member_chats, Chat.id == two_member_chats.c.chat_id)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(ChatMember.user_id.in_([user1, user2]))
        .group_by(Chat.id)
        .having(func.count(ChatMember.user_id) == 2)
    )

    result = await db.execute(stmt)
    return result.scalars().first()


async def _check_can_message(db: AsyncSession, sender_id: int, recipient_id: int) -> None:
    """
    Enforce messaging privacy for new private chats.
    Raises 403 if the recipient doesn't want messages from this sender.
    Should only be called when no existing chat exists yet.
    """
    await check_not_blocked(db, sender_id, recipient_id)

    ps = await _get_privacy(db, recipient_id)
    if ps.messages_from == Visibility.everyone:
        return
    if ps.messages_from == Visibility.friends:
        if await _are_friends(db, sender_id, recipient_id):
            return
        raise HTTPException(
            status_code=403,
            detail="This user only accepts messages from friends",
        )
    # nobody
    raise HTTPException(
        status_code=403,
        detail="This user does not accept new messages",
    )


async def create_chat(
    db: AsyncSession,
    creator_id: int,
    user_ids: list[int],
    title: str | None,
):
    all_users = set(user_ids)
    all_users.add(creator_id)

    users = await db.execute(select(User.id).where(User.id.in_(all_users)))
    found_users = {u[0] for u in users.all()}

    if found_users != all_users:
        raise HTTPException(status_code=404, detail="Some users not found")

    if len(all_users) == 2:
        user_list = list(all_users)
        other_id = user_list[0] if user_list[1] == creator_id else user_list[1]

        # Return existing chat immediately — no privacy check needed
        existing = await get_private_chat_between(db, creator_id, other_id)
        if existing:
            return existing

        # New chat: enforce messaging privacy + block check
        await _check_can_message(db, creator_id, other_id)

    chat = Chat(title=title)
    db.add(chat)
    await db.flush()

    now = datetime.now(timezone.utc)
    db.add_all([
        ChatMember(chat_id=chat.id, user_id=uid, role=MemberRole.member, joined_at=now)
        for uid in all_users
    ])

    await db.commit()
    await db.refresh(chat)
    return chat


async def get_or_create_saved_chat(db: AsyncSession, user_id: int) -> Chat:
    result = await db.execute(
        select(Chat)
        .join(ChatMember, ChatMember.chat_id == Chat.id)
        .where(ChatMember.user_id == user_id, Chat.type == ChatType.saved)
    )
    chat = result.scalars().first()
    if chat:
        return chat

    chat = Chat(type=ChatType.saved, title="Saved Messages", max_members=1)
    db.add(chat)
    await db.flush()

    db.add(ChatMember(chat_id=chat.id, user_id=user_id, role=MemberRole.owner, joined_at=datetime.now(timezone.utc)))
    await db.commit()
    await db.refresh(chat)
    return chat


async def pin_message(db: AsyncSession, user_id: int, chat_id: int, message_id: int | None) -> None:
    from models.chat_update import ChatUpdateEventType
    from models.chat_member import MemberRole
    from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope

    result = await db.execute(
        select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
    )
    member = result.scalars().first()
    if not member:
        raise HTTPException(status_code=403, detail="Access denied")
    if member.role not in (MemberRole.admin, MemberRole.owner):
        raise HTTPException(status_code=403, detail="Only admins and owner can pin messages")

    chat = await lock_chat_row(db, chat_id)
    chat.pinned_message_id = message_id

    seq, _ = await log_update_on_locked_chat(
        db, chat, ChatUpdateEventType.message_pinned, message_id,
        {"pinned_message_id": message_id},
    )
    await db.commit()

    env = build_envelope(
        chat_id, seq, ChatUpdateEventType.message_pinned, message_id,
        {"pinned_message_id": message_id},
    )
    await broadcast_envelope(chat_id, env)


async def get_user_chats(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(Chat)
        .join(ChatMember)
        .where(ChatMember.user_id == user_id)
        .order_by(desc(Chat.last_message_id).nulls_last(), desc(Chat.id))
    )
    return result.scalars().all()


async def upsert_draft(db: AsyncSession, user_id: int, chat_id: int, text: str) -> None:
    from models.chat_draft import ChatDraft
    await check_user_in_chat(db, user_id, chat_id)
    result = await db.execute(
        select(ChatDraft).where(ChatDraft.chat_id == chat_id, ChatDraft.user_id == user_id)
    )
    draft = result.scalars().first()
    if draft:
        draft.text = text
    else:
        db.add(ChatDraft(chat_id=chat_id, user_id=user_id, text=text))
    await db.commit()


async def delete_draft(db: AsyncSession, user_id: int, chat_id: int) -> None:
    from models.chat_draft import ChatDraft
    result = await db.execute(
        select(ChatDraft).where(ChatDraft.chat_id == chat_id, ChatDraft.user_id == user_id)
    )
    draft = result.scalars().first()
    if draft:
        await db.delete(draft)
        await db.commit()


async def check_user_in_chat(db: AsyncSession, user_id: int, chat_id: int):
    stmt = select(ChatMember.id).where(
        ChatMember.user_id == user_id,
        ChatMember.chat_id == chat_id,
    )
    result = await db.execute(stmt)
    if not result.scalar():
        raise HTTPException(status_code=403, detail="Access denied")
