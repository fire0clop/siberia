#utils/jwt.py
from datetime import datetime, timedelta, timezone
from jose import jwt
import uuid

from config import settings


def create_token(data: dict, expires_days: int):
    to_encode = data.copy()

    expire = datetime.now(timezone.utc) + timedelta(days=expires_days)

    to_encode.update({
        "exp": expire,
        "jti": str(uuid.uuid4())
    })

    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def create_access_token(user_id: int, session_id: int):
    return create_token(
        {
            "sub": str(user_id),
            "type": "access",
            "session_id": session_id
        },
        settings.ACCESS_TOKEN_EXPIRE_DAYS
    )


def create_refresh_token(user_id: int, session_id: int):
    return create_token(
        {
            "sub": str(user_id),
            "type": "refresh",
            "session_id": session_id
        },
        settings.REFRESH_TOKEN_EXPIRE_DAYS
    )


def decode_token(token: str):
    return jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])