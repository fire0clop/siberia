# routes/chat.py

from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Query, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from db import get_db
from utils.deps import get_current_user
from schemas.chat import ChatCreate, ChatOut, GroupCreate, ChatPatch, ChatMemberOut, AddMembersRequest, RoleChangeRequest
from schemas.message import MessageCreate, MessageSendResponse, BulkReadRequest
from schemas.sync import ChatSyncResponse, ChatUpdateItem
from schemas.user import UserOut
from services.user_service import build_user_out

from models.chat_mute import ChatMuteSetting
from models.chat_member import MemberRole
from services.chat import create_chat, get_user_chats, check_user_in_chat, get_or_create_saved_chat, pin_message, upsert_draft, delete_draft
from services.message import create_message
from services.message_query import get_messages_with_status, get_messages_around
from services.chat_sync import get_updates_since
from services.bulk_read_service import bulk_mark_read
from services.group_service import (
    create_group_chat, get_chat_detail, get_members, add_members,
    remove_member, leave_chat, update_group, change_member_role,
    generate_invite_link, revoke_invite_link, join_by_invite
)

router = APIRouter(prefix="/chats", tags=["Chats"])


class MuteRequest(BaseModel):
    # None = навсегда; ISO datetime = до указанного времени
    muted_until: Optional[datetime] = None


class DraftRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=4096)


