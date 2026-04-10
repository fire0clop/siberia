from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from schemas.friend import FriendRequestOut
from schemas.user import UserOut
from services.user_service import build_user_out
from services.friend import (
    accept_request,
    get_friends,
    get_incoming_friend_requests,
    get_outgoing_friend_requests,
    reject_request,
    remove_friend,
    send_request,
)

router = APIRouter(prefix="/friends", tags=["Friends"])


@router.post("/add/{user_id}")
async def add_friend(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await send_request(db, current["user"].id, user_id)


@router.post("/accept/{request_id}")
async def accept(
    request_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await accept_request(db, current["user"].id, request_id)


@router.post("/reject/{request_id}")
async def reject(
    request_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await reject_request(db, current["user"].id, request_id)


@router.delete("/{user_id}")
async def unfriend(
    user_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await remove_friend(db, current["user"].id, user_id)


@router.get("/requests/sent", response_model=list[FriendRequestOut])
async def outgoing_requests(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = await get_outgoing_friend_requests(db, current["user"].id)
    return [
        FriendRequestOut(request_id=friend_row.id, user=addressee)
        for friend_row, addressee in rows
    ]


@router.get("/requests", response_model=list[FriendRequestOut])
async def incoming_requests(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = await get_incoming_friend_requests(db, current["user"].id)
    return [
        FriendRequestOut(request_id=friend_row.id, user=requester)
        for friend_row, requester in rows
    ]


@router.get("", response_model=list[UserOut])
async def friends(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    viewer_id = current["user"].id
    users = await get_friends(db, viewer_id)
    result = []
    for u in users:
        data = await build_user_out(db, u, viewer_id=viewer_id)
        result.append(UserOut(**data))
    return result
