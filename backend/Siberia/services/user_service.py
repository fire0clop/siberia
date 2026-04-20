"""Profile-related service helpers."""
from __future__ import annotations

import json
import logging
import uuid

logger = logging.getLogger(__name__)
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import and_, or_

from models.user import User
from models.media import Media, MediaType
from models.privacy_settings import PrivacySetting, Visibility
from models.friend import Friend, FriendStatus
from utils.redis import cache_set, cache_get, cache_delete

_PROFILE_TTL = 300  # 5 minutes


def _profile_key(user_id: int) -> str:
    return f"user:profile:{user_id}"


async def invalidate_user_profile(user_id: int) -> None:
    await cache_delete(_profile_key(user_id))


async def _get_privacy(db: AsyncSession, user_id: int) -> PrivacySetting:
    """Return existing PrivacySetting or create default row."""
    ps = await db.get(PrivacySetting, user_id)
    if ps is None:
        ps = PrivacySetting(user_id=user_id)
        db.add(ps)
        await db.commit()
        await db.refresh(ps)
    return ps


async def _are_friends(db: AsyncSession, user_id: int, other_id: int) -> bool:
    result = await db.execute(
        select(Friend).where(
            or_(
                and_(Friend.requester_id == user_id, Friend.addressee_id == other_id),
                and_(Friend.requester_id == other_id, Friend.addressee_id == user_id),
            ),
            Friend.status == FriendStatus.accepted,
        )
    )
    return result.scalars().first() is not None


async def get_avatar_url(db: AsyncSession, avatar_media_id) -> Optional[str]:
    if not avatar_media_id:
        return None
    media = await db.get(Media, avatar_media_id)
    if not media:
        return None
    try:
        from services.s3 import presigned_url
        return await presigned_url(media.s3_key)
    except Exception as exc:
        logger.exception("Failed to generate avatar presigned URL: %s", exc)
        return None


async def build_user_out(
    db: AsyncSession,
    target: User,
    viewer_id: Optional[int] = None,
    include_avatar_url: bool = True,
) -> dict:
    """Build UserOut dict with privacy filtering applied. Caches self-profile."""
    is_self = viewer_id == target.id

    # Cache only self-profile (viewer == target) since privacy rules are trivial
    if is_self:
        cached = await cache_get(_profile_key(target.id))
        if cached:
            try:
                return json.loads(cached)
            except Exception as exc:
                logger.warning("Corrupted user profile cache for %s: %s", target.id, exc)

    ps = await _get_privacy(db, target.id)

    friends = False
    if viewer_id and not is_self:
        friends = await _are_friends(db, viewer_id, target.id)

    def _visible(rule: Visibility) -> bool:
        if is_self:
            return True
        if rule == Visibility.everyone:
            return True
        if rule == Visibility.friends:
            return friends
        return False

    avatar_url = None
    avatar_media_id = None
    if _visible(ps.avatar):
        avatar_media_id = str(target.avatar_media_id) if target.avatar_media_id else None
        if include_avatar_url and avatar_media_id:
            avatar_url = await get_avatar_url(db, target.avatar_media_id)

    last_seen_at = target.last_seen_at if _visible(ps.last_seen) else None

    result = {
        "id": target.id,
        "public_id": target.public_id,
        "email": target.email,
        "nickname": target.nickname,
        "username": target.username,
        "bio": target.bio,
        "avatar_media_id": avatar_media_id,
        "avatar_url": avatar_url,
        "last_seen_at": last_seen_at.isoformat() if last_seen_at else None,
        "email_verified": target.email_verified if hasattr(target, "email_verified") else False,
    }

    if is_self:
        await cache_set(_profile_key(target.id), json.dumps(result), ttl=_PROFILE_TTL)

    return result


async def update_last_seen(db: AsyncSession, user_id: int) -> None:
    user = await db.get(User, user_id)
    if user:
        user.last_seen_at = datetime.now(timezone.utc)
        await db.commit()
