import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import desc

from db import get_db
from schemas.user import (
    AvatarPatch,
    PasswordChange,
    PrivacySettingOut,
    PrivacySettingPatch,
    UsernamePatch,
    UserOut,
    UserPatch,
    UserPresence,
    LoginHistoryItem,
)
from utils.deps import get_current_user
from utils.redis import is_online
from models.user import User
from models.media import Media, MediaType
from models.message_status import MessageStatus, MessageStatusEnum
from models.privacy_settings import Visibility
from models.login_event import LoginEvent
from services.user_search import search_users
from services.user_service import _get_privacy, build_user_out, invalidate_user_profile
from services.block_service import block_user, unblock_user, get_blocked_users
from services.auth import change_password, delete_account

router = APIRouter(prefix="/users", tags=["Users"])


# ── /me endpoints (must be before /{id}) ─────────────────────────────────────

@router.get("/me", response_model=UserOut)
async def me(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    data = await build_user_out(db, user, viewer_id=user.id)
    return UserOut(**data)


@router.patch("/me", response_model=UserOut)
async def update_me(
    patch: UserPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]

    if patch.nickname is not None and patch.nickname != user.nickname:
        existing = await db.execute(
            select(User).where(User.nickname == patch.nickname, User.id != user.id)
        )
        if existing.scalars().first():
            raise HTTPException(status_code=409, detail="Nickname already taken")
        user.nickname = patch.nickname

    if patch.bio is not None:
        user.bio = patch.bio

    await db.commit()
    await db.refresh(user)
    await invalidate_user_profile(user.id)
    data = await build_user_out(db, user, viewer_id=user.id)
    return UserOut(**data)


@router.patch("/me/avatar", response_model=UserOut)
async def update_avatar(
    patch: AvatarPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]

    try:
        media_uuid = uuid.UUID(patch.media_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid media_id format")

    media = await db.get(Media, media_uuid)
    if not media:
        raise HTTPException(status_code=404, detail="Media not found")
    if media.uploader_id != user.id:
        raise HTTPException(status_code=403, detail="Media does not belong to you")
    if media.type != MediaType.image:
        raise HTTPException(status_code=400, detail="Avatar must be an image")

    user.avatar_media_id = media_uuid
    await db.commit()
    await db.refresh(user)
    await invalidate_user_profile(user.id)
    data = await build_user_out(db, user, viewer_id=user.id)
    return UserOut(**data)


@router.delete("/me/avatar", response_model=UserOut)
async def delete_avatar(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    user.avatar_media_id = None
    await db.commit()
    await db.refresh(user)
    await invalidate_user_profile(user.id)
    data = await build_user_out(db, user, viewer_id=user.id)
    return UserOut(**data)


@router.patch("/me/username", response_model=UserOut)
async def update_username(
    patch: UsernamePatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]

    existing = await db.execute(
        select(User).where(User.username == patch.username, User.id != user.id)
    )
    if existing.scalars().first():
        raise HTTPException(status_code=409, detail="Username already taken")

    user.username = patch.username
    await db.commit()
    await db.refresh(user)
    await invalidate_user_profile(user.id)
    data = await build_user_out(db, user, viewer_id=user.id)
    return UserOut(**data)


@router.get("/me/badge")
async def badge(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    result = await db.execute(
        select(MessageStatus).where(
            MessageStatus.user_id == user.id,
            MessageStatus.status != MessageStatusEnum.read,
        )
    )
    count = len(result.scalars().all())
    return {"unread": count}


@router.get("/me/privacy", response_model=PrivacySettingOut)
async def get_privacy(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _get_privacy(db, current["user"].id)


@router.patch("/me/privacy", response_model=PrivacySettingOut)
async def update_privacy(
    patch: PrivacySettingPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ps = await _get_privacy(db, current["user"].id)

    if patch.last_seen is not None:
        ps.last_seen = Visibility(patch.last_seen)
    if patch.avatar is not None:
        ps.avatar = Visibility(patch.avatar)
    if patch.messages_from is not None:
        ps.messages_from = Visibility(patch.messages_from)
    if patch.invisible_mode is not None:
        ps.invisible_mode = patch.invisible_mode

    await db.commit()
    await db.refresh(ps)
    return ps


@router.patch("/me/password", status_code=200)
async def update_password(
    data: PasswordChange,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await change_password(
        db,
        current["user"].id,
        data.current_password,
        data.new_password,
        current["session_id"],
    )
    return {"detail": "Password changed"}


@router.delete("/me", status_code=200)
async def delete_me(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user_id = current["user"].id
    await delete_account(db, user_id)
    await invalidate_user_profile(user_id)
    return {"detail": "Account deleted"}


@router.get("/me/login-history", response_model=list[LoginHistoryItem])
async def login_history(
    limit: int = Query(20, ge=1, le=100),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(LoginEvent)
        .where(LoginEvent.user_id == current["user"].id)
        .order_by(desc(LoginEvent.created_at))
        .limit(limit)
    )
    return result.scalars().all()


@router.get("/me/blocked", response_model=list[UserOut])
async def get_blocked(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    users = await get_blocked_users(db, current["user"].id)
    return [UserOut.model_validate(u) for u in users]


@router.post("/{user_id}/block", status_code=200)
async def block(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await block_user(db, current["user"].id, user_id)
    return {"detail": "User blocked"}


@router.delete("/{user_id}/block", status_code=200)
async def unblock(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await unblock_user(db, current["user"].id, user_id)
    return {"detail": "User unblocked"}


@router.get("/search", response_model=list[UserOut])
async def search(
    q: str = Query(..., min_length=1),
    _auth: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    viewer_id = _auth["user"].id
    users = await search_users(db, q, searcher_id=viewer_id)
    result = []
    for u in users:
        data = await build_user_out(db, u, viewer_id=viewer_id)
        result.append(UserOut(**data))
    return result


# ── /{id} endpoints ───────────────────────────────────────────────────────────

@router.get("/{user_id}/presence", response_model=UserPresence)
async def get_presence(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    target = await db.get(User, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")

    ps = await _get_privacy(db, user_id)
    viewer_id = current["user"].id
    is_self = viewer_id == user_id

    # Determine if viewer can see last_seen
    visible = is_self
    if not visible:
        if ps.last_seen == Visibility.everyone:
            visible = True
        elif ps.last_seen == Visibility.friends:
            from services.user_service import _are_friends
            visible = await _are_friends(db, viewer_id, user_id)

    # Invisible mode: для всех кроме self — online всегда false и last_seen скрыт.
    # Реальный online-статус «прорывается» только через WS-событие presence_change,
    # которое бэк публикует в `chat:{id}` только когда юзер активно в этом чате.
    if ps.invisible_mode and not is_self:
        return UserPresence(user_id=user_id, online=False, last_seen_at=None)

    online = await is_online(user_id)
    last_seen = target.last_seen_at if visible else None

    return UserPresence(user_id=user_id, online=online, last_seen_at=last_seen)


@router.get("/{user_id}", response_model=UserOut)
async def get_user(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    target = await db.get(User, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")

    data = await build_user_out(db, target, viewer_id=current["user"].id)
    return UserOut(**data)
