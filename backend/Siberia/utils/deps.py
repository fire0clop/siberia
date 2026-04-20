#utils/deps.py
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select

from db import get_db
from utils.jwt import decode_token
from utils.redis import is_session_revoked
from models.user import User


security = HTTPBearer()


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

    user_id = int(payload.get("sub"))
    session_id = payload.get("session_id")

    if not session_id:
        raise HTTPException(status_code=401, detail="Session not found in token")

    # Session revocation blacklist: после logout / revoke / change password / delete account
    if await is_session_revoked(session_id):
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
