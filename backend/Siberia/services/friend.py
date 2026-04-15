from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import or_, and_, delete as sa_delete
from fastapi import HTTPException

from models.friend import Friend, FriendStatus
from models.user import User
from services.block_service import check_not_blocked


async def send_request(db: AsyncSession, requester_id: int, addressee_id: int):
    if requester_id == addressee_id:
        raise HTTPException(status_code=400, detail="Cannot add yourself")

    target = await db.get(User, addressee_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")

    await check_not_blocked(db, requester_id, addressee_id)

    existing = await db.execute(
        select(Friend).where(
            or_(
                and_(Friend.requester_id == requester_id, Friend.addressee_id == addressee_id),
                and_(Friend.requester_id == addressee_id, Friend.addressee_id == requester_id),
            )
        )
    )
    row = existing.scalars().first()

    if row:
        if row.status == FriendStatus.accepted:
            raise HTTPException(status_code=400, detail="Already friends")
        if row.status == FriendStatus.pending:
            raise HTTPException(status_code=400, detail="Request already sent")
        # rejected → allow re-request by creating a fresh record
        await db.delete(row)
        await db.flush()

    friend = Friend(
        requester_id=requester_id,
        addressee_id=addressee_id,
        status=FriendStatus.pending,
    )
    db.add(friend)
    await db.commit()
    await db.refresh(friend)
    return friend


async def accept_request(db: AsyncSession, user_id: int, request_id: int):
    result = await db.execute(select(Friend).where(Friend.id == request_id))
    friend = result.scalars().first()

    if not friend or friend.addressee_id != user_id:
        raise HTTPException(status_code=404, detail="Request not found")
    if friend.status != FriendStatus.pending:
        raise HTTPException(status_code=400, detail="Request is not pending")

    friend.status = FriendStatus.accepted
    await db.commit()
    await db.refresh(friend)
    return friend


async def reject_request(db: AsyncSession, user_id: int, request_id: int):
    result = await db.execute(select(Friend).where(Friend.id == request_id))
    friend = result.scalars().first()

    if not friend or friend.addressee_id != user_id:
        raise HTTPException(status_code=404, detail="Request not found")
    if friend.status != FriendStatus.pending:
        raise HTTPException(status_code=400, detail="Request is not pending")

    friend.status = FriendStatus.rejected
    await db.commit()
    return {"detail": "Request rejected"}


async def remove_friend(db: AsyncSession, user_id: int, other_user_id: int):
    result = await db.execute(
        select(Friend).where(
            or_(
                and_(Friend.requester_id == user_id, Friend.addressee_id == other_user_id),
                and_(Friend.requester_id == other_user_id, Friend.addressee_id == user_id),
            ),
            Friend.status == FriendStatus.accepted,
        )
    )
    friend = result.scalars().first()
    if not friend:
        raise HTTPException(status_code=404, detail="Not friends")

    await db.delete(friend)
    await db.commit()
    return {"detail": "Friend removed"}


async def get_friends(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(User)
        .select_from(Friend)
        .join(
            User,
            or_(
                and_(Friend.requester_id == user_id, Friend.addressee_id == User.id),
                and_(Friend.addressee_id == user_id, Friend.requester_id == User.id),
            ),
        )
        .where(Friend.status == FriendStatus.accepted)
    )
    return result.scalars().unique().all()


async def get_incoming_friend_requests(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(Friend, User)
        .select_from(Friend)
        .join(User, User.id == Friend.requester_id)
        .where(Friend.addressee_id == user_id, Friend.status == FriendStatus.pending)
        .order_by(Friend.id.desc())
    )
    return list(result.all())


async def get_outgoing_friend_requests(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(Friend, User)
        .select_from(Friend)
        .join(User, User.id == Friend.addressee_id)
        .where(Friend.requester_id == user_id, Friend.status == FriendStatus.pending)
        .order_by(Friend.id.desc())
    )
    return list(result.all())
