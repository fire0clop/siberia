#utils/deps.py
import logging

from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from db import get_db
from utils.jwt import decode_token
from utils.redis import is_session_revoked
from models.user import User

logger = logging.getLogger(__name__)

security = HTTPBearer()


async def check_session_revoked(db: AsyncSession, session_id) -> bool:
    """Проверка отзыва сессии: Redis (быстрый путь) с fallback на БД.

    Redis — только blacklist-кеш; источник правды — таблица sessions
    (logout/revoke/kick УДАЛЯЮТ строку). Раньше недоступный Redis ронял
    каждый авторизованный запрос 500-кой; теперь при его отказе смотрим
    в БД: строки нет → сессия отозвана.
    """
    try:
        return await is_session_revoked(session_id)
    except Exception as exc:
        logger.warning("Redis unavailable for revocation check (%s) — falling back to DB", exc)
        try:
            sid = int(session_id)
        except (TypeError, ValueError):
            return True
        from models.session import Session
        result = await db.execute(select(Session.id).where(Session.id == sid))
        return result.scalar() is None


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db)
):
    token = credentials.credentials

    try:
        payload = decode_token(token)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")

    if payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Invalid token type")

    try:
        user_id = int(payload.get("sub"))
    except (TypeError, ValueError):
        # Битый sub — невалидный токен (401), а не наша ошибка (500)
        raise HTTPException(status_code=401, detail="Invalid token")
    session_id = payload.get("session_id")

    if not session_id:
        raise HTTPException(status_code=401, detail="Session not found in token")

    # Session revocation blacklist: после logout / revoke / change password / delete account
    if await check_session_revoked(db, session_id):
        raise HTTPException(status_code=401, detail="Session revoked")

    result = await db.execute(
        select(User).where(User.id == user_id, User.deleted_at.is_(None))
    )
    user = result.scalars().first()

    if not user:
        raise HTTPException(status_code=401, detail="User not found")

    return {
        "user": user,
        "session_id": session_id
    }
