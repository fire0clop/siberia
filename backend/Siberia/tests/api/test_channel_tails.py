"""Хвосты каналов: инвайт-ссылки, превью публичного канала, модерация, pin в DM."""


async def _channel(client, owner, is_public=True, title="Канал"):
    r = await client.post(
        "/channels", json={"title": title, "is_public": is_public}, headers=owner.headers
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_channel_invite_link_grants_subscriber(client, register_user):
    owner = await register_user("inv_own")
    guest = await register_user("inv_gst")
    ch_id = await _channel(client, owner, is_public=False, title="Приватный")

    # Раньше: 400 "Only groups have invite links" — приватный канал был незаходибельным
    r = await client.post(f"/chats/{ch_id}/invite-link", headers=owner.headers)
    assert r.status_code == 200, r.text
    slug = r.json()["invite_link"] if "invite_link" in r.json() else r.json().get("slug") or list(r.json().values())[0]

    r = await client.get(f"/chats/join/{slug}", headers=guest.headers)
    assert r.status_code == 200, r.text

    # Пришедший по ссылке — ПОДПИСЧИК: постить не может
    r = await client.post(f"/chats/{ch_id}/messages", json={"content": "спам"}, headers=guest.headers)
    assert r.status_code == 403

    # Счётчик подписчиков вырос
    r = await client.get(f"/channels/{ch_id}", headers=owner.headers)
    assert r.json()["subscribers_count"] >= 2


async def test_public_channel_preview_without_subscription(client, register_user):
    owner = await register_user("pv_own")
    visitor = await register_user("pv_vis")
    ch_id = await _channel(client, owner, is_public=True, title="Открытый")

    await client.post(f"/chats/{ch_id}/messages", json={"content": "первый пост"}, headers=owner.headers)

    # Не подписан — но публичный канал можно посмотреть
    r = await client.get(f"/chats/{ch_id}", headers=visitor.headers)
    assert r.status_code == 200, f"public channel detail must be viewable: {r.text}"

    r = await client.get(f"/chats/{ch_id}/messages", headers=visitor.headers)
    assert r.status_code == 200, f"public channel messages must be readable: {r.text}"
    texts = [m.get("text") for m in r.json()]
    assert "первый пост" in texts

    # А постить без подписки/прав — нельзя
    r = await client.post(f"/chats/{ch_id}/messages", json={"content": "вброс"}, headers=visitor.headers)
    assert r.status_code == 403


async def test_private_channel_not_readable_without_membership(client, register_user):
    owner = await register_user("pc_own")
    visitor = await register_user("pc_vis")
    ch_id = await _channel(client, owner, is_public=False, title="Закрытый")

    r = await client.get(f"/chats/{ch_id}/messages", headers=visitor.headers)
    assert r.status_code == 403


async def test_admin_can_delete_others_messages(client, register_user):
    owner = await register_user("md_own")
    member = await register_user("md_mem")
    outsider = await register_user("md_out")

    r = await client.post(
        "/chats/group", json={"title": "Модерация", "user_ids": [member.id]}, headers=owner.headers
    )
    chat_id = r.json()["id"]

    msg_id = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "нарушение правил"}, headers=member.headers
    )).json()["message"]["id"]

    # Обычный участник чужое удалить не может (member удаляет сообщение owner'а)
    own_msg = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "от владельца"}, headers=owner.headers
    )).json()["message"]["id"]
    r = await client.delete(f"/messages/{own_msg}", headers=member.headers)
    assert r.status_code == 403

    # Посторонний — тем более
    r = await client.delete(f"/messages/{msg_id}", headers=outsider.headers)
    assert r.status_code == 403

    # Owner удаляет чужое — можно (раньше: 403 "Can only delete own messages")
    r = await client.delete(f"/messages/{msg_id}", headers=owner.headers)
    assert r.status_code == 200, r.text

    r = await client.get(f"/chats/{chat_id}/messages", headers=owner.headers)
    deleted = next(m for m in r.json() if m["id"] == msg_id)
    assert deleted.get("deleted_at") is not None or deleted.get("text") is None


async def test_pin_works_in_dm_and_validates_chat(client, register_user):
    a = await register_user("pin_a")
    b = await register_user("pin_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]
    msg_id = (await client.post(
        f"/chats/{chat_id}/messages", json={"content": "закрепи меня"}, headers=a.headers
    )).json()["message"]["id"]

    # Раньше в DM pin был невозможен (роль member → 403)
    r = await client.post(f"/chats/{chat_id}/pin/{msg_id}", headers=b.headers)
    assert r.status_code == 200, r.text

    # Сообщение из ЧУЖОГО чата закрепить нельзя
    c = await register_user("pin_c")
    r2 = await client.post("/chats", json={"user_id": c.id}, headers=a.headers)
    other_chat = r2.json()["id"]
    foreign_msg = (await client.post(
        f"/chats/{other_chat}/messages", json={"content": "чужое"}, headers=a.headers
    )).json()["message"]["id"]
    r = await client.post(f"/chats/{chat_id}/pin/{foreign_msg}", headers=a.headers)
    assert r.status_code == 400
