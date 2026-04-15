"""Group chat management service."""
import secrets
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import and_, func

from models.chat import Chat, ChatType
from models.chat_member import ChatMember, MemberRole
from models.message import Message, MessageType
from models.chat_update import ChatUpdateEventType
from models.user import User
from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope

_ROLE_RANK = {MemberRole.owner: 3, MemberRole.admin: 2, MemberRole.member: 1, MemberRole.subscriber: 0}


async def _get_member(db, chat_id: int, user_id: int) -> ChatMember:
    result = await db.execute(
        select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
    )
    m = result.scalars().first()
    if not m:
        raise HTTPException(status_code=403, detail="Not a member of this chat")
    return m


async def _require_role(db, chat_id: int, user_id: int, min_role: MemberRole) -> ChatMember:
    m = await _get_member(db, chat_id, user_id)
    if _ROLE_RANK[m.role] < _ROLE_RANK[min_role]:
        raise HTTPException(status_code=403, detail="Insufficient permissions")
    return m


async def _create_system_message(db, chat: Chat, text: str) -> Message:
    msg = Message(chat_id=chat.id, user_id=None, text=text, type=MessageType.system)
    db.add(msg)
    await db.flush()
    chat.last_message_id = msg.id
    return msg


async def create_group_chat(
    db: AsyncSession,
    creator_id: int,
    title: str,
    user_ids: list[int],
    description: Optional[str] = None,
) -> Chat:
    all_ids = list({creator_id} | set(user_ids))
    if len(all_ids) < 2:
        raise HTTPException(status_code=400, detail="Group must have at least 2 members")

    users = await db.execute(select(User.id).where(User.id.in_(all_ids)))
    found = {u[0] for u in users.all()}
    missing = set(all_ids) - found
    if missing:
        raise HTTPException(status_code=404, detail=f"Users not found: {missing}")

    chat = Chat(type=ChatType.group, title=title, description=description)
    db.add(chat)
    await db.flush()

    now = datetime.now(timezone.utc)
    for uid in all_ids:
        role = MemberRole.owner if uid == creator_id else MemberRole.member
        db.add(ChatMember(chat_id=chat.id, user_id=uid, role=role, joined_at=now))

    await db.flush()

    creator = await db.get(User, creator_id)
    creator_name = creator.nickname if creator else str(creator_id)
    msg = await _create_system_message(db, chat, f"{creator_name} created the group")
    chat.last_message_id = msg.id
    chat.sync_seq = 1

    await db.commit()
    await db.refresh(chat)
    return chat


async def get_chat_detail(db: AsyncSession, chat_id: int, user_id: int) -> Chat:
    """Return chat only if user is a member."""
    await _get_member(db, chat_id, user_id)
    chat = await db.get(Chat, chat_id)
    if not chat:
        raise HTTPException(status_code=404, detail="Chat not found")
    return chat


async def get_members(db: AsyncSession, chat_id: int, limit: int = 100, offset: int = 0):
    result = await db.execute(
        select(ChatMember, User)
        .join(User, User.id == ChatMember.user_id)
        .where(ChatMember.chat_id == chat_id)
        .order_by(ChatMember.joined_at)
        .limit(limit)
        .offset(offset)
    )
    return [(m, u) for m, u in result.all()]


