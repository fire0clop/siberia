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
from datetime import datetime, timezone

from arq import cron
from arq.connections import RedisSettings
from sqlalchemy.future import select

from config import settings
from db import async_session_maker

logger = logging.getLogger(__name__)


# ── Scheduled message delivery ────────────────────────────────────────────────

async def deliver_scheduled_messages(ctx: dict) -> None:
    """Atomically claim due scheduled messages, broadcast them, send push.

    Idempotent under concurrent workers: claiming uses a single
    `UPDATE … SET send_at = NULL WHERE send_at <= now() RETURNING id`,
    so each message can be claimed by at most one worker.
    """
    from sqlalchemy import update as sa_update
    from models.message import Message
    from models.user import User
    from models.chat_update import ChatUpdateEventType
    from services.sync_engine import lock_chat_row, log_update_on_locked_chat, build_envelope, broadcast_envelope
    from services.push_dispatcher import dispatch_push_for_message

    # Atomic claim — guarantees at-most-once delivery across multiple workers
    async with async_session_maker() as db:
        now = datetime.now(timezone.utc)
        result = await db.execute(
            sa_update(Message)
            .where(
                Message.send_at.isnot(None),
                Message.send_at <= now,
                Message.deleted_at.is_(None),
            )
            .values(send_at=None)
            .returning(Message.id)
        )
        due_ids = [row[0] for row in result.all()]
        await db.commit()

    if not due_ids:
        return

    delivered = 0
    for msg_id in due_ids:
        # Each message gets its own transaction so a failure doesn't poison others
        try:
            async with async_session_maker() as db:
                msg = await db.get(Message, msg_id)
                if not msg:
                    continue  # message was deleted between claim and broadcast

                sender = await db.get(User, msg.user_id) if msg.user_id else None
                sender_nickname = sender.nickname if sender else "Channel"

                locked_chat = await lock_chat_row(db, msg.chat_id)
                locked_chat.last_message_id = msg.id

                seq, _ = await log_update_on_locked_chat(
                    db, locked_chat, ChatUpdateEventType.message_new, msg.id, {}
                )
                await db.commit()

                # Broadcast and push are best-effort; failures don't need rollback
                env = build_envelope(msg.chat_id, seq, ChatUpdateEventType.message_new, msg.id, {})
                await broadcast_envelope(msg.chat_id, env)

                asyncio.create_task(dispatch_push_for_message(
                    chat_id=msg.chat_id,
                    message_id=msg.id,
                    sender_id=msg.user_id or 0,
                    sender_nickname=sender_nickname,
                    message_text=msg.text or "",
                ))

                delivered += 1
        except Exception as exc:
            logger.exception("Failed to deliver scheduled msg %d: %s", msg_id, exc)

    if delivered:
        logger.info("Delivered %d scheduled messages", delivered)


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
    functions = [deliver_scheduled_messages, cleanup_expired_verifications]
    cron_jobs = [
        cron(deliver_scheduled_messages, second={0}, run_at_startup=True),
        cron(cleanup_expired_verifications, hour={3}, minute={0}, second={0}),
    ]
    max_jobs = 10
    job_timeout = 300
