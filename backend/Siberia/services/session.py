#services/session.py
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from fastapi import HTTPException

from models.session import Session
from utils.redis import mark_session_revoked
from config import settings


def _access_ttl_seconds() -> int:
    return max(60, settings.ACCESS_TOKEN_EXPIRE_DAYS * 86400)


async def get_user_sessions(db: AsyncSession, user_id: int):
    result = await db.execute(
        select(Session).where(Session.user_id == user_id)
    )
    return result.scalars().all()


async def delete_session(db: AsyncSession, user_id: int, session_id: int):
    result = await db.execute(
        select(Session).where(
            Session.id == session_id,
            Session.user_id == user_id
        )
    )
    session = result.scalars().first()

    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    sid = session.id
    await db.delete(session)
    await db.commit()
    await mark_session_revoked(sid, _access_ttl_seconds())


async def delete_all_sessions(db: AsyncSession, user_id: int, current_session_id: int):
    result = await db.execute(
        select(Session).where(Session.user_id == user_id)
    )
    sessions = result.scalars().all()

    revoked: list[int] = []
    for session in sessions:
        if session.id != current_session_id:
            revoked.append(session.id)
            await db.delete(session)

    await db.commit()
    ttl = _access_ttl_seconds()
    for sid in revoked:
        await mark_session_revoked(sid, ttl)
