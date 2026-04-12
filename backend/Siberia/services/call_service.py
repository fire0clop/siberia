# services/call_service.py
import asyncio
import json
import logging
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy.future import select
from sqlalchemy.orm import selectinload
from sqlalchemy.ext.asyncio import AsyncSession

from db import async_session_maker
from models.call import Call, CallStatus, CallType
from models.user import User
from models.block import Block
from models.push_token import PushToken, PushTokenKind
from services import push_apns
from utils.redis import publish

logger = logging.getLogger("siberia.calls")


# ── Redis pub helpers ────────────────────────────────────────────────────────

def _channel_for(user_id: int) -> str:
    return f"user:{user_id}"


async def _push_to_user(user_id: int, payload: dict) -> None:
    """Публикуем событие в персональный канал /ws/me пользователя."""
    await publish(_channel_for(user_id), json.dumps(payload))


def _serialize_call(call: Call) -> dict:
    return {
        "id": call.id,
        "caller_id": call.caller_id,
        "callee_id": call.callee_id,
        "chat_id": call.chat_id,
        "type": call.type.value if hasattr(call.type, "value") else call.type,
        "status": call.status.value if hasattr(call.status, "value") else call.status,
        "started_at": call.started_at.isoformat() if call.started_at else None,
        "accepted_at": call.accepted_at.isoformat() if call.accepted_at else None,
        "ended_at": call.ended_at.isoformat() if call.ended_at else None,
        "duration_seconds": call.duration_seconds,
    }


def _serialize_user_short(u: User) -> dict:
    return {
        "id": u.id,
        "nickname": u.nickname,
        "email": u.email,
        "avatar_url": getattr(u, "avatar_url", None),
        "bio": getattr(u, "bio", None),
        "email_verified": getattr(u, "email_verified", False),
    }


# ── Initiate ─────────────────────────────────────────────────────────────────

async def initiate_call(
    db: AsyncSession,
    caller_id: int,
    callee_id: int,
    call_type: CallType,
    chat_id: int | None = None,
) -> Call:
    if caller_id == callee_id:
        raise HTTPException(status_code=400, detail="Cannot call yourself")

    # callee существует и не удалён
    callee = await db.get(User, callee_id)
    if not callee or callee.deleted_at is not None:
        raise HTTPException(status_code=404, detail="User not found")

    # Блокировки в обе стороны
    block_check = await db.execute(
        select(Block).where(
            ((Block.blocker_id == caller_id) & (Block.blocked_id == callee_id))
            | ((Block.blocker_id == callee_id) & (Block.blocked_id == caller_id))
        )
    )
    if block_check.scalars().first():
        raise HTTPException(status_code=403, detail="Call not allowed")

    # Есть ли уже активный/звонящий вызов с участием любой из сторон?
    active = await db.execute(
        select(Call).where(
            Call.status.in_([CallStatus.ringing, CallStatus.active]),
            (
                (Call.caller_id.in_([caller_id, callee_id]))
                | (Call.callee_id.in_([caller_id, callee_id]))
            ),
        )
    )
    if active.scalars().first():
        raise HTTPException(status_code=409, detail="Already in a call")

    call = Call(
        caller_id=caller_id,
        callee_id=callee_id,
        chat_id=chat_id,
        type=call_type,
        status=CallStatus.ringing,
        started_at=datetime.now(timezone.utc),
    )
    db.add(call)
    await db.commit()
    await db.refresh(call)

    # Подгружаем caller для отправки callee'у
    caller = await db.get(User, caller_id)

    # Шлём callee «входящий звонок» через WS (если он сейчас онлайн)
    await _push_to_user(callee_id, {
        "type": "call_incoming",
        "call": _serialize_call(call),
        "caller": _serialize_user_short(caller),
    })

    # Параллельно — VoIP push (разбудит фон/убитое приложение и запустит CallKit)
    asyncio.create_task(_send_voip_push_for_call(call, caller))

    return call


# ── VoIP push для входящего звонка ───────────────────────────────────────────

async def _send_voip_push_for_call(call: Call, caller: User) -> None:
    """
    PushKit VoIP-пуш ВСЕМ зарегистрированным VoIP-токенам callee.
    Минимальная нагрузка — call_id + имя + тип. Клиент в ответ обязан
    сразу зарепортить CXProvider'у incoming call (требование Apple).
    """
    try:
        async with async_session_maker() as db:
            result = await db.execute(
                select(PushToken).where(
                    PushToken.user_id == call.callee_id,
                    PushToken.kind == PushTokenKind.voip,
                )
            )
            tokens = result.scalars().all()
    except Exception:
        logger.exception("Failed to load VoIP tokens for user %d", call.callee_id)
        return

    if not tokens:
        logger.info("No VoIP tokens for user %d — push skipped", call.callee_id)
        return

    payload = {
        "call_id":      call.id,
        "caller_id":    caller.id,
        "caller_name":  caller.nickname,
        "caller_avatar": getattr(caller, "avatar_url", None),
        "type":         call.type.value if hasattr(call.type, "value") else call.type,
    }

    for token in tokens:
        try:
            valid = await push_apns.send_voip(token.device_token, payload)
            if not valid:
                async def _clean(tid: int):
                    async with async_session_maker() as db:
                        from sqlalchemy import delete as sa_delete
                        await db.execute(sa_delete(PushToken).where(PushToken.id == tid))
                        await db.commit()
                asyncio.create_task(_clean(token.id))
        except Exception:
            logger.exception("VoIP push send error token=%d", token.id)


