#schemas/session.py
from pydantic import BaseModel, ConfigDict
from datetime import datetime


class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    device_id: str
    user_agent: str | None
    created_at: datetime
    last_active: datetime