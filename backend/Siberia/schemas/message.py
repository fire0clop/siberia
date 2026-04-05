from pydantic import BaseModel, ConfigDict, Field, model_validator
from datetime import datetime
from typing import Optional
from uuid import UUID


class MediaOut(BaseModel):
    id: str
    type: str
    mime_type: str
    size_bytes: int
    duration_sec: Optional[int] = None
    width: Optional[int] = None
    height: Optional[int] = None
    original_name: Optional[str] = None


class MessageCreate(BaseModel):
    content: Optional[str] = Field(None, min_length=1, max_length=4096)
    media_id: Optional[UUID] = None
    client_message_id: Optional[UUID] = None
    reply_to_message_id: Optional[int] = None
    forward_message_id: Optional[int] = None
    send_at: Optional[datetime] = None

    @model_validator(mode="after")
    def content_or_media_or_forward_required(self) -> "MessageCreate":
        if not self.content and not self.media_id and not self.forward_message_id:
            raise ValueError("Either content, media_id, or forward_message_id must be provided")
        return self


class MessageCreateAuto(BaseModel):
    user_id: int
    content: str = Field(..., min_length=1, max_length=4096)
    client_message_id: Optional[UUID] = None
    reply_to_message_id: Optional[int] = None


class MessagePatch(BaseModel):
    content: str = Field(..., min_length=1, max_length=4096)


class ReactionRequest(BaseModel):
    emoji: str = Field(..., min_length=1, max_length=8)


class MessageOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    chat_id: int
    user_id: Optional[int] = None
    type: str = "text"
    text: Optional[str] = None
    media_id: Optional[UUID] = None
    media_type: Optional[str] = None
    reply_to_message_id: Optional[int] = None
    forwarded_from_message_id: Optional[int] = None
    forwarded_from_user_id: Optional[int] = None
    forwarded_from_chat_id: Optional[int] = None
    mention_user_ids: Optional[list[int]] = None
    reactions: Optional[dict[str, int]] = None
    send_at: Optional[datetime] = None
    created_at: datetime
    edited_at: Optional[datetime] = None
    deleted_at: Optional[datetime] = None


class MessageSendResponse(BaseModel):
    message: MessageOut
    idempotent: bool = False


class MessageAutoSendResponse(BaseModel):
    chat_id: int
    message: MessageOut
    idempotent: bool = False


class BulkReadRequest(BaseModel):
    up_to_message_id: int
