"""Стадия 2: обычные личные чаты (type=private) стали end-to-end.

Признак шифрования — наличие e2e_handshake, а не тип secret. Здесь проверяется:
создание DM с eph_pub даёт E2E-чат; до-обновление legacy-plaintext DM до E2E;
шифрованный DM не принимает plaintext и наоборот; без ключей — остаётся
plaintext (обратная совместимость).
"""
import base64
import os


def _b64(n=32):
    return base64.b64encode(os.urandom(n)).decode()


async def _publish_key(client, u, key=None):
    key = key or _b64()
    r = await client.put("/e2e/keys", json={"public_key": key}, headers=u.headers)
    assert r.status_code == 200, r.text
    return key


async def test_private_chat_e2e_by_default(client, register_user):
    a = await register_user("pe_a")
    b = await register_user("pe_b")
    await _publish_key(client, a)
    await _publish_key(client, b)

    eph = _b64()
    r = await client.post("/chats", json={"user_id": b.id, "eph_pub": eph}, headers=a.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    # Тип остаётся private, но чат несёт handshake → он E2E.
    assert body["type"] == "private"
    hs = body["e2e_handshake"]
    assert hs is not None
    assert hs["creator_id"] == a.id
    assert hs["eph_pub"] == eph
    assert hs["creator_identity_pub"] and hs["peer_identity_pub"]
    chat_id = body["id"]

    # Собеседник видит тот же handshake.
    r = await client.get(f"/chats/{chat_id}", headers=b.headers)
    assert r.json()["e2e_handshake"]["eph_pub"] == eph

    # Plaintext в E2E-DM → 400.
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "открытым текстом"}, headers=a.headers)
    assert r.status_code == 400

    # Шифроблоб → ок, отдаётся непрозрачно, text == None.
    blob = base64.b64encode(os.urandom(64)).decode()
    r = await client.post(f"/chats/{chat_id}/messages", json={"encrypted_payload": blob}, headers=a.headers)
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    assert msg["encrypted_payload"] == blob and msg["text"] is None

    # FTS не находит E2E-сообщения (text NULL → вне индекса).
    r = await client.get("/search/messages", params={"q": "текстом"}, headers=a.headers)
    assert r.status_code == 200
    assert all(hit["id"] != msg["id"] for hit in r.json()["results"])


async def test_legacy_plaintext_dm_upgrades_to_e2e(client, register_user):
    a = await register_user("up_a")
    b = await register_user("up_b")

    # Legacy-DM без ключей → plaintext (обратная совместимость).
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    assert r.status_code == 200, r.text
    chat_id = r.json()["id"]
    assert r.json()["e2e_handshake"] is None

    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "старое сообщение"}, headers=a.headers)
    assert r.status_code == 200  # plaintext всё ещё принимается — handshake нет

    # Публикуем ключи и повторяем POST /chats с eph_pub → тот же чат, но E2E.
    await _publish_key(client, a)
    await _publish_key(client, b)
    eph = _b64()
    r = await client.post("/chats", json={"user_id": b.id, "eph_pub": eph}, headers=a.headers)
    assert r.status_code == 200, r.text
    assert r.json()["id"] == chat_id  # тот же самый DM
    hs = r.json()["e2e_handshake"]
    assert hs is not None and hs["eph_pub"] == eph and hs["creator_id"] == a.id

    # Теперь plaintext запрещён, а шифроблоб — принимается.
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "снова открыто"}, headers=a.headers)
    assert r.status_code == 400
    blob = base64.b64encode(os.urandom(48)).decode()
    r = await client.post(f"/chats/{chat_id}/messages", json={"encrypted_payload": blob}, headers=b.headers)
    assert r.status_code == 200, r.text


async def test_private_chat_without_keys_stays_plaintext(client, register_user):
    a = await register_user("pk_a")
    b = await register_user("pk_b")
    # eph_pub передан, но ни у кого нет опубликованного identity-ключа →
    # handshake собрать нельзя, чат остаётся plaintext (не падаем).
    r = await client.post("/chats", json={"user_id": b.id, "eph_pub": _b64()}, headers=a.headers)
    assert r.status_code == 200, r.text
    assert r.json()["e2e_handshake"] is None
    chat_id = r.json()["id"]
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "обычный текст"}, headers=a.headers)
    assert r.status_code == 200, r.text
