from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from schemas.search import MessageSearchResponse, SearchHit

from services.message_search import search_messages, global_search
from services.channel_service import search_channels

router = APIRouter(prefix="/search", tags=["Search"])


@router.get("/messages", response_model=MessageSearchResponse)
async def search_messages_route(
    q: str = Query(..., min_length=1),
    chat_id: Optional[int] = Query(None),
    date_from: Optional[datetime] = Query(None),
    date_to: Optional[datetime] = Query(None),
    limit: int = Query(30, ge=1, le=100),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    hits = await search_messages(
        db,
        current["user"].id,
        q,
        chat_id,
        limit,
        date_from=date_from,
        date_to=date_to,
    )
    return MessageSearchResponse(results=[SearchHit(**h) for h in hits])


@router.get("")
async def search_global(
    q: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=50),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await global_search(db, current["user"].id, q, limit)


@router.get("/channels")
async def search_channels_route(
    q: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=100),
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    channels = await search_channels(db, q, limit)
    return [
        {
            "id": c.id,
            "title": c.title,
            "description": c.description,
            "avatar_media_id": str(c.avatar_media_id) if c.avatar_media_id else None,
            "subscribers_count": c.subscribers_count,
            "is_public": c.is_public,
        }
        for c in channels
    ]
