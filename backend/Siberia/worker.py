"""ARQ background worker.

Run with:
    arq worker.WorkerSettings

Cron tasks:
    deliver_scheduled_messages  — every 60 s
    cleanup_expired_verifications — every 24 h
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from arq import cron
from arq.connections import RedisSettings

from config import settings
from db import async_session_maker

logger = logging.getLogger(__name__)


# ── Scheduled message delivery ────────────────────────────────────────────────

async def deliver_scheduled_messages(ctx: dict) -> None:
    """Доставка scheduled-сообщений: at-least-once, по одному в транзакции.

    Раньше claim обнулял send_at ДО доставки в отдельной транзакции: упади
    воркер между claim'ом и доставкой — сообщение терялось молча и навсегда.
    Теперь строка захватывается FOR UPDATE SKIP LOCKED, а send_at обнуляется
    в ТОЙ ЖЕ транзакции, что и запись ChatUpdate: краш → rollback → send_at
    цел → ретрай на следующем тике. SKIP LOCKED защищает от двойной доставки
    при нескольких воркерах. «Ядовитое» сообщение (стабильно падающее)
    откладывается на минуту, чтобы не блокировать очередь.
    """
    from sqlalchemy.future import select
    from models.message import Message
    from models.user import User
    from models.chat_update import ChatUpdateEventType
    from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope
    from services.message import _add_statuses_for_new_message, build_message_new_payload
    from services.push_dispatcher import dispatch_push_for_message

    delivered = 0
    # Потолок на тик — защита от бесконечного цикла при аномальной очереди
    for _ in range(500):
        async with async_session_maker() as db:
            now = datetime.now(timezone.utc)
            result = await db.execute(
                select(Message)
                .where(
                    Message.send_at.isnot(None),
                    Message.send_at <= now,
                    Message.deleted_at.is_(None),
                )
                .order_by(Message.send_at)
                .with_for_update(skip_locked=True)
                .limit(1)
            )
            msg = result.scalars().first()
            if msg is None:
                break

            msg_id = msg.id
            try:
                sender = await db.get(User, msg.user_id) if msg.user_id else None
                sender_nickname = sender.nickname if sender else "Channel"

                locked_chat = await lock_chat_row(db, msg.chat_id)
                locked_chat.last_message_id = msg.id

                # Статусы (unread) создаются в момент доставки, а не планирования (H-6)
                await _add_statuses_for_new_message(db, msg.id, msg.chat_id, msg.user_id)

                payload = await build_message_new_payload(db, msg)
                seq, _ = await log_update_on_locked_chat(
                    db, locked_chat, ChatUpdateEventType.message_new, msg.id, payload
                )
                msg.send_at = None  # доставлено — в той же транзакции, что и ChatUpdate
                await db.commit()
            except Exception as exc:
                logger.exception("Failed to deliver scheduled msg %d: %s", msg_id, exc)
                await db.rollback()
                # Откладываем ядовитое сообщение, чтобы не застревать на нём
                try:
                    retry_msg = await db.get(Message, msg_id)
                    if retry_msg is not None and retry_msg.send_at is not None:
                        retry_msg.send_at = datetime.now(timezone.utc) + timedelta(seconds=60)
                        await db.commit()
                except Exception:
                    logger.exception("Failed to defer scheduled msg %d", msg_id)
                continue

            # Broadcast и push — best-effort, уже после коммита
            try:
                env = build_envelope(msg.chat_id, seq, ChatUpdateEventType.message_new, msg.id, payload)
                await broadcast_envelope(msg.chat_id, env)
            except Exception:
                logger.exception("Broadcast failed for scheduled msg %d", msg_id)

            asyncio.create_task(dispatch_push_for_message(
                chat_id=msg.chat_id,
                message_id=msg.id,
                sender_id=msg.user_id or 0,
                sender_nickname=sender_nickname,
                message_text=msg.text or "",
            ))

            delivered += 1

    if delivered:
        logger.info("Delivered %d scheduled messages", delivered)


# ── Expire stale ringing calls ────────────────────────────────────────────────

async def expire_stale_calls(ctx: dict) -> None:
    """Гасит звонки, зависшие в ringing дольше RING_TIMEOUT_SECONDS.

    Без этого один зависший ringing (упавшее приложение звонящего) навсегда
    блокировал звонки обоим участникам — initiate_call отвечал 409, а у callee
    вечно висел входящий.
    """
    from services.call_service import expire_stale_ringing_calls

    try:
        async with async_session_maker() as db:
            stale = await expire_stale_ringing_calls(db)
        if stale:
            logger.info("Expired %d stale ringing calls", len(stale))
    except Exception as exc:
        logger.exception("expire_stale_calls failed: %s", exc)


# ── Cleanup expired verifications ─────────────────────────────────────────────

async def cleanup_expired_verifications(ctx: dict) -> None:
    """Delete expired unused email verification codes."""
    from models.email_verification import EmailVerification
    from sqlalchemy import delete as sa_delete

    async with async_session_maker() as db:
        now = datetime.now(timezone.utc)
        result = await db.execute(
            sa_delete(EmailVerification)
            .where(
                EmailVerification.expires_at < now,
                EmailVerification.used.is_(False),
            )
            .returning(EmailVerification.id)
        )
        count = len(result.all())
        await db.commit()
        logger.info("Cleaned up %d expired email verifications", count)


# ── Worker settings ───────────────────────────────────────────────────────────

class WorkerSettings:
    redis_settings = RedisSettings.from_dsn(settings.REDIS_URL)
    functions = [deliver_scheduled_messages, expire_stale_calls, cleanup_expired_verifications]
    cron_jobs = [
        cron(deliver_scheduled_messages, second={0}, run_at_startup=True),
        cron(expire_stale_calls, second={0, 30}),
        cron(cleanup_expired_verifications, hour={3}, minute={0}, second={0}),
    ]
    max_jobs = 10
    job_timeout = 300
