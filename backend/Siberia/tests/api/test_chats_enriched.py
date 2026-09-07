"""GET /chats обогащён: unread, last_message, peer; scheduled не считается unread (H-6)."""
from datetime import datetime, timedelta, timezone


async def _dm(client, a, b):
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def _send(client, u, chat_id, text, **extra):
    return await client.post(
        f"/chats/{chat_id}/messages", json={"content": text, **extra}, headers=u.headers
    )


async def test_chat_list_has_unread_last_message_and_peer(client, register_user):
    a = await register_user("enr_a")
    b = await register_user("enr_b")
    chat_id = await _dm(client, a, b)

    await _send(client, b, chat_id, "первое")
    await _send(client, b, chat_id, "второе непрочитанное")

    r = await client.get("/chats", headers=a.headers)
    assert r.status_code == 200
    chat = next(c for c in r.json() if c["id"] == chat_id)

    assert chat["unread_count"] == 2
    assert chat["last_message"]["text"] == "второе непрочитанное"
    assert chat["last_message"]["user_id"] == b.id
    # peer — это B, и его email скрыт (C-4)
    assert chat["peer"] is not None
    assert chat["peer"]["id"] == b.id
    assert chat["peer"]["email"] is None


async def test_unread_resets_after_read(client, register_user):
    a = await register_user("rd_a")
    b = await register_user("rd_b")
    chat_id = await _dm(client, a, b)
    r = await _send(client, b, chat_id, "прочитай меня")
    last_id = r.json()["message"]["id"]

    await client.post(f"/chats/{chat_id}/read", json={"up_to_message_id": last_id}, headers=a.headers)

    r = await client.get("/chats", headers=a.headers)
    chat = next(c for c in r.json() if c["id"] == chat_id)
    assert chat["unread_count"] == 0


async def test_own_messages_not_counted_unread(client, register_user):
    a = await register_user("own_a")
    b = await register_user("own_b")
    chat_id = await _dm(client, a, b)
    await _send(client, a, chat_id, "моё сообщение")

    r = await client.get("/chats", headers=a.headers)
    chat = next(c for c in r.json() if c["id"] == chat_id)
    assert chat["unread_count"] == 0


async def test_scheduled_message_not_counted_unread(client, register_user):
    """Отложка до доставки живёт в scheduled_messages и unread не создаёт."""
    a = await register_user("sch_a")
    b = await register_user("sch_b")
    chat_id = await _dm(client, a, b)

    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    r = await _send(client, a, chat_id, "через час", send_at=future)
    assert r.status_code == 200, r.text

    # У получателя B ничего непрочитанного (сообщение ещё не отправлено)
    r = await client.get("/chats", headers=b.headers)
    chat = next((c for c in r.json() if c["id"] == chat_id), None)
    if chat is not None:
        assert chat["unread_count"] == 0

    # И badge у B нулевой
    r = await client.get("/users/me/badge", headers=b.headers)
    assert r.json()["unread"] == 0
