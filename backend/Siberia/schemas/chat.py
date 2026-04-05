# schemas/chat.py

from pydantic import BaseModel, ConfigDict, Field
from datetime import datetime
from typing import Optional
from uuid import UUID
from schemas.user import UserOut


class ChatCreate(BaseModel):
    user_id: int  # for private chat creation


class GroupCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=100)
    user_ids: list[int] = Field(..., min_length=1)  # other participants (not creator)
    description: Optional[str] = Field(None, max_length=255)


class ChatPatch(BaseModel):
    title: Optional[str] = Field(None, min_length=1, max_length=100)
    description: Optional[str] = Field(None, max_length=255)
    avatar_media_id: Optional[UUID] = None


class AddMembersRequest(BaseModel):
    user_ids: list[int] = Field(..., min_length=1)


class RoleChangeRequest(BaseModel):
    role: str = Field(..., pattern=r"^(owner|admin|member)$")


class ChatMemberOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user: UserOut
    role: str
    joined_at: datetime


class ChannelCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=100)
    description: Optional[str] = Field(None, max_length=255)
    is_public: bool = True


class ChatOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    type: str
    title: Optional[str]
    description: Optional[str] = None
    avatar_media_id: Optional[UUID] = None
    last_message_id: Optional[int]
    pinned_message_id: Optional[int] = None
    sync_seq: int
    created_at: datetime
    max_members: int
    invite_link: Optional[str] = None
    draft_text: Optional[str] = None
    is_public: bool = False
    subscribers_count: int = 0
