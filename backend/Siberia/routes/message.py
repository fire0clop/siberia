# routes/message.py

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from db import get_db
from utils.deps import get_current_user

from schemas.message import (
    MessageCreateAuto,
    MessageAutoSendResponse,
    MessagePatch,
    MessageOut,
    ReactionRequest,
)
from services.message import create_message_auto, edit_message, soft_delete_message
from services.reaction_service import add_reaction, remove_reaction

router = APIRouter(prefix="/messages", tags=["Messages"])


@router.post("", response_model=MessageAutoSendResponse)
async def send_message_auto_route(
    data: MessageCreateAuto,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await create_message_auto(
        db,
        current["user"].id,
        data.user_id,
        data.content,
        client_message_id=data.client_message_id,
        reply_to_message_id=data.reply_to_message_id,
    )
    return MessageAutoSendResponse(
        chat_id=result["chat_id"],
        message=result["message"],
        idempotent=result["idempotent"],
    )


@router.patch("/{message_id}", response_model=MessageOut)
async def patch_message(
    message_id: int,
    data: MessagePatch,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await edit_message(
        db,
        current["user"].id,
        message_id,
        data.content,
    )


@router.delete("/{message_id}")
async def delete_message(
    message_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await soft_delete_message(db, current["user"].id, message_id)
    return {"detail": "Message deleted"}


@router.post("/{message_id}/reactions")
async def react_to_message(
    message_id: int,
    data: ReactionRequest,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    reactions = await add_reaction(db, current["user"].id, message_id, data.emoji)
    return {"reactions": reactions}


@router.delete("/{message_id}/reactions")
async def unreact_to_message(
    message_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    reactions = await remove_reaction(db, current["user"].id, message_id)
    return {"reactions": reactions}


@router.delete("/{message_id}/scheduled")
async def cancel_scheduled_message(
    message_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from models.message import Message
    from fastapi import HTTPException
    from datetime import datetime, timezone

    message = await db.get(Message, message_id)
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    if message.user_id != current["user"].id:
        raise HTTPException(status_code=403, detail="Not your message")
    if message.send_at is None or message.send_at <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail="Message is not scheduled or already sent")

    await db.delete(message)
    await db.commit()
    return {"detail": "Scheduled message cancelled"}


@router.get("/{message_id}/history")
async def message_history(
    message_id: int,
    current=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Возвращает историю редактирования сообщения (последняя версия — текущий текст,
    остальные — снимки из message_edit_history)."""
    from models.message import Message
    from models.message_edit_history import MessageEditHistory
    from services.chat import check_user_in_chat
    from fastapi import HTTPException
    from sqlalchemy.future import select

    message = await db.get(Message, message_id)
    if not message or message.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Message not found")

    # Доступ имеет только член чата
    await check_user_in_chat(db, current["user"].id, message.chat_id)

    result = await db.execute(
        select(MessageEditHistory)
        .where(MessageEditHistory.message_id == message_id)
        .order_by(MessageEditHistory.edited_at.asc())
    )
    history = result.scalars().all()

    versions = [
        {"text": h.text, "edited_at": h.edited_at.isoformat() if h.edited_at else None}
        for h in history
    ]
    # Добавляем текущую версию
    versions.append({
        "text": message.text,
        "edited_at": (message.edited_at or message.created_at).isoformat() if (message.edited_at or message.created_at) else None,
    })
    return {"message_id": message_id, "versions": versions}
