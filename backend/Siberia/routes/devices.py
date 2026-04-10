"""
Регистрация push-токенов устройств.

POST /devices/push-token  — сохранить/обновить токен текущей сессии
DELETE /devices/push-token — удалить токен (вызывать при logout на клиенте)
"""
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.future import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from db import get_db
from models.push_token import PushToken, PushPlatform, PushTokenKind
from utils.deps import get_current_user

router = APIRouter(prefix="/devices", tags=["Devices"])


class PushTokenRegister(BaseModel):
    device_token: str
    platform: PushPlatform                       # ios | android
    kind: PushTokenKind = PushTokenKind.apns     # apns | voip | fcm


class PushTokenDelete(BaseModel):
    device_token: str


@router.post("/push-token", status_code=200)
async def register_push_token(
    data: PushTokenRegister,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Клиент вызывает при каждом запуске приложения для каждого вида токена
    (один раз для обычного APNs, второй раз — для PushKit VoIP).
    Upsert: если токен уже есть — обновляем session_id, platform, kind.
    """
    user = current["user"]
    session_id = current["session_id"]

    stmt = (
        pg_insert(PushToken)
        .values(
            user_id=user.id,
            session_id=session_id,
            device_token=data.device_token,
            platform=data.platform,
            kind=data.kind,
        )
        .on_conflict_do_update(
            index_elements=["device_token"],
            set_={
                "user_id": user.id,
                "session_id": session_id,
                "platform": data.platform,
                "kind": data.kind,
            },
        )
    )
    await db.execute(stmt)
    await db.commit()
    return {"detail": "Push token registered"}


@router.delete("/push-token", status_code=200)
async def delete_push_token(
    data: PushTokenDelete,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Удалить токен при logout или отключении уведомлений."""
    user = current["user"]
    result = await db.execute(
        select(PushToken).where(
            PushToken.device_token == data.device_token,
            PushToken.user_id == user.id,
        )
    )
    token = result.scalars().first()
    if token:
        await db.delete(token)
        await db.commit()
    return {"detail": "Push token removed"}
