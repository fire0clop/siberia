"""Конкурентные отправки: sync_seq не должен дублироваться (регрессия H-5).

До фикса lock_chat_row возвращал Chat из identity map со stale sync_seq
(POST /messages сначала загружает Chat через get_private_chat_between),
и параллельные отправки ловили unique violation → 500.
"""
import asyncio


async def test_concurrent_sends_produce_unique_seqs(client, register_user):
    a = await register_user("cc_a")
    b = await register_user("cc_b")

    # POST /messages (auto-chat) — именно этот путь грузит Chat до лока
    async def send(user, i):
        peer = b if user is a else a
        return await client.post(
            "/messages",
            json={"user_id": peer.id, "content": f"msg-{i}"},
            headers=user.headers,
        )

    results = await asyncio.gather(*[
        send(a if i % 2 == 0 else b, i) for i in range(10)
    ])

    codes = [r.status_code for r in results]
    assert all(c == 200 for c in codes), f"statuses: {codes}; first error: " + next(
        (r.text for r in results if r.status_code != 200), ""
    )

    chat_id = results[0].json()["chat_id"]
    assert all(r.json()["chat_id"] == chat_id for r in results)

    # Все обновления имеют уникальные и непрерывные seq
    r = await client.get(f"/chats/{chat_id}/sync", params={"after_seq": 0}, headers=a.headers)
    assert r.status_code == 200
    updates = r.json()["updates"]
    seqs = [u["seq"] for u in updates]
    assert len(seqs) == len(set(seqs)), f"duplicate seqs: {sorted(seqs)}"
    assert len([u for u in updates if u["event"] == "message_new"]) == 10


async def test_concurrent_sends_same_chat_endpoint(client, register_user):
    a = await register_user("cs_a")
    b = await register_user("cs_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    results = await asyncio.gather(*[
        client.post(
            f"/chats/{chat_id}/messages",
            json={"content": f"m{i}"},
            headers=(a if i % 2 else b).headers,
        )
        for i in range(10)
    ])
    codes = [r.status_code for r in results]
    assert all(c == 200 for c in codes), f"statuses: {codes}"


async def test_idempotent_send_via_client_message_id(client, register_user):
    a = await register_user("idem_a")
    b = await register_user("idem_b")
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    chat_id = r.json()["id"]

    cmid = "3f2b8c1a-9d4e-4f6a-8b2c-1d3e5f7a9b0c"
    r1 = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "раз", "client_message_id": cmid},
        headers=a.headers,
    )
    r2 = await client.post(
        f"/chats/{chat_id}/messages",
        json={"content": "раз", "client_message_id": cmid},
        headers=a.headers,
    )
    assert r1.json()["message"]["id"] == r2.json()["message"]["id"]
    assert r2.json()["idempotent"] is True
