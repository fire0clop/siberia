from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import or_, and_, not_, exists

from models.user import User
from models.block import Block


async def search_users(db: AsyncSession, query: str, searcher_id: int | None = None):
    """Search by nickname or @username. Hides users who blocked searcher or were blocked by searcher."""
    like = f"%{query}%"
    bare_like = f"%{query.lstrip('@')}%"

    stmt = (
        select(User)
        .where(
            User.deleted_at.is_(None),
            or_(
                User.nickname.ilike(like),
                User.username.ilike(bare_like),
            ),
        )
    )

    if searcher_id is not None:
        # Exclude users who have a block relationship with the searcher
        stmt = stmt.where(
            not_(
                exists(
                    select(Block.id).where(
                        or_(
                            and_(Block.blocker_id == searcher_id, Block.blocked_id == User.id),
                            and_(Block.blocker_id == User.id, Block.blocked_id == searcher_id),
                        )
                    )
                )
            ),
            User.id != searcher_id,
        )

    stmt = stmt.limit(50)
    result = await db.execute(stmt)
    return result.scalars().all()
