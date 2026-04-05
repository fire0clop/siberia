from pydantic import BaseModel, ConfigDict

from schemas.user import UserOut


class FriendRequestOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    request_id: int
    user: UserOut
