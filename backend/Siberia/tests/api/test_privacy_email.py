"""Email — приватное поле: виден только владельцу (регрессия C-4)."""


async def test_email_hidden_from_other_users(client, register_user):
    a = await register_user("alice")
    b = await register_user("bob")

    # Себе — виден
    r = await client.get("/users/me", headers=a.headers)
    assert r.json()["email"] == a.email

    # Чужому — нет
    r = await client.get(f"/users/{a.id}", headers=b.headers)
    assert r.status_code == 200
    assert r.json()["email"] is None

    # Поиск — нет
    r = await client.get("/users/search", params={"q": a.nickname}, headers=b.headers)
    hits = [u for u in r.json() if u["id"] == a.id]
    assert hits and hits[0]["email"] is None


async def test_email_hidden_in_friend_requests_and_blocked(client, register_user):
    a = await register_user("ann")
    b = await register_user("ben")

    # Заявка в друзья: входящие у B не должны светить email A
    r = await client.post(f"/friends/add/{b.id}", headers=a.headers)
    assert r.status_code == 200, r.text
    r = await client.get("/friends/requests", headers=b.headers)
    reqs = r.json()
    assert reqs and reqs[0]["user"]["id"] == a.id
    assert reqs[0]["user"]["email"] is None

    # Исходящие у A не светят email B
    r = await client.get("/friends/requests/sent", headers=a.headers)
    sent = r.json()
    assert sent and sent[0]["user"]["email"] is None

    # Список заблокированных
    r = await client.post(f"/users/{a.id}/block", headers=b.headers)
    assert r.status_code == 200
    r = await client.get("/users/me/blocked", headers=b.headers)
    blocked = r.json()
    assert blocked and blocked[0]["id"] == a.id
    assert blocked[0]["email"] is None


async def test_email_hidden_in_chat_members(client, register_user):
    a = await register_user("mem_a")
    b = await register_user("mem_b")

    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    assert r.status_code == 200, r.text
    chat_id = r.json()["id"]

    r = await client.get(f"/chats/{chat_id}/members", headers=a.headers)
    members = {m["user"]["id"]: m["user"] for m in r.json()}
    assert members[a.id]["email"] == a.email  # свой — виден
    assert members[b.id]["email"] is None     # чужой — нет
