import asyncio
import random
import string
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy import asc, delete as sa_delete
from fastapi import HTTPException

from models.user import User
from models.session import Session
from models.email_verification import EmailVerification
from models.login_event import LoginEvent
from models.push_token import PushToken

from services.security import hash_password, verify_password
from utils.jwt import create_access_token, create_refresh_token, decode_token
from utils.redis import mark_session_revoked
from config import settings


MAX_SESSIONS = settings.MAX_SESSIONS
_VERIFY_TTL_MINUTES = settings.VERIFY_CODE_TTL_MINUTES


def _access_token_ttl_seconds() -> int:
    return max(60, settings.ACCESS_TOKEN_EXPIRE_DAYS * 86400)


async def _revoke_sessions_in_redis(session_ids: list[int]) -> None:
    ttl = _access_token_ttl_seconds()
    for sid in session_ids:
        await mark_session_revoked(sid, ttl)


# ── Email verification ────────────────────────────────────────────────────────

def _gen_code() -> str:
    return "".join(random.choices(string.digits, k=6))


async def send_verification_email(db: AsyncSession, user: User) -> None:
    from services.email_service import send_verification_code

    # Invalidate previous unused codes
    await db.execute(
        sa_delete(EmailVerification).where(
            EmailVerification.user_id == user.id,
            EmailVerification.used.is_(False),
        )
    )
    code = _gen_code()
    expires = datetime.now(timezone.utc) + timedelta(minutes=_VERIFY_TTL_MINUTES)
    db.add(EmailVerification(user_id=user.id, code=code, expires_at=expires))
    await db.commit()

    asyncio.create_task(send_verification_code(user.email, code))


async def verify_email_code(db: AsyncSession, user_id: int, code: str) -> None:
    from utils.redis import (
        verify_attempts_inc, verify_attempts_reset,
        verify_set_lockout, verify_is_locked,
    )

    if await verify_is_locked(user_id):
        raise HTTPException(
            status_code=429,
            detail=f"Too many wrong codes. Try again in {settings.VERIFY_CODE_LOCKOUT_MINUTES} minutes.",
        )

    result = await db.execute(
        select(EmailVerification).where(
            EmailVerification.user_id == user_id,
            EmailVerification.code == code,
            EmailVerification.used.is_(False),
        )
    )
    ev = result.scalars().first()
    if not ev or ev.expires_at < datetime.now(timezone.utc):
        # Wrong / expired — count attempt
        attempts = await verify_attempts_inc(
            user_id, ttl_seconds=settings.VERIFY_CODE_LOCKOUT_MINUTES * 60
        )
        if attempts >= settings.VERIFY_CODE_MAX_ATTEMPTS:
            await verify_set_lockout(
                user_id, ttl_seconds=settings.VERIFY_CODE_LOCKOUT_MINUTES * 60
            )
            raise HTTPException(
                status_code=429,
                detail=f"Too many wrong codes. Locked out for {settings.VERIFY_CODE_LOCKOUT_MINUTES} minutes.",
            )
        raise HTTPException(status_code=400, detail="Invalid or expired code")

    ev.used = True
    user = await db.get(User, user_id)
    if user:
        user.email_verified = True
    await db.commit()
    await verify_attempts_reset(user_id)


# ── Login history ─────────────────────────────────────────────────────────────

async def _log_login(
    db: AsyncSession,
    user_id: int | None,
    ip: str | None,
    user_agent: str | None,
    success: bool,
) -> None:
    db.add(LoginEvent(user_id=user_id, ip=ip, user_agent=user_agent, success=success))
    await db.flush()


async def _check_new_device(
    db: AsyncSession,
    user: User,
    ip: str | None,
    user_agent: str | None,
) -> bool:
    """Returns True if this IP has never been used for a successful login before."""
    if not ip:
        return False
    result = await db.execute(
        select(LoginEvent).where(
            LoginEvent.user_id == user.id,
            LoginEvent.ip == ip,
            LoginEvent.success.is_(True),
        )
    )
    return result.scalars().first() is None


# ── Strict refresh token rotation (P8.3) ─────────────────────────────────────

async def _invalidate_session_on_token_reuse(db: AsyncSession, user_id: int) -> None:
    """Called when a stale refresh token is used — signs out all sessions."""
    result = await db.execute(
        select(Session.id).where(Session.user_id == user_id)
    )
    session_ids = [row[0] for row in result.all()]
    await db.execute(
        sa_delete(Session).where(Session.user_id == user_id)
    )
    await db.commit()
    await _revoke_sessions_in_redis(session_ids)


# ── TOTP helpers (P8.2) ───────────────────────────────────────────────────────

def create_pre_auth_token(user_id: int, session_id: int) -> str:
    from datetime import timedelta
    from config import settings
    from jose import jwt
    import uuid
    expire = datetime.now(timezone.utc) + timedelta(minutes=5)
    payload = {
        "sub": str(user_id),
        "type": "pre_auth",
        "session_id": session_id,
        "exp": expire,
        "jti": str(uuid.uuid4()),
    }
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


