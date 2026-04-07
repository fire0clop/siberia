from pydantic import BaseModel, ConfigDict
from datetime import datetime
from typing import Optional


class SearchHit(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    chat_id: int
    user_id: Optional[int] = None
    text: Optional[str] = None
    created_at: datetime
    edited_at: Optional[datetime] = None


class MessageSearchResponse(BaseModel):
    results: list[SearchHit]
