# schemas/call.py
from datetime import datetime
from pydantic import BaseModel, ConfigDict

from models.call import CallType, CallStatus
from schemas.user import UserOut


class CallInitiate(BaseModel):
    callee_id: int
    type: CallType = CallType.audio


class CallOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    caller_id: int
    callee_id: int
    chat_id: int | None
    type: CallType
    status: CallStatus
    started_at: datetime
    accepted_at: datetime | None
    ended_at: datetime | None
    duration_seconds: int | None


class CallWithPeers(CallOut):
    """Расширенный вид — с вложенными User-объектами обеих сторон.
    Используется для входящего звонка (нужно показать имя и аватар звонящего)
    и для истории звонков."""
    caller: UserOut
    callee: UserOut