# ── Core auth functions ───────────────────────────────────────────────────────

async def register_user(
    db: AsyncSession,
    email: str,
    nickname: str,
    password: str,
) -> User:
    result = await db.execute(select(User).where(User.email == email))
    if result.scalars().first():
        raise HTTPException(status_code=400, detail="Email already exists")

    result = await db.execute(select(User).where(User.nickname == nickname))
    if result.scalars().first():
        raise HTTPException(status_code=400, detail="Nickname already exists")

    user = User(email=email, nickname=nickname, password=hash_password(password))
    db.add(user)
    await db.commit()
    await db.refresh(user)

    # Send verification email as fire-and-forget
    await send_verification_email(db, user)

    return user


async def authenticate_user(db: AsyncSession, email: str, password: str) -> User | None:
    result = await db.execute(
        select(User).where(User.email == email, User.deleted_at.is_(None))
    )
    user = result.scalars().first()
    if not user or not verify_password(password, user.password):
        return None
    return user


async def create_tokens(
    db: AsyncSession,
    user_id: int,
    device_id: str | None,
    user_agent: str | None = None,
    ip: str | None = None,
) -> tuple[str, str]:
    result = await db.execute(
        select(Session)
        .where(Session.user_id == user_id)
        .order_by(asc(Session.created_at))
        .with_for_update()
    )
    sessions = result.scalars().all()

    evicted_id: int | None = None
    if len(sessions) >= MAX_SESSIONS:
        evicted_id = sessions[0].id
        await db.delete(sessions[0])
        await db.flush()

    result = await db.execute(
        select(Session).where(
            Session.user_id == user_id,
            Session.device_id == device_id,
        )
    )
    session = result.scalars().first()

    if not session:
        session = Session(user_id=user_id, device_id=device_id, user_agent=user_agent)
        db.add(session)
        await db.flush()

    if evicted_id is not None and evicted_id != session.id:
        await _revoke_sessions_in_redis([evicted_id])

    access = create_access_token(user_id, session.id)
    refresh = create_refresh_token(user_id, session.id)

    session.refresh_token = refresh
    session.last_active = datetime.now(timezone.utc)

    await db.commit()
    return access, refresh


async def login_user(
    db: AsyncSession,
    email: str,
    password: str,
    device_id: str | None,
    user_agent: str | None,
    ip: str | None,
) -> dict:
    """
    Returns one of:
    - {"access_token", "refresh_token", "user"} — normal login
    - {"requires_2fa": True, "temp_token"} — 2FA pending
    """
    user = await authenticate_user(db, email, password)

    if not user:
        await _log_login(db, None, ip, user_agent, success=False)
        await db.commit()
        raise HTTPException(status_code=401, detail="Invalid credentials")

    # Check BEFORE logging so the new event doesn't pollute the history check
    is_new_device = await _check_new_device(db, user, ip, user_agent)

    await _log_login(db, user.id, ip, user_agent, success=True)
    await db.commit()

    if is_new_device and user.email_verified:
        from services.email_service import send_new_device_alert
        asyncio.create_task(send_new_device_alert(user.email, ip or "unknown", user_agent or ""))

    # If 2FA is enabled, issue a short-lived pre-auth token instead
    if user.totp_secret:
        # Create session first so temp_token has a session_id
        result = await db.execute(
            select(Session)
            .where(Session.user_id == user.id)
            .order_by(asc(Session.created_at))
            .with_for_update()
        )
        sessions = result.scalars().all()
        evicted_id_2fa: int | None = None
        if len(sessions) >= MAX_SESSIONS:
            evicted_id_2fa = sessions[0].id
            await db.delete(sessions[0])
            await db.flush()

        result = await db.execute(
            select(Session).where(
                Session.user_id == user.id,
                Session.device_id == device_id,
            )
        )
        session = result.scalars().first()
        if not session:
            session = Session(user_id=user.id, device_id=device_id, user_agent=user_agent)
            db.add(session)
            await db.flush()

        await db.commit()
        if evicted_id_2fa is not None and evicted_id_2fa != session.id:
            await _revoke_sessions_in_redis([evicted_id_2fa])
        temp = create_pre_auth_token(user.id, session.id)
        return {"requires_2fa": True, "temp_token": temp}

    access, refresh = await create_tokens(db, user.id, device_id, user_agent, ip)
    return {"access_token": access, "refresh_token": refresh, "user": user}


async def complete_2fa_login(
    db: AsyncSession,
    temp_token: str,
    totp_code: str,
    device_id: str | None,
    user_agent: str | None,
) -> tuple[str, str, User]:
    try:
        payload = decode_token(temp_token)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid temp token")

    if payload.get("type") != "pre_auth":
        raise HTTPException(status_code=401, detail="Invalid token type")

    user_id = int(payload["sub"])
    user = await db.get(User, user_id)
    if not user or user.deleted_at is not None:
        raise HTTPException(status_code=401, detail="User not found")
    if not user.totp_secret:
        raise HTTPException(status_code=400, detail="2FA is not enabled")

    import pyotp
    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(totp_code, valid_window=1):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    access, refresh = await create_tokens(db, user.id, device_id, user_agent)
    return access, refresh, user


