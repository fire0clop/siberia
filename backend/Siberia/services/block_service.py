from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import or_, and_

from models.block import Block
from models.user import User


async def block_user(db: AsyncSession, blocker_id: int, blocked_id: int) -> None:
    if blocker_id == blocked_id:
        raise HTTPException(status_code=400, detail="Cannot block yourself")

    target = await db.get(User, blocked_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")

    existing = await db.execute(
        select(Block).where(Block.blocker_id == blocker_id, Block.blocked_id == blocked_id)
    )
    if existing.scalars().first():
        return  # already blocked — idempotent

    # Remove any friendship between the two when blocking
    from models.friend import Friend
    from sqlalchemy import delete as sa_delete
    await db.execute(
        sa_delete(Friend).where(
            or_(
                and_(Friend.requester_id == blocker_id, Friend.addressee_id == blocked_id),
                and_(Friend.requester_id == blocked_id, Friend.addressee_id == blocker_id),
            )
        )
    )

    db.add(Block(blocker_id=blocker_id, blocked_id=blocked_id))
    await db.commit()


async def unblock_user(db: AsyncSession, blocker_id: int, blocked_id: int) -> None:
    result = await db.execute(
        select(Block).where(Block.blocker_id == blocker_id, Block.blocked_id == blocked_id)
    )
    block = result.scalars().first()
    if block:
        await db.delete(block)
        await db.commit()


async def get_blocked_users(db: AsyncSession, user_id: int) -> list[User]:
    result = await db.execute(
        select(User)
        .join(Block, Block.blocked_id == User.id)
        .where(Block.blocker_id == user_id)
        .order_by(Block.id.desc())
    )
    return result.scalars().all()


async def check_not_blocked(db: AsyncSession, user_a: int, user_b: int) -> None:
    """Raise 403 if either user has blocked the other."""
    result = await db.execute(
        select(Block).where(
            or_(
                and_(Block.blocker_id == user_a, Block.blocked_id == user_b),
                and_(Block.blocker_id == user_b, Block.blocked_id == user_a),
            )
        )
    )
    if result.scalars().first():
        raise HTTPException(status_code=403, detail="Action not allowed")


async def is_blocked(db: AsyncSession, blocker_id: int, blocked_id: int) -> bool:
    result = await db.execute(
        select(Block).where(
            or_(
                and_(Block.blocker_id == blocker_id, Block.blocked_id == blocked_id),
                and_(Block.blocker_id == blocked_id, Block.blocked_id == blocker_id),
            )
        )
    )
    return result.scalars().first() is not None