async def add_members(
    db: AsyncSession, chat_id: int, actor_id: int, user_ids: list[int]
) -> None:
    await _require_role(db, chat_id, actor_id, MemberRole.admin)
    chat_obj = await db.get(Chat, chat_id)
    if chat_obj.type != ChatType.group:
        raise HTTPException(status_code=400, detail="Cannot add members to a private chat")

    # Check max_members
    count_result = await db.execute(
        select(func.count(ChatMember.id)).where(ChatMember.chat_id == chat_id)
    )
    current_count = count_result.scalar()
    if current_count + len(user_ids) > chat_obj.max_members:
        raise HTTPException(status_code=400, detail=f"Group is full (max {chat_obj.max_members})")

    now = datetime.now(timezone.utc)
    added_names = []
    for uid in user_ids:
        existing = await db.execute(
            select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == uid)
        )
        if existing.scalars().first():
            continue  # already a member
        u = await db.get(User, uid)
        if not u:
            continue
        db.add(ChatMember(chat_id=chat_id, user_id=uid, role=MemberRole.member, joined_at=now))
        added_names.append(u.nickname)

    if not added_names:
        await db.commit()
        return

    await db.flush()

    locked_chat = await lock_chat_row(db, chat_id)
    msg = await _create_system_message(db, locked_chat, f"Added: {', '.join(added_names)}")

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_added, msg.id,
        {"added_user_ids": user_ids, "actor_id": actor_id}
    )
    await db.commit()

    env = build_envelope(chat_id, seq, ChatUpdateEventType.member_added, msg.id,
                         {"added_user_ids": user_ids, "actor_id": actor_id})
    await broadcast_envelope(chat_id, env)


async def remove_member(
    db: AsyncSession, chat_id: int, actor_id: int, target_user_id: int
) -> None:
    actor_member = await _require_role(db, chat_id, actor_id, MemberRole.admin)
    target_member = await _get_member(db, chat_id, target_user_id)

    if target_member.role == MemberRole.owner:
        raise HTTPException(status_code=403, detail="Cannot remove the owner")
    if actor_member.role == MemberRole.admin and target_member.role == MemberRole.admin:
        raise HTTPException(status_code=403, detail="Admins cannot remove other admins")

    target_user = await db.get(User, target_user_id)
    target_name = target_user.nickname if target_user else str(target_user_id)

    await db.delete(target_member)
    await db.flush()

    locked_chat = await lock_chat_row(db, chat_id)
    msg = await _create_system_message(db, locked_chat, f"{target_name} was removed from the group")

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_removed, msg.id,
        {"removed_user_id": target_user_id, "actor_id": actor_id}
    )
    await db.commit()

    env = build_envelope(chat_id, seq, ChatUpdateEventType.member_removed, msg.id,
                         {"removed_user_id": target_user_id, "actor_id": actor_id})
    await broadcast_envelope(chat_id, env)


async def leave_chat(db: AsyncSession, chat_id: int, user_id: int) -> None:
    member = await _get_member(db, chat_id, user_id)
    chat_obj = await db.get(Chat, chat_id)
    if not chat_obj or chat_obj.type != ChatType.group:
        raise HTTPException(status_code=400, detail="Cannot leave a private chat")

    leaving_user = await db.get(User, user_id)
    leaving_name = leaving_user.nickname if leaving_user else str(user_id)

    if member.role == MemberRole.owner:
        # Auto-promote: oldest admin first, then oldest member
        result = await db.execute(
            select(ChatMember)
            .where(ChatMember.chat_id == chat_id, ChatMember.user_id != user_id)
            .order_by(
                (ChatMember.role == MemberRole.admin).desc(),
                ChatMember.joined_at,
            )
        )
        next_owner = result.scalars().first()
        if next_owner:
            next_owner.role = MemberRole.owner

    await db.delete(member)
    await db.flush()

    locked_chat = await lock_chat_row(db, chat_id)
    msg = await _create_system_message(db, locked_chat, f"{leaving_name} left the group")

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_left, msg.id,
        {"user_id": user_id}
    )
    await db.commit()

    env = build_envelope(chat_id, seq, ChatUpdateEventType.member_left, msg.id, {"user_id": user_id})
    await broadcast_envelope(chat_id, env)


