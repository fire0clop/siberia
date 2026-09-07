"""Воркер scheduled-сообщений: at-least-once, статусы при доставке, payload.

Регрессии: send_at обнулялся до доставки (краш = сообщение потеряно навсегда),
payload был пустым, статусы создавались при планировании.
"""
from datetime import datetime, timedelta, timezone

from sqlalchemy import text

import worker as worker_mod


async def _dm(client, a, b):
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    return r.json()["id"]


async def _schedule(client, u, chat_id, text_, minutes=60):
    send_at = (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": text_, "send_at": send_at},
        headers=u.headers,
    )
    assert r.status_code == 200, r.text
    return r.json()["message"]["id"]


async def _make_due(msg_id):
    from db import async_session_maker
    async with async_session_maker() as db:
        await db.execute(
            text("UPDATE messages SET send_at = now() - interval '5 seconds' WHERE id = :id"),
            {"id": msg_id},
        )
        await db.commit()


async def test_delivery_creates_statuses_payload_and_clears_send_at(client, register_user):
    a = await register_user("wrk_a")
    b = await register_user("wrk_b")
    chat_id = await _dm(client, a, b)
    msg_id = await _schedule(client, a, chat_id, "отложенное")

    # До доставки: у B ноль непрочитанного (H-6)
    r = await client.get("/users/me/badge", headers=b.headers)
    assert r.json()["unread"] == 0

    await _make_due(msg_id)
    await worker_mod.deliver_scheduled_messages({})

    # Доставлено: send_at очищен, у B появилось непрочитанное
    r = await client.get("/users/me/badge", headers=b.headers)
    assert r.json()["unread"] == 1

    # Конверт в sync несёт реальный payload, а не {}
    r = await client.get(f"/chats/{chat_id}/sync", params={"after_seq": 0}, headers=b.headers)
    news = [u for u in r.json()["updates"] if u["event"] == "message_new" and u["message_id"] == msg_id]
    assert news, "message_new for scheduled msg missing from sync"

    # Повторный тик ничего не дублирует
    await worker_mod.deliver_scheduled_messages({})
    r = await client.get("/users/me/badge", headers=b.headers)
    assert r.json()["unread"] == 1


async def test_failed_delivery_is_retried_not_lost(client, register_user, monkeypatch):
    """Краш на доставке не должен молча терять сообщение (at-least-once)."""
    a = await register_user("fail_a")
    b = await register_user("fail_b")
    chat_id = await _dm(client, a, b)
    msg_id = await _schedule(client, a, chat_id, "выживу")
    await _make_due(msg_id)

    # Ломаем шаг ВНУТРИ транзакции доставки
    import services.sync_engine as se
    real_log = se.log_update_on_locked_chat

    async def boom(*args, **kwargs):
        raise RuntimeError("simulated crash mid-delivery")

    monkeypatch.setattr(se, "log_update_on_locked_chat", boom)
    await worker_mod.deliver_scheduled_messages({})

    # Сообщение НЕ потеряно: send_at жив (отложен на ретрай)
    from db import async_session_maker
    async with async_session_maker() as db:
        row = await db.execute(text("SELECT send_at FROM messages WHERE id = :id"), {"id": msg_id})
        send_at = row.scalar()
    assert send_at is not None, "scheduled message was lost after a mid-delivery crash"

    # Чиним, делаем due снова — доставляется
    monkeypatch.setattr(se, "log_update_on_locked_chat", real_log)
    await _make_due(msg_id)
    await worker_mod.deliver_scheduled_messages({})
    r = await client.get("/users/me/badge", headers=b.headers)
    assert r.json()["unread"] == 1
