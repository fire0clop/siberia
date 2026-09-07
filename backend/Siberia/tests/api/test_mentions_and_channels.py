"""Упоминания по @username и ролевая модель каналов."""


async def _set_username(client, u, username):
    r = await client.patch("/users/me/username", json={"username": username}, headers=u.headers)
    assert r.status_code == 200, r.text


async def test_mentions_resolve_by_username_not_nickname(client, register_user):
    a = await register_user("mn_a")
    b = await register_user("mn_b")
    await _set_username(client, b, "durov")

    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    # @username матчится
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "привет @durov, зайди"},
        headers=a.headers,
    )
    assert r.json()["message"]["mention_user_ids"] == [b.id]

    # никнейм (mn_b_...) БЕЗ username-совпадения не матчится
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": f"эй @{b.nickname}"},
        headers=a.headers,
    )
    mention_ids = r.json()["message"]["mention_user_ids"]
    assert not mention_ids


async def test_channel_roles_and_subscriber_demotion(client, register_user):
    owner = await register_user("ch_own")
    sub = await register_user("ch_sub")

    r = await client.post(
        "/channels", json={"title": "Новости", "is_public": True}, headers=owner.headers
    )
    assert r.status_code == 200, r.text
    ch_id = r.json()["id"]

    r = await client.post(f"/channels/{ch_id}/subscribe", headers=sub.headers)
    assert r.status_code == 200
    assert r.json()["subscribers_count"] >= 1

    # 'member' в канале не существует — раньше owner мог случайно раздать
    # подписчику право постить
    r = await client.patch(
        f"/chats/{ch_id}/members/{sub.id}/role", json={"role": "member"}, headers=owner.headers
    )
    assert r.status_code == 400

    # Повышение до admin работает, admin может постить
    r = await client.patch(
        f"/chats/{ch_id}/members/{sub.id}/role", json={"role": "admin"}, headers=owner.headers
    )
    assert r.status_code == 200
    r = await client.post(f"/chats/{ch_id}/messages", json={"content": "пост"}, headers=sub.headers)
    assert r.status_code == 200

    # И понижение ОБРАТНО в subscriber теперь возможно — постинг снова закрыт
    r = await client.patch(
        f"/chats/{ch_id}/members/{sub.id}/role", json={"role": "subscriber"}, headers=owner.headers
    )
    assert r.status_code == 200, r.text
    r = await client.post(f"/chats/{ch_id}/messages", json={"content": "ещё"}, headers=sub.headers)
    assert r.status_code == 403


async def test_kick_from_channel_decrements_subscribers(client, register_user):
    owner = await register_user("kd_own")
    sub = await register_user("kd_sub")

    ch_id = (await client.post(
        "/channels", json={"title": "Канал", "is_public": True}, headers=owner.headers
    )).json()["id"]

    await client.post(f"/channels/{ch_id}/subscribe", headers=sub.headers)
    before = (await client.get(f"/channels/{ch_id}", headers=owner.headers)).json()["subscribers_count"]

    r = await client.delete(f"/chats/{ch_id}/members/{sub.id}", headers=owner.headers)
    assert r.status_code == 200, r.text

    after = (await client.get(f"/channels/{ch_id}", headers=owner.headers)).json()["subscribers_count"]
    assert after == before - 1, f"kick must decrement subscribers_count: {before} -> {after}"


async def test_group_cannot_assign_subscriber(client, register_user):
    owner = await register_user("gr_own")
    m = await register_user("gr_m")
    r = await client.post(
        "/chats/group", json={"title": "Группа", "user_ids": [m.id]}, headers=owner.headers
    )
    chat_id = r.json()["id"]

    r = await client.patch(
        f"/chats/{chat_id}/members/{m.id}/role", json={"role": "subscriber"}, headers=owner.headers
    )
    assert r.status_code == 400
