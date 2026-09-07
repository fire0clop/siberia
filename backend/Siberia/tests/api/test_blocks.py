"""Блокировка должна работать и в уже существующем DM (регрессия C-3)."""


async def _send(client, u, chat_id, text):
    return await client.post(
        f"/chats/{chat_id}/messages", json={"content": text}, headers=u.headers
    )


async def test_block_stops_messages_in_existing_dm(client, register_user):
    a = await register_user("blk_a")
    b = await register_user("blk_b")

    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    # До блокировки переписка работает
    assert (await _send(client, a, chat_id, "привет")).status_code == 200

    # B блокирует A → A больше не может писать в СУЩЕСТВУЮЩИЙ чат
    await client.post(f"/users/{a.id}/block", headers=b.headers)
    r = await _send(client, a, chat_id, "а теперь?")
    assert r.status_code == 403, f"blocked user still messaged: {r.status_code} {r.text}"

    # Блокировавший тоже не пишет (блок двусторонний)
    assert (await _send(client, b, chat_id, "и я")).status_code == 403

    # Разблокировка возвращает переписку
    await client.delete(f"/users/{a.id}/block", headers=b.headers)
    assert (await _send(client, a, chat_id, "снова тут")).status_code == 200


async def test_block_still_prevents_new_chat(client, register_user):
    a = await register_user("nc_a")
    b = await register_user("nc_b")
    await client.post(f"/users/{a.id}/block", headers=b.headers)
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    assert r.status_code == 403
