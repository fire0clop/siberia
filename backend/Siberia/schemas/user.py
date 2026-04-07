from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, EmailStr, ConfigDict, Field


class UserCreate(BaseModel):
    email: EmailStr
    nickname: str = Field(..., min_length=1, max_length=50)
    password: str = Field(..., min_length=8, max_length=128)


class UserLogin(BaseModel):
    email: EmailStr
    password: str
    device_id: Optional[str] = None


class Token(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshRequest(BaseModel):
    refresh_token: str
    device_id: Optional[str] = None


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    public_id: str
    email: EmailStr
    nickname: str
    username: Optional[str] = None
    bio: Optional[str] = None
    avatar_media_id: Optional[UUID] = None
    avatar_url: Optional[str] = None
    last_seen_at: Optional[datetime] = None
    email_verified: bool = False


class UserPatch(BaseModel):
    nickname: Optional[str] = Field(None, min_length=1, max_length=50)
    bio: Optional[str] = Field(None, max_length=200)


class AvatarPatch(BaseModel):
    media_id: str


class UsernamePatch(BaseModel):
    username: str = Field(
        ...,
        min_length=3,
        max_length=32,
        pattern=r"^[a-zA-Z0-9_]+$",
    )


class PrivacySettingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    last_seen: str
    avatar: str
    messages_from: str
    invisible_mode: bool = False


class PrivacySettingPatch(BaseModel):
    last_seen: Optional[str] = Field(None, pattern=r"^(everyone|friends|nobody)$")
    avatar: Optional[str] = Field(None, pattern=r"^(everyone|friends|nobody)$")
    messages_from: Optional[str] = Field(None, pattern=r"^(everyone|friends|nobody)$")
    invisible_mode: Optional[bool] = None


class UserPresence(BaseModel):
    user_id: int
    online: bool
    last_seen_at: Optional[datetime] = None


class PasswordChange(BaseModel):
    current_password: str
    new_password: str = Field(..., min_length=8, max_length=128)


class EmailVerifyRequest(BaseModel):
    code: str = Field(..., min_length=6, max_length=6)


class TotpSetupResponse(BaseModel):
    secret: str
    qr_url: str


class TotpConfirmRequest(BaseModel):
    totp_code: str = Field(..., min_length=6, max_length=6)


class TotpVerifyRequest(BaseModel):
    temp_token: str
    totp_code: str = Field(..., min_length=6, max_length=6)


class LoginHistoryItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    ip: Optional[str] = None
    user_agent: Optional[str] = None
    success: bool
    created_at: datetime


class AuthResponse(BaseModel):
    access_token: Optional[str] = None
    refresh_token: Optional[str] = None
    token_type: str = "bearer"
    user: Optional[UserOut] = None
    requires_2fa: bool = False
    temp_token: Optional[str] = None
