"""GET /chats/{id}/members отдаёт last_read_message_id для инициализации галочек."""


async def test_members_carry_last_read(client, register_user):
    a = await register_user("lr_a")
    b = await register_user("lr_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    m1 = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "раз"}, headers=a.headers
    )).json()["message"]["id"]
    m2 = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "два"}, headers=a.headers
    )).json()["message"]["id"]

    # B прочитал только первое
    await client.post(f"/chats/{chat_id}/read", json={"up_to_message_id": m1}, headers=b.headers)

    r = await client.get(f"/chats/{chat_id}/members", headers=a.headers)
    members = {m["user"]["id"]: m for m in r.json()}
    assert members[b.id]["last_read_message_id"] == m1
    # A — отправитель, его собственные сообщения помечены read сразу
    assert members[a.id]["last_read_message_id"] == m2

    # B дочитал до второго
    await client.post(f"/chats/{chat_id}/read", json={"up_to_message_id": m2}, headers=b.headers)
    r = await client.get(f"/chats/{chat_id}/members", headers=a.headers)
    members = {m["user"]["id"]: m for m in r.json()}
    assert members[b.id]["last_read_message_id"] == m2