async def setup_totp(db: AsyncSession, user_id: int) -> dict:
    import pyotp
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    secret = pyotp.random_base32()
    totp = pyotp.TOTP(secret)
    app_name = "Siberia"
    qr_url = totp.provisioning_uri(name=user.email, issuer_name=app_name)

    # Store secret but don't activate 2FA until confirmed
    user.totp_secret = f"pending:{secret}"
    await db.commit()

    return {"secret": secret, "qr_url": qr_url}


async def confirm_totp(db: AsyncSession, user_id: int, totp_code: str) -> None:
    import pyotp
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    if not user.totp_secret or not user.totp_secret.startswith("pending:"):
        raise HTTPException(status_code=400, detail="Run /auth/2fa/setup first")

    secret = user.totp_secret[len("pending:"):]
    totp = pyotp.TOTP(secret)
    if not totp.verify(totp_code, valid_window=1):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    user.totp_secret = secret
    await db.commit()


async def disable_totp(db: AsyncSession, user_id: int, totp_code: str) -> None:
    import pyotp
    user = await db.get(User, user_id)
    if not user or not user.totp_secret or user.totp_secret.startswith("pending:"):
        raise HTTPException(status_code=400, detail="2FA is not enabled")

    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(totp_code, valid_window=1):
        raise HTTPException(status_code=401, detail="Invalid TOTP code")

    user.totp_secret = None
    await db.commit()


async def refresh_tokens(db: AsyncSession, refresh_token: str, device_id: str | None) -> tuple[str, str]:
    try:
        payload = decode_token(refresh_token)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")

    if payload.get("type") != "refresh":
        raise HTTPException(status_code=401, detail="Invalid token type")

    session_id = payload.get("session_id")
    result = await db.execute(select(Session).where(Session.id == session_id))
    session = result.scalars().first()

    if not session:
        raise HTTPException(status_code=401, detail="Session not found")

    # P8.3: strict rotation — if token doesn't match, token was already rotated → nuke all sessions
    if session.refresh_token != refresh_token:
        await _invalidate_session_on_token_reuse(db, session.user_id)
        raise HTTPException(status_code=401, detail="Refresh token already used — all sessions revoked")

    if device_id and session.device_id != device_id:
        raise HTTPException(status_code=401, detail="Invalid device")

    user_id = session.user_id

    # P8.3: Clear old token BEFORE issuing new one
    session.refresh_token = None
    await db.flush()

    new_access = create_access_token(user_id, session.id)
    new_refresh = create_refresh_token(user_id, session.id)

    session.refresh_token = new_refresh
    session.last_active = datetime.now(timezone.utc)
    await db.commit()

    return new_access, new_refresh


async def logout_user(db: AsyncSession, refresh_token: str) -> None:
    result = await db.execute(
        select(Session).where(Session.refresh_token == refresh_token)
    )
    session = result.scalars().first()
    if session:
        sid = session.id
        await db.delete(session)
        await db.commit()
        await _revoke_sessions_in_redis([sid])


async def change_password(
    db: AsyncSession,
    user_id: int,
    current_password: str,
    new_password: str,
    current_session_id: int,
) -> None:
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not verify_password(current_password, user.password):
        raise HTTPException(status_code=401, detail="Wrong current password")

    user.password = hash_password(new_password)

    # Revoke all sessions except current
    revoked_ids_result = await db.execute(
        select(Session.id).where(
            Session.user_id == user_id,
            Session.id != current_session_id,
        )
    )
    revoked_ids = [row[0] for row in revoked_ids_result.all()]
    await db.execute(
        sa_delete(Session).where(
            Session.user_id == user_id,
            Session.id != current_session_id,
        )
    )
    await db.commit()
    await _revoke_sessions_in_redis(revoked_ids)


async def delete_account(db: AsyncSession, user_id: int) -> None:
    user = await db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    now = datetime.now(timezone.utc)
    user.deleted_at = now
    user.email = f"deleted_{user_id}@deleted.local"
    user.nickname = f"Deleted_{user_id}"
    user.bio = None
    user.avatar_media_id = None
    user.totp_secret = None

    # Revoke all sessions
    sids_result = await db.execute(select(Session.id).where(Session.user_id == user_id))
    sids = [row[0] for row in sids_result.all()]
    await db.execute(sa_delete(Session).where(Session.user_id == user_id))
    # Remove all push tokens
    await db.execute(sa_delete(PushToken).where(PushToken.user_id == user_id))

    await db.commit()
    await _revoke_sessions_in_redis(sids)
