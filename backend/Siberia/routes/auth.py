from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi_limiter.depends import RateLimiter
from pyrate_limiter import Duration, InMemoryBucket, Limiter, Rate
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from schemas.user import (
    UserCreate,
    UserLogin,
    Token,
    AuthResponse,
    RefreshRequest,
    EmailVerifyRequest,
    TotpSetupResponse,
    TotpConfirmRequest,
    TotpVerifyRequest,
)
from utils.deps import get_current_user

from services.auth import (
    register_user,
    login_user,
    create_tokens,
    refresh_tokens,
    logout_user,
    verify_email_code,
    send_verification_email,
    setup_totp,
    confirm_totp,
    disable_totp,
    complete_2fa_login,
)

router = APIRouter(prefix="/auth", tags=["Auth"])

_strict_limiter = Limiter(InMemoryBucket([Rate(10, Duration.MINUTE)]))
_refresh_limiter = Limiter(InMemoryBucket([Rate(60, Duration.MINUTE)]))
_verify_limiter = Limiter(InMemoryBucket([Rate(10, Duration.MINUTE)]))

_limit_strict = [Depends(RateLimiter(limiter=_strict_limiter))]
_limit_refresh = [Depends(RateLimiter(limiter=_refresh_limiter))]
_limit_verify = [Depends(RateLimiter(limiter=_verify_limiter))]


@router.post("/register", response_model=AuthResponse, dependencies=_limit_strict)
async def register(data: UserCreate, request: Request, db: AsyncSession = Depends(get_db)):
    user = await register_user(db, data.email, data.nickname, data.password)

    device_id = request.headers.get("X-Device-ID")
    user_agent = request.headers.get("User-Agent")
    ip = request.client.host if request.client else None

    access, refresh = await create_tokens(db, user.id, device_id, user_agent, ip)

    return AuthResponse(
        access_token=access,
        refresh_token=refresh,
        user=user,
    )


@router.post("/login", response_model=AuthResponse, dependencies=_limit_strict)
async def login(data: UserLogin, request: Request, db: AsyncSession = Depends(get_db)):
    user_agent = request.headers.get("User-Agent")
    device_id = request.headers.get("X-Device-ID") or data.device_id
    ip = request.client.host if request.client else None

    result = await login_user(db, data.email, data.password, device_id, user_agent, ip)

    if result.get("requires_2fa"):
        return AuthResponse(requires_2fa=True, temp_token=result["temp_token"])

    user = result["user"]
    return AuthResponse(
        access_token=result["access_token"],
        refresh_token=result["refresh_token"],
        user=user,
    )


@router.post("/refresh", response_model=Token, dependencies=_limit_refresh)
async def refresh(data: RefreshRequest, db: AsyncSession = Depends(get_db)):
    access, refresh_token = await refresh_tokens(db, data.refresh_token, data.device_id)
    return Token(access_token=access, refresh_token=refresh_token)


@router.post("/logout")
async def logout(data: RefreshRequest, db: AsyncSession = Depends(get_db)):
    await logout_user(db, data.refresh_token)
    return {"detail": "Logged out"}


# ── Email verification ────────────────────────────────────────────────────────

@router.post("/verify-email", dependencies=_limit_verify)
async def verify_email(
    data: EmailVerifyRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await verify_email_code(db, current["user"].id, data.code)
    return {"detail": "Email verified"}


@router.post("/resend-verification", dependencies=_limit_verify)
async def resend_verification(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user = current["user"]
    if user.email_verified:
        raise HTTPException(status_code=400, detail="Email already verified")
    await send_verification_email(db, user)
    return {"detail": "Verification code sent"}


# ── 2FA ───────────────────────────────────────────────────────────────────────

@router.post("/2fa/setup", response_model=TotpSetupResponse)
async def totp_setup(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await setup_totp(db, current["user"].id)


@router.post("/2fa/confirm")
async def totp_confirm(
    data: TotpConfirmRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await confirm_totp(db, current["user"].id, data.totp_code)
    return {"detail": "2FA enabled"}


@router.post("/2fa/verify", response_model=AuthResponse)
async def totp_verify(
    data: TotpVerifyRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    device_id = request.headers.get("X-Device-ID")
    user_agent = request.headers.get("User-Agent")

    access, refresh, user = await complete_2fa_login(
        db, data.temp_token, data.totp_code, device_id, user_agent
    )
    return AuthResponse(access_token=access, refresh_token=refresh, user=user)


@router.delete("/2fa")
async def totp_disable(
    data: TotpConfirmRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await disable_totp(db, current["user"].id, data.totp_code)
    return {"detail": "2FA disabled"}
