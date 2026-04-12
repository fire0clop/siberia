#routes/session.py
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user
from schemas.session import SessionOut

from services.session import (
    get_user_sessions,
    delete_session,
    delete_all_sessions
)

router = APIRouter(prefix="/sessions", tags=["Sessions"])


@router.get("", response_model=list[SessionOut])
async def get_sessions(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    user = current["user"]
    return await get_user_sessions(db, user.id)


@router.delete("/{session_id}")
async def remove_session(
    session_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    user = current["user"]

    await delete_session(db, user.id, session_id)
    return {"detail": "Session removed"}


@router.post("/revoke_all")
async def revoke_all_sessions(
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    user = current["user"]
    current_session_id = current["session_id"]

    await delete_all_sessions(db, user.id, current_session_id)

    return {"detail": "All sessions revoked"}