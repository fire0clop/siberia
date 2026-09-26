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
    assert r.status_code == 200  # plaintext всё ещё принимается — чат не E2E

    # Стадия 3c: DM становится E2E, как только у обеих сторон есть device-ключи.
    # Регистрируем устройства и снова обращаемся к чату → до-обновление до E2E.
    await client.put("/e2e/devices", json={"device_id": "a1", "public_key": _b64()}, headers=a.headers)
    await client.put("/e2e/devices", json={"device_id": "b1", "public_key": _b64()}, headers=b.headers)
    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    assert r.status_code == 200, r.text
    assert r.json()["id"] == chat_id  # тот же самый DM
    assert r.json()["is_e2e"] is True

    # Теперь plaintext запрещён, а шифроблоб (sender keys) — принимается.
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "снова открыто"}, headers=a.headers)
    assert r.status_code == 400
    blob = base64.b64encode(os.urandom(48)).decode()
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"encrypted_payload": blob, "sender_device_id": "b1"},
        headers=b.headers,
    )
    assert r.status_code == 200, r.text


async def test_new_dm_with_device_keys_is_e2e_sender_keys(client, register_user):
    """Стадия 3c: DM унифицирован на sender keys — E2E, если у обеих сторон
    есть device-ключи, без всякого handshake/eph_pub."""
    a = await register_user("d3_a")
    b = await register_user("d3_b")
    await client.put("/e2e/devices", json={"device_id": "a1", "public_key": _b64()}, headers=a.headers)
    await client.put("/e2e/devices", json={"device_id": "b1", "public_key": _b64()}, headers=b.headers)

    r = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)  # без eph_pub
    assert r.status_code == 200, r.text
    assert r.json()["type"] == "private"
    assert r.json()["is_e2e"] is True
    assert r.json()["e2e_handshake"] is None  # handshake больше не нужен
    chat_id = r.json()["id"]

    # Plaintext запрещён; шифроблоб c sender_device_id принимается.
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "x"}, headers=a.headers)
    assert r.status_code == 400
    blob = base64.b64encode(os.urandom(48)).decode()
    r = await client.post(
        f"/chats/{chat_id}/messages",
        json={"encrypted_payload": blob, "sender_device_id": "a1"},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["message"]["sender_device_id"] == "a1"


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
