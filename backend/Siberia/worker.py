"""ARQ background worker.

Run with:
    arq worker.WorkerSettings

Cron tasks:
    deliver_scheduled_messages  — every 60 s
    cleanup_expired_verifications — every 24 h
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

from arq import cron
from arq.connections import RedisSettings

from config import settings
from db import async_session_maker

logger = logging.getLogger(__name__)


# ── Scheduled message delivery ────────────────────────────────────────────────

async def deliver_scheduled_messages(ctx: dict) -> None:
    """Доставка отложек из scheduled_messages (см. services/scheduled.deliver_due).

    Настоящее сообщение создаётся в момент доставки — свежий id, корректная
    позиция в ленте, статусы/конверт/пуш через обычный create_message.
    at-least-once + идемпотентность по client_message_id = effectively-once.
    """
    from services.scheduled import deliver_due

    delivered = await deliver_due(async_session_maker)
    if delivered:
        logger.info("Delivered %d scheduled messages", delivered)


# ── Link preview (OG-теги) ────────────────────────────────────────────────────

async def fetch_link_preview(ctx: dict, message_id: int, url: str) -> None:
    """Скачивает OG-превью первой ссылки сообщения и рассылает его в комнату.

    Ставится из create_message. SSRF-защита и кеш — в services/link_preview.
    Событие не пишется в ChatUpdate-лог: офлайн-клиенты получат превью при
    следующей загрузке истории, онлайн — по лёгкому событию link_preview.
    """
    import json as _json

    from models.message import Message
    from services.link_preview import build_preview_cached
    from utils.redis import publish

    try:
        preview = await build_preview_cached(url)
        if not preview:
            return

        async with async_session_maker() as db:
            msg = await db.get(Message, message_id)
            if msg is None or msg.deleted_at is not None:
                return
            msg.link_preview = preview
            chat_id = msg.chat_id
            await db.commit()

        await publish(f"chat:{chat_id}", _json.dumps({
            "v": 1,
            "type": "link_preview",
            "event": "link_preview",
            "chat_id": chat_id,
            "message_id": message_id,
            "payload": preview,
        }))
    except Exception as exc:
        logger.exception("fetch_link_preview failed msg=%d: %s", message_id, exc)


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


# ── Cleanup expired stories ───────────────────────────────────────────────────

async def cleanup_expired_stories(ctx: dict) -> None:
    """Удаляет сторис старше их expires_at (views каскадом)."""
    from models.story import Story
    from sqlalchemy import delete as sa_delete

    async with async_session_maker() as db:
        now = datetime.now(timezone.utc)
        result = await db.execute(
            sa_delete(Story).where(Story.expires_at < now).returning(Story.id)
        )
        count = len(result.all())
        await db.commit()
    if count:
        logger.info("Cleaned up %d expired stories", count)


# ── Worker settings ───────────────────────────────────────────────────────────

class WorkerSettings:
    redis_settings = RedisSettings.from_dsn(settings.REDIS_URL)
    functions = [deliver_scheduled_messages, fetch_link_preview, expire_stale_calls, cleanup_expired_verifications, cleanup_expired_stories]
    cron_jobs = [
        cron(deliver_scheduled_messages, second={0}, run_at_startup=True),
        cron(expire_stale_calls, second={0, 30}),
        cron(cleanup_expired_verifications, hour={3}, minute={0}, second={0}),
        cron(cleanup_expired_stories, hour={4}, minute={0}, second={0}),
    ]
    max_jobs = 10
    job_timeout = 300
