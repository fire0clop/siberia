# routes/e2e.py — публичные X25519-ключи устройств для секретных чатов
import base64
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from models.e2e_key import E2EKey

router = APIRouter(prefix="/e2e", tags=["E2E"])


class E2EKeyPut(BaseModel):
    public_key: str = Field(..., min_length=40, max_length=128)


class E2EKeyOut(BaseModel):
    user_id: int
    public_key: str
    updated_at: datetime


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
