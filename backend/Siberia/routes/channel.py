# routes/channel.py

from typing import Optional

from fastapi import APIRouter, Depends, Query, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from schemas.chat import ChannelCreate, ChatOut, ChatPatch

from services.channel_service import (
    create_channel,
    subscribe_channel,
    subscribe_by_invite,
    unsubscribe_channel,
    update_channel,
    search_channels,
    get_channel_for_user,
)

router = APIRouter(prefix="/channels", tags=["Channels"])


class ChannelPatch(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=100)
    description: Optional[str] = Field(None, max_length=255)
    is_public: Optional[bool] = None
    avatar_media_id: Optional[str] = None


@router.post("", response_model=ChatOut)
async def create(
    data: ChannelCreate,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await create_channel(
        db,
        creator_id=current["user"].id,
        title=data.title,
        description=data.description,
        is_public=data.is_public,
    )


@router.get("/{channel_id}", response_model=ChatOut)
async def get_channel(
    channel_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_channel_for_user(db, channel_id, current["user"].id)


@router.patch("/{channel_id}", response_model=ChatOut)
async def update(
    channel_id: int,
    data: ChannelPatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_channel(
        db,
        channel_id=channel_id,
        actor_id=current["user"].id,
        title=data.title,
        description=data.description,
        is_public=data.is_public,
        avatar_media_id=data.avatar_media_id,
    )


@router.post("/{channel_id}/subscribe", response_model=ChatOut)
async def subscribe(
    channel_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await subscribe_channel(db, channel_id, current["user"].id)


@router.delete("/{channel_id}/subscribe", status_code=200)
async def unsubscribe(
    channel_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await unsubscribe_channel(db, channel_id, current["user"].id)
    return {"detail": "Unsubscribed"}


@router.get("/join/{slug}", response_model=ChatOut)
async def join_channel_by_invite(
    slug: str,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await subscribe_by_invite(db, slug, current["user"].id)
