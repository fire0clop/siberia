# routes/story.py — Stories: эфемерные медиа-посты для друзей
import uuid as uuid_mod
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import and_, func, or_

from db import get_db
from utils.deps import get_current_user
from models.friend import Friend, FriendStatus
from models.media import Media, MediaType
from models.story import Story, StoryView
from models.user import User
from schemas.user import UserOut
from services.user_service import build_user_out

router = APIRouter(prefix="/stories", tags=["Stories"])

_STORY_TTL_HOURS = 24
_MAX_ACTIVE_STORIES = 20


class StoryCreate(BaseModel):
    media_id: str
    caption: str | None = Field(None, max_length=200)


class StoryOut(BaseModel):
    id: int
    user_id: int
    media_id: str
    media_type: str
    media_url: str | None = None
    caption: str | None = None
    created_at: datetime
    expires_at: datetime
    viewed: bool = False
    views_count: int | None = None  # только для собственных


class StoryFeedGroup(BaseModel):
    user: UserOut
    stories: list[StoryOut]
    all_viewed: bool


async def _friend_ids(db: AsyncSession, user_id: int) -> list[int]:
    rows = await db.execute(
        select(Friend.requester_id, Friend.addressee_id).where(
            or_(Friend.requester_id == user_id, Friend.addressee_id == user_id),
            Friend.status == FriendStatus.accepted,
        )
    )
    ids = set()
    for a, b in rows.all():
        ids.add(b if a == user_id else a)
    return list(ids)


async def _story_out(
    db: AsyncSession, story: Story, media: Media,
    viewer_id: int, viewed_ids: set[int], views_count: dict[int, int],
) -> StoryOut:
    from services.s3 import presigned_url
    url = None
    try:
        url = await presigned_url(media.s3_key)
    except Exception:  # noqa: BLE001 — сторис без URL лучше, чем 500 на всю ленту
        pass
    is_own = story.user_id == viewer_id
    return StoryOut(
        id=story.id,
        user_id=story.user_id,
        media_id=str(story.media_id),
        media_type=media.type.value,
        media_url=url,
        caption=story.caption,
        created_at=story.created_at,
        expires_at=story.expires_at,
        viewed=is_own or story.id in viewed_ids,
        views_count=views_count.get(story.id, 0) if is_own else None,
    )


@router.post("", response_model=StoryOut)
async def create_story(
    data: StoryCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    try:
        media_uuid = uuid_mod.UUID(data.media_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid media_id")

    media = await db.get(Media, media_uuid)
    if media is None:
        raise HTTPException(status_code=404, detail="Media not found")
    if media.uploader_id != user.id:
        raise HTTPException(status_code=403, detail="Media does not belong to you")
    if media.type not in (MediaType.image, MediaType.video):
        raise HTTPException(status_code=400, detail="Story must be an image or video")

    now = datetime.now(timezone.utc)
    active = (await db.execute(
        select(func.count()).select_from(Story).where(
            Story.user_id == user.id, Story.expires_at > now
        )
    )).scalar() or 0
    if active >= _MAX_ACTIVE_STORIES:
        raise HTTPException(status_code=400, detail=f"Story limit reached ({_MAX_ACTIVE_STORIES})")

    story = Story(
        user_id=user.id,
        media_id=media_uuid,
        caption=data.caption,
        created_at=now,
        expires_at=now + timedelta(hours=_STORY_TTL_HOURS),
    )
    db.add(story)
    await db.commit()
    await db.refresh(story)
    return await _story_out(db, story, media, user.id, set(), {})


@router.get("/feed", response_model=list[StoryFeedGroup])
async def stories_feed(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Лента: мои сторис + сторис друзей. Своя группа всегда первая."""
    viewer_id = current["user"].id
    now = datetime.now(timezone.utc)

    author_ids = await _friend_ids(db, viewer_id)
    author_ids.append(viewer_id)

    rows = (await db.execute(
        select(Story, Media)
        .join(Media, Media.id == Story.media_id)
        .where(Story.user_id.in_(author_ids), Story.expires_at > now)
        .order_by(Story.user_id, Story.created_at)
    )).all()
    if not rows:
        return []

    story_ids = [s.id for s, _ in rows]

    viewed_ids = {
        r[0] for r in (await db.execute(
            select(StoryView.story_id).where(
                StoryView.story_id.in_(story_ids), StoryView.user_id == viewer_id
            )
        )).all()
    }
    views_count = {
        sid: int(cnt) for sid, cnt in (await db.execute(
            select(StoryView.story_id, func.count())
            .where(StoryView.story_id.in_(story_ids))
            .group_by(StoryView.story_id)
        )).all()
    }

    by_author: dict[int, list[tuple[Story, Media]]] = {}
    for s, m in rows:
        by_author.setdefault(s.user_id, []).append((s, m))

    groups: list[StoryFeedGroup] = []
    for author_id, items in by_author.items():
        author = await db.get(User, author_id)
        if author is None:
            continue
        user_out = UserOut(**await build_user_out(db, author, viewer_id=viewer_id))
        outs = [
            await _story_out(db, s, m, viewer_id, viewed_ids, views_count)
            for s, m in items
        ]
        groups.append(StoryFeedGroup(
            user=user_out,
            stories=outs,
            all_viewed=all(o.viewed for o in outs),
        ))

    # Моя группа первой, дальше: непросмотренные раньше просмотренных, свежие выше
    groups.sort(key=lambda g: (
        g.user.id != viewer_id,
        g.all_viewed,
        -max(s.created_at.timestamp() for s in g.stories),
    ))
    return groups


@router.post("/{story_id}/view", status_code=200)
async def mark_viewed(
    story_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    viewer_id = current["user"].id
    story = await db.get(Story, story_id)
    if story is None or story.expires_at <= datetime.now(timezone.utc):
        raise HTTPException(status_code=404, detail="Story not found")
    # Смотреть можно свои и друзей
    if story.user_id != viewer_id and story.user_id not in await _friend_ids(db, viewer_id):
        raise HTTPException(status_code=403, detail="Not allowed")

    await db.execute(
        pg_insert(StoryView)
        .values(story_id=story_id, user_id=viewer_id)
        .on_conflict_do_nothing(constraint="uq_story_view")
    )
    await db.commit()
    return {"detail": "Viewed"}


@router.get("/{story_id}/views", response_model=list[UserOut])
async def story_views(
    story_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Кто посмотрел — только для автора."""
    viewer_id = current["user"].id
    story = await db.get(Story, story_id)
    if story is None:
        raise HTTPException(status_code=404, detail="Story not found")
    if story.user_id != viewer_id:
        raise HTTPException(status_code=403, detail="Only the author can see views")

    rows = (await db.execute(
        select(User)
        .join(StoryView, and_(StoryView.user_id == User.id, StoryView.story_id == story_id))
        .order_by(StoryView.viewed_at.desc())
    )).scalars().all()
    return [UserOut(**await build_user_out(db, u, viewer_id=viewer_id)) for u in rows]


@router.delete("/{story_id}", status_code=200)
async def delete_story(
    story_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    story = await db.get(Story, story_id)
    if story is None:
        raise HTTPException(status_code=404, detail="Story not found")
    if story.user_id != current["user"].id:
        raise HTTPException(status_code=403, detail="Can only delete own stories")
    await db.delete(story)
    await db.commit()
    return {"detail": "Story deleted"}
