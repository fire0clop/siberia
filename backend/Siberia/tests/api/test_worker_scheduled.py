"""Отложенные сообщения: доставка воркером из scheduled_messages.

Архитектура: до отправки — строка в scheduled_messages; настоящее сообщение
создаётся в момент доставки (свежий id → корректная позиция в ленте),
at-least-once + идемпотентность по client_message_id.
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
    return r.json()["message"]["id"]  # id из пространства scheduled_messages


async def _make_due(scheduled_id):
    from db import async_session_maker
    async with async_session_maker() as db:
        await db.execute(
            text("UPDATE scheduled_messages SET send_at = now() - interval '5 seconds' WHERE id = :id"),
            {"id": scheduled_id},
        )
        await db.commit()


async def test_delivery_creates_fresh_message_at_bottom(client, register_user):
    """Ключевой кейс: доставленная отложка встаёт В КОНЕЦ ленты, а не в глубину
    истории по старому id (прежняя архитектура вставляла строку заранее)."""
    a = await register_user("wrk_a")
    b = await register_user("wrk_b")
    chat_id = await _dm(client, a, b)

    sched_id = await _schedule(client, a, chat_id, "отложенное")

    # ПОСЛЕ планирования обычная переписка продолжается
    later_id = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "обычное позже"}, headers=b.headers
    )).json()["message"]["id"]

    # До доставки: у B ноль непрочитанного от отложки, в списке отложек она есть
    sched_list = (await client.get(f"/chats/{chat_id}/messages/scheduled", headers=a.headers)).json()
    assert [m["id"] for m in sched_list] == [sched_id]

    await _make_due(sched_id)
    await worker_mod.deliver_scheduled_messages({})

    # Отложка исчезла из списка, а в истории появилось сообщение со СВЕЖИМ id
    assert (await client.get(f"/chats/{chat_id}/messages/scheduled", headers=a.headers)).json() == []
    history = (await client.get(f"/chats/{chat_id}/messages", headers=b.headers)).json()
    delivered = next(m for m in history if m["text"] == "отложенное")
    assert delivered["id"] > later_id, "доставленная отложка должна быть внизу ленты"

    # У B ровно одно непрочитанное (доставленное); повторный тик не дублирует
    r = await client.get("/users/me/badge", headers=b.headers)
    unread_before = r.json()["unread"]
    await worker_mod.deliver_scheduled_messages({})
    assert (await client.get("/users/me/badge", headers=b.headers)).json()["unread"] == unread_before
    history2 = (await client.get(f"/chats/{chat_id}/messages", headers=b.headers)).json()
    assert len([m for m in history2 if m["text"] == "отложенное"]) == 1


async def test_failed_delivery_is_retried_not_lost(client, register_user, monkeypatch):
    """Инфраструктурный сбой при доставке: строка откладывается, не теряется."""
    a = await register_user("fail_a")
    b = await register_user("fail_b")
    chat_id = await _dm(client, a, b)
    sched_id = await _schedule(client, a, chat_id, "выживу")
    await _make_due(sched_id)

    calls = {"n": 0}
    real = None

    async def boom(*args, **kwargs):
        calls["n"] += 1
        raise RuntimeError("simulated infra crash")

    import services.message as msg_mod
    real = msg_mod.create_message
    monkeypatch.setattr(msg_mod, "create_message", boom)
    # deliver_due импортирует create_message изнутри services.message
    await worker_mod.deliver_scheduled_messages({})
    assert calls["n"] >= 1

    from db import async_session_maker
    async with async_session_maker() as db:
        left = (await db.execute(
            text("SELECT count(*) FROM scheduled_messages WHERE id = :id"), {"id": sched_id}
        )).scalar()
    assert left == 1, "строка не должна теряться при сбое"

    monkeypatch.setattr(msg_mod, "create_message", real)
    await _make_due(sched_id)
    await worker_mod.deliver_scheduled_messages({})
    history = (await client.get(f"/chats/{chat_id}/messages", headers=b.headers)).json()
    assert any(m["text"] == "выживу" for m in history)


async def test_undeliverable_scheduled_is_dropped(client, register_user):
    """Права умерли между планированием и доставкой (блок) — строка дропается."""
    a = await register_user("und_a")
    b = await register_user("und_b")
    chat_id = await _dm(client, a, b)
    sched_id = await _schedule(client, a, chat_id, "не дойдёт")

    await client.post(f"/users/{a.id}/block", headers=b.headers)
    await _make_due(sched_id)
    await worker_mod.deliver_scheduled_messages({})

    from db import async_session_maker
    async with async_session_maker() as db:
        left = (await db.execute(
            text("SELECT count(*) FROM scheduled_messages WHERE id = :id"), {"id": sched_id}
        )).scalar()
    assert left == 0, "недоставляемая строка не должна блокировать очередь"
    history = (await client.get(f"/chats/{chat_id}/messages", headers=b.headers)).json()
    assert not any(m["text"] == "не дойдёт" for m in history)


async def test_schedule_validation_and_cancel(client, register_user):
    a = await register_user("val_a")
    b = await register_user("val_b")
    chat_id = await _dm(client, a, b)

    # Прошлое → 400
    past = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    r = await client.post(
        f"/chats/{chat_id}/messages", json={"content": "x", "send_at": past}, headers=a.headers
    )
    assert r.status_code == 400

    # Отмена своей — ок; чужой — 403
    sched_id = await _schedule(client, a, chat_id, "отменю")
    r = await client.delete(f"/messages/{sched_id}/scheduled", headers=b.headers)
    assert r.status_code == 403
    r = await client.delete(f"/messages/{sched_id}/scheduled", headers=a.headers)
    assert r.status_code == 200
    assert (await client.get(f"/chats/{chat_id}/messages/scheduled", headers=a.headers)).json() == []