# ── Accept / decline / end / cancel ──────────────────────────────────────────

async def _get_call_for_user(db: AsyncSession, call_id: int, user_id: int) -> Call:
    call = await db.get(Call, call_id)
    if not call:
        raise HTTPException(status_code=404, detail="Call not found")
    if user_id not in (call.caller_id, call.callee_id):
        raise HTTPException(status_code=403, detail="Not a participant")
    return call


async def accept_call(db: AsyncSession, call_id: int, user_id: int) -> Call:
    call = await _get_call_for_user(db, call_id, user_id)
    if user_id != call.callee_id:
        raise HTTPException(status_code=403, detail="Only callee can accept")
    if call.status != CallStatus.ringing:
        raise HTTPException(status_code=409, detail=f"Call is {call.status}")

    call.status = CallStatus.active
    call.accepted_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(call)

    await _push_to_user(call.caller_id, {
        "type": "call_accepted",
        "call_id": call.id,
    })
    return call


async def decline_call(db: AsyncSession, call_id: int, user_id: int) -> Call:
    call = await _get_call_for_user(db, call_id, user_id)
    if user_id != call.callee_id:
        raise HTTPException(status_code=403, detail="Only callee can decline")
    if call.status != CallStatus.ringing:
        raise HTTPException(status_code=409, detail=f"Call is {call.status}")

    call.status = CallStatus.declined
    call.ended_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(call)

    await _push_to_user(call.caller_id, {
        "type": "call_declined",
        "call_id": call.id,
    })
    return call


async def cancel_call(db: AsyncSession, call_id: int, user_id: int) -> Call:
    """Caller отменяет звонок до того как callee ответил."""
    call = await _get_call_for_user(db, call_id, user_id)
    if user_id != call.caller_id:
        raise HTTPException(status_code=403, detail="Only caller can cancel")
    if call.status != CallStatus.ringing:
        raise HTTPException(status_code=409, detail=f"Call is {call.status}")

    call.status = CallStatus.cancelled
    call.ended_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(call)

    await _push_to_user(call.callee_id, {
        "type": "call_cancelled",
        "call_id": call.id,
    })
    return call


async def end_call(db: AsyncSession, call_id: int, user_id: int) -> Call:
    call = await _get_call_for_user(db, call_id, user_id)
    if call.status not in (CallStatus.active, CallStatus.ringing):
        raise HTTPException(status_code=409, detail=f"Call is {call.status}")

    now = datetime.now(timezone.utc)
    if call.status == CallStatus.active and call.accepted_at:
        call.duration_seconds = int((now - call.accepted_at).total_seconds())
        call.status = CallStatus.ended
    elif call.status == CallStatus.ringing:
        # ended without ever connecting → missed для callee, cancelled для caller
        call.status = CallStatus.missed if user_id == call.caller_id else CallStatus.declined
    call.ended_at = now
    await db.commit()
    await db.refresh(call)

    peer_id = call.callee_id if user_id == call.caller_id else call.caller_id
    await _push_to_user(peer_id, {
        "type": "call_ended",
        "call_id": call.id,
        "duration_seconds": call.duration_seconds,
    })
    return call


# ── WS signaling relay (offer/answer/ICE) ────────────────────────────────────

async def relay_signal(
    db: AsyncSession,
    sender_id: int,
    call_id: int,
    kind: str,
    payload: dict,
) -> None:
    """Передать SDP/ICE-фрейм пиру через Redis pubsub.
    Сервер ничего не хранит и не модифицирует — только валидирует участников и пересылает."""
    if kind not in ("offer", "answer", "ice"):
        raise HTTPException(status_code=400, detail="Unknown signal kind")

    call = await _get_call_for_user(db, call_id, sender_id)
    if call.status not in (CallStatus.ringing, CallStatus.active):
        return  # тихо игнорируем — звонок уже закрыт

    peer_id = call.callee_id if sender_id == call.caller_id else call.caller_id

    await _push_to_user(peer_id, {
        "type": "call_signal",
        "call_id": call_id,
        "kind": kind,
        "from_user_id": sender_id,
        "payload": payload,
    })


# ── History ──────────────────────────────────────────────────────────────────

async def list_history(db: AsyncSession, user_id: int, limit: int = 50) -> list[Call]:
    result = await db.execute(
        select(Call)
        .where((Call.caller_id == user_id) | (Call.callee_id == user_id))
        .options(selectinload(Call.caller), selectinload(Call.callee))
        .order_by(Call.started_at.desc())
        .limit(limit)
    )
    return list(result.scalars().all())