async def update_group(
    db: AsyncSession, chat_id: int, actor_id: int,
    title: Optional[str], description: Optional[str], avatar_media_id: Optional[str]
) -> Chat:
    await _require_role(db, chat_id, actor_id, MemberRole.admin)
    locked_chat = await lock_chat_row(db, chat_id)
    if locked_chat.type != ChatType.group:
        raise HTTPException(status_code=400, detail="Cannot edit a private chat")

    if title is not None:
        locked_chat.title = title
    if description is not None:
        locked_chat.description = description
    if avatar_media_id is not None:
        import uuid as _uuid
        locked_chat.avatar_media_id = _uuid.UUID(avatar_media_id)

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.chat_updated, None,
        {"title": title, "description": description}
    )
    await db.commit()
    await db.refresh(locked_chat)

    env = build_envelope(chat_id, seq, ChatUpdateEventType.chat_updated, None,
                         {"title": title, "description": description})
    await broadcast_envelope(chat_id, env)
    return locked_chat


async def change_member_role(
    db: AsyncSession, chat_id: int, actor_id: int, target_user_id: int, new_role: MemberRole
) -> None:
    actor_member = await _require_role(db, chat_id, actor_id, MemberRole.owner)
    target_member = await _get_member(db, chat_id, target_user_id)

    if new_role == MemberRole.owner:
        # Transfer ownership: demote current owner to admin
        actor_member.role = MemberRole.admin

    target_member.role = new_role

    locked_chat = await lock_chat_row(db, chat_id)
    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.role_changed, None,
        {"user_id": target_user_id, "new_role": new_role.value, "actor_id": actor_id}
    )
    await db.commit()

    env = build_envelope(chat_id, seq, ChatUpdateEventType.role_changed, None,
                         {"user_id": target_user_id, "new_role": new_role.value, "actor_id": actor_id})
    await broadcast_envelope(chat_id, env)


async def generate_invite_link(db: AsyncSession, chat_id: int, actor_id: int) -> str:
    await _require_role(db, chat_id, actor_id, MemberRole.admin)
    chat_obj = await db.get(Chat, chat_id)
    if not chat_obj or chat_obj.type != ChatType.group:
        raise HTTPException(status_code=400, detail="Only groups have invite links")

    slug = secrets.token_urlsafe(24)  # ~32 chars
    chat_obj.invite_link = slug
    await db.commit()
    return slug


async def revoke_invite_link(db: AsyncSession, chat_id: int, actor_id: int) -> None:
    await _require_role(db, chat_id, actor_id, MemberRole.admin)
    chat_obj = await db.get(Chat, chat_id)
    if chat_obj:
        chat_obj.invite_link = None
        await db.commit()


async def join_by_invite(db: AsyncSession, slug: str, user_id: int) -> Chat:
    result = await db.execute(select(Chat).where(Chat.invite_link == slug))
    chat_obj = result.scalars().first()
    if not chat_obj:
        raise HTTPException(status_code=404, detail="Invalid or expired invite link")

    # Check if already a member
    existing = await db.execute(
        select(ChatMember).where(ChatMember.chat_id == chat_obj.id, ChatMember.user_id == user_id)
    )
    if existing.scalars().first():
        return chat_obj  # already member, idempotent

    # Check max_members
    count_result = await db.execute(
        select(func.count(ChatMember.id)).where(ChatMember.chat_id == chat_obj.id)
    )
    if count_result.scalar() >= chat_obj.max_members:
        raise HTTPException(status_code=400, detail="Group is full")

    now = datetime.now(timezone.utc)
    db.add(ChatMember(chat_id=chat_obj.id, user_id=user_id, role=MemberRole.member, joined_at=now))
    await db.flush()

    user = await db.get(User, user_id)
    user_name = user.nickname if user else str(user_id)

    locked_chat = await lock_chat_row(db, chat_obj.id)
    msg = await _create_system_message(db, locked_chat, f"{user_name} joined via invite link")

    seq, _ = await log_update_on_locked_chat(
        db, locked_chat, ChatUpdateEventType.member_added, msg.id,
        {"added_user_ids": [user_id], "via_invite": True}
    )
    await db.commit()
    await db.refresh(locked_chat)

    env = build_envelope(chat_obj.id, seq, ChatUpdateEventType.member_added, msg.id,
                         {"added_user_ids": [user_id], "via_invite": True})
    await broadcast_envelope(chat_obj.id, env)
    return locked_chat