@router.post("", response_model=ChatOut)
async def create(
    data: ChatCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    return await create_chat(
        db=db,
        creator_id=user.id,
        user_ids=[data.user_id],
        title=None,
    )


@router.get("", response_model=list[ChatOut])
async def get_chats(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from models.chat_draft import ChatDraft
    user = current["user"]
    chats = await get_user_chats(db, user.id)

    # Batch-load drafts for this user across all chats
    chat_ids = [c.id for c in chats]
    drafts: dict[int, str] = {}
    if chat_ids:
        draft_result = await db.execute(
            select(ChatDraft).where(
                ChatDraft.user_id == user.id,
                ChatDraft.chat_id.in_(chat_ids),
            )
        )
        for d in draft_result.scalars().all():
            drafts[d.chat_id] = d.text

    out = []
    for chat in chats:
        data = ChatOut.model_validate(chat).model_dump()
        data["draft_text"] = drafts.get(chat.id)
        out.append(ChatOut(**data))
    return out


# POST /chats/group — MUST be before /{chat_id} routes
@router.post("/group", response_model=ChatOut)
async def create_group(
    data: GroupCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await create_group_chat(db, current["user"].id, data.title, data.user_ids, data.description)


# GET /chats/join/{slug} — MUST be before /{chat_id} routes
@router.get("/join/{slug}", response_model=ChatOut)
async def join_chat(
    slug: str,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await join_by_invite(db, slug, current["user"].id)


@router.get("/saved", response_model=ChatOut)
async def get_saved_chat(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get (or create) the Saved Messages chat for the current user."""
    chat = await get_or_create_saved_chat(db, current["user"].id)
    return chat


@router.get("/{chat_id}", response_model=ChatOut)
async def get_chat(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_chat_detail(db, chat_id, current["user"].id)


@router.post("/{chat_id}/messages")
async def send_chat_message(
    chat_id: int,
    data: MessageCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from models.media import Media as _Media
    msg, idem = await create_message(
        db,
        current["user"].id,
        chat_id,
        data.content,
        client_message_id=data.client_message_id,
        reply_to_message_id=data.reply_to_message_id,
        media_id=data.media_id,
        forward_message_id=data.forward_message_id,
        send_at=data.send_at,
    )
    media_type = None
    if msg.media_id:
        media_row = await db.get(_Media, msg.media_id)
        if media_row:
            media_type = media_row.type.value

    return {
        "message": {
            "id": msg.id,
            "chat_id": msg.chat_id,
            "user_id": msg.user_id,
            "type": msg.type.value if msg.type else "text",
            "text": msg.text,
            "media_id": str(msg.media_id) if msg.media_id else None,
            "media_type": media_type,
            "reply_to_message_id": msg.reply_to_message_id,
            "forwarded_from_message_id": msg.forwarded_from_message_id,
            "forwarded_from_user_id": msg.forwarded_from_user_id,
            "forwarded_from_chat_id": msg.forwarded_from_chat_id,
            "mention_user_ids": msg.mention_user_ids,
            "reactions": None,
            "send_at": msg.send_at,
            "created_at": msg.created_at,
            "edited_at": msg.edited_at,
            "deleted_at": msg.deleted_at,
            "client_message_id": str(msg.client_message_id) if msg.client_message_id else None,
        },
        "idempotent": idem,
    }


@router.get("/{chat_id}/messages")
async def list_chat_messages(
    chat_id: int,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    before_id: Optional[int] = Query(None),
    after_id: Optional[int] = Query(None),
    around_message_id: Optional[int] = Query(None),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await check_user_in_chat(db, current["user"].id, chat_id)
    if around_message_id is not None:
        return await get_messages_around(
            db,
            current["user"].id,
            chat_id,
            pivot_id=around_message_id,
            half=limit // 2,
        )
    return await get_messages_with_status(
        db,
        current["user"].id,
        chat_id,
        limit,
        offset,
        before_id=before_id,
        after_id=after_id,
    )


@router.post("/{chat_id}/mute", status_code=200)
async def mute_chat(
    chat_id: int,
    data: MuteRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Замьютить чат. muted_until=null — навсегда; дата — до указанного момента."""
    user = current["user"]
    await check_user_in_chat(db, user.id, chat_id)

    result = await db.execute(
        select(ChatMuteSetting).where(
            ChatMuteSetting.user_id == user.id,
            ChatMuteSetting.chat_id == chat_id,
        )
    )
    mute = result.scalars().first()

    if mute:
        mute.muted_until = data.muted_until
    else:
        db.add(ChatMuteSetting(user_id=user.id, chat_id=chat_id, muted_until=data.muted_until))

    await db.commit()
    return {"detail": "Chat muted"}


@router.delete("/{chat_id}/mute", status_code=200)
async def unmute_chat(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Отключить мут чата."""
    user = current["user"]
    await check_user_in_chat(db, user.id, chat_id)

    result = await db.execute(
        select(ChatMuteSetting).where(
            ChatMuteSetting.user_id == user.id,
            ChatMuteSetting.chat_id == chat_id,
        )
    )
    mute = result.scalars().first()
    if mute:
        await db.delete(mute)
        await db.commit()
    return {"detail": "Chat unmuted"}


@router.get("/{chat_id}/sync", response_model=ChatSyncResponse)
async def sync_chat_updates(
    chat_id: int,
    after_seq: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=500),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    items, latest = await get_updates_since(
        db,
        current["user"].id,
        chat_id,
        after_seq,
        limit,
    )
    return ChatSyncResponse(
        updates=[ChatUpdateItem(**u) for u in items],
        latest_seq=latest,
    )


# GET /chats/{chat_id}/members
@router.get("/{chat_id}/members", response_model=list[ChatMemberOut])
async def list_members(
    chat_id: int,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    viewer_id = current["user"].id
    await check_user_in_chat(db, viewer_id, chat_id)
    rows = await get_members(db, chat_id, limit, offset)
    result = []
    for m, u in rows:
        user_data = await build_user_out(db, u, viewer_id=viewer_id)
        result.append(ChatMemberOut(user=UserOut(**user_data), role=m.role.value, joined_at=m.joined_at))
    return result


# POST /chats/{chat_id}/members
@router.post("/{chat_id}/members", status_code=200)
async def add_chat_members(
    chat_id: int,
    data: AddMembersRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await add_members(db, chat_id, current["user"].id, data.user_ids)
    return {"detail": "Members added"}


# DELETE /chats/{chat_id}/members/{user_id}
@router.delete("/{chat_id}/members/{user_id}", status_code=200)
async def kick_member(
    chat_id: int,
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await remove_member(db, chat_id, current["user"].id, user_id)
    return {"detail": "Member removed"}


# POST /chats/{chat_id}/leave
@router.post("/{chat_id}/leave", status_code=200)
async def leave(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await leave_chat(db, chat_id, current["user"].id)
    return {"detail": "Left the chat"}


# PATCH /chats/{chat_id}
@router.patch("/{chat_id}", response_model=ChatOut)
async def update_chat(
    chat_id: int,
    data: ChatPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_group(db, chat_id, current["user"].id, data.title, data.description, data.avatar_media_id)


# PATCH /chats/{chat_id}/members/{user_id}/role
@router.patch("/{chat_id}/members/{user_id}/role", status_code=200)
async def set_role(
    chat_id: int,
    user_id: int,
    data: RoleChangeRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await change_member_role(db, chat_id, current["user"].id, user_id, MemberRole(data.role))
    return {"detail": "Role updated"}


# POST /chats/{chat_id}/invite-link
@router.post("/{chat_id}/invite-link")
async def create_invite(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    slug = await generate_invite_link(db, chat_id, current["user"].id)
    return {"invite_link": slug}


# DELETE /chats/{chat_id}/invite-link
@router.delete("/{chat_id}/invite-link", status_code=200)
async def delete_invite(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await revoke_invite_link(db, chat_id, current["user"].id)
    return {"detail": "Invite link revoked"}


# POST /chats/{chat_id}/pin/{message_id}
@router.post("/{chat_id}/pin/{message_id}", status_code=200)
async def pin_chat_message(
    chat_id: int,
    message_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await pin_message(db, current["user"].id, chat_id, message_id)
    return {"detail": "Message pinned"}


# DELETE /chats/{chat_id}/pin
@router.delete("/{chat_id}/pin", status_code=200)
async def unpin_chat_message(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await pin_message(db, current["user"].id, chat_id, None)
    return {"detail": "Pin removed"}


# POST /chats/{chat_id}/read
@router.post("/{chat_id}/read", status_code=200)
async def bulk_read(
    chat_id: int,
    data: BulkReadRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await bulk_mark_read(db, current["user"].id, chat_id, data.up_to_message_id)
    return {"detail": "Messages marked as read"}


# PUT /chats/{chat_id}/draft
@router.put("/{chat_id}/draft", status_code=200)
async def save_draft(
    chat_id: int,
    data: DraftRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await upsert_draft(db, current["user"].id, chat_id, data.text)
    return {"detail": "Draft saved"}


# DELETE /chats/{chat_id}/draft
@router.delete("/{chat_id}/draft", status_code=200)
async def remove_draft(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await delete_draft(db, current["user"].id, chat_id)
    return {"detail": "Draft deleted"}


# GET /chats/{chat_id}/messages/scheduled
@router.get("/{chat_id}/messages/scheduled")
async def list_scheduled_messages(
    chat_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from datetime import datetime, timezone
    from models.message import Message
    from sqlalchemy.future import select as sa_select

    await check_user_in_chat(db, current["user"].id, chat_id)
    now = datetime.now(timezone.utc)
    result = await db.execute(
        sa_select(Message).where(
            Message.chat_id == chat_id,
            Message.user_id == current["user"].id,
            Message.send_at.isnot(None),
            Message.send_at > now,
        ).order_by(Message.send_at)
    )
    msgs = result.scalars().all()
    return [
        {
            "id": m.id,
            "chat_id": m.chat_id,
            "user_id": m.user_id,
            "text": m.text,
            "media_id": str(m.media_id) if m.media_id else None,
            "reply_to_message_id": m.reply_to_message_id,
            "send_at": m.send_at,
            "created_at": m.created_at,
        }
        for m in msgs
    ]
