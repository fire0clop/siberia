# routes/e2e.py — публичные X25519-ключи устройств для E2E-чатов
import base64
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from models.e2e_key import E2EKey
from models.e2e_device import E2EDevice

router = APIRouter(prefix="/e2e", tags=["E2E"])


class E2EKeyPut(BaseModel):
    public_key: str = Field(..., min_length=40, max_length=128)


class E2EKeyOut(BaseModel):
    user_id: int
    public_key: str
    updated_at: datetime


class E2EDevicePut(BaseModel):
    device_id: str = Field(..., min_length=1, max_length=128)
    public_key: str = Field(..., min_length=40, max_length=128)


class E2EDeviceOut(BaseModel):
    user_id: int
    device_id: str
    public_key: str


class E2EDeviceListOut(BaseModel):
    user_id: int
    devices: list[E2EDeviceOut]


def _validate_x25519_pub(b64: str) -> None:
    try:
        raw = base64.b64decode(b64, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="public_key must be base64")
    if len(raw) != 32:
        raise HTTPException(status_code=400, detail="X25519 public key must be 32 bytes")


@router.put("/keys", response_model=E2EKeyOut)
async def put_key(
    data: E2EKeyPut,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Публикация identity-ключа устройства (v1: один на пользователя).

    Замена ключа делает СТАРЫЕ секретные чаты нечитаемыми на новых
    устройствах — это осознанное ограничение v1 (нет мультидевайса).
    """
    _validate_x25519_pub(data.public_key)
    user_id = current["user"].id
    row = await db.get(E2EKey, user_id)
    if row is None:
        row = E2EKey(user_id=user_id, public_key=data.public_key)
        db.add(row)
    else:
        row.public_key = data.public_key
        row.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(row)
    return row


@router.get("/keys/{user_id}", response_model=E2EKeyOut)
async def get_key(
    user_id: int,
    _current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    row = await db.get(E2EKey, user_id)
    if row is None:
        raise HTTPException(status_code=404, detail="User has no E2E key")
    return row


@router.put("/devices", response_model=E2EDeviceOut)
async def put_device(
    data: E2EDevicePut,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Регистрация identity-ключа ЭТОГО устройства (мультидевайс, стадия 3).

    Идемпотентно по (user_id, device_id): повторный вызов обновляет ключ,
    например после переустановки на том же device_id.
    """
    _validate_x25519_pub(data.public_key)
    user_id = current["user"].id
    result = await db.execute(
        select(E2EDevice).where(
            E2EDevice.user_id == user_id,
            E2EDevice.device_id == data.device_id,
        )
    )
    row = result.scalars().first()
    if row is None:
        row = E2EDevice(user_id=user_id, device_id=data.device_id, public_key=data.public_key)
        db.add(row)
    else:
        row.public_key = data.public_key
        row.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(row)
    return E2EDeviceOut(user_id=row.user_id, device_id=row.device_id, public_key=row.public_key)


@router.get("/devices/{user_id}", response_model=E2EDeviceListOut)
async def get_devices(
    user_id: int,
    _current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Все устройства пользователя с их публичными ключами (для фанаута)."""
    result = await db.execute(
        select(E2EDevice).where(E2EDevice.user_id == user_id).order_by(E2EDevice.id)
    )
    devices = [
        E2EDeviceOut(user_id=d.user_id, device_id=d.device_id, public_key=d.public_key)
        for d in result.scalars().all()
    ]
    return E2EDeviceListOut(user_id=user_id, devices=devices)
