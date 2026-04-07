from pydantic import BaseModel, Field
from typing import Any, Optional


class ChatUpdateItem(BaseModel):
    seq: int
    event: str
    message_id: Optional[int] = None
    payload: dict[str, Any] = Field(default_factory=dict)
    created_at: Optional[str] = None


class ChatSyncResponse(BaseModel):
    updates: list[ChatUpdateItem]
    latest_seq: int
