"""E2E секретные чаты: серверные контракты.

Сервер криптографию не выполняет вовсе — он транспорт. Здесь проверяются
контракты: хранение ключей, handshake-материал, непрозрачность шифроблоба,
запреты (plaintext/edit/forward), блокировки. Сходимость самой криптографии
(X25519+HKDF+AES-GCM) покрыта iOS-тестами E2ECryptoTests на CryptoKit.
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


async def test_key_publish_and_fetch(client, register_user):
    a = await register_user("k_a")
    b = await register_user("k_b")
    key = await _publish_key(client, a)

    r = await client.get(f"/e2e/keys/{a.id}", headers=b.headers)
    assert r.status_code == 200
    assert r.json()["public_key"] == key

    # Нет ключа → 404
    r = await client.get(f"/e2e/keys/{b.id}", headers=a.headers)
    assert r.status_code == 404

    # Мусор вместо ключа → 400
    r = await client.put("/e2e/keys", json={"public_key": "not-base64!!!" * 4}, headers=a.headers)
    assert r.status_code == 400
    r = await client.put("/e2e/keys", json={"public_key": base64.b64encode(b"short").decode() * 3}, headers=a.headers)
    assert r.status_code in (400, 422)  # короткий ключ режет pydantic (422) до нашего валидатора


async def test_secret_chat_requires_both_keys(client, register_user):
    a = await register_user("sc_a")
    b = await register_user("sc_b")
    eph = _b64()

    # Ни у кого нет ключей → 409
    r = await client.post("/chats/secret", json={"user_id": b.id, "eph_pub": eph}, headers=a.headers)
    assert r.status_code == 409

    await _publish_key(client, a)
    r = await client.post("/chats/secret", json={"user_id": b.id, "eph_pub": eph}, headers=a.headers)
    assert r.status_code == 409  # у peer'а нет

    await _publish_key(client, b)
    r = await client.post("/chats/secret", json={"user_id": b.id, "eph_pub": eph}, headers=a.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["type"] == "secret"
    hs = body["e2e_handshake"]
    assert hs["creator_id"] == a.id
    assert hs["eph_pub"] == eph
    assert hs["creator_identity_pub"] and hs["peer_identity_pub"]

    # Обе стороны видят handshake в детали чата и в списке
    chat_id = body["id"]
    r = await client.get(f"/chats/{chat_id}", headers=b.headers)
    assert r.json()["e2e_handshake"]["eph_pub"] == eph
    lst = (await client.get("/chats", headers=b.headers)).json()
    entry = next(c for c in lst if c["id"] == chat_id)
    assert entry["type"] == "secret"
    assert entry["peer"]["id"] == a.id  # собеседник резолвится и для секретных


async def _secret_chat(client, a, b):
    await _publish_key(client, a)
    await _publish_key(client, b)
    r = await client.post(
        "/chats/secret", json={"user_id": b.id, "eph_pub": _b64()}, headers=a.headers
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_secret_chat_accepts_only_ciphertext(client, register_user):
    a = await register_user("ct_a")
    b = await register_user("ct_b")
    chat_id = await _secret_chat(client, a, b)

    # Plaintext в секретный чат → 400
    r = await client.post(f"/chats/{chat_id}/messages", json={"content": "открытый текст"}, headers=a.headers)
    assert r.status_code == 400

    # Шифроблоб → ок; сервер отдаёт его непрозрачно, text == None
    blob = base64.b64encode(os.urandom(64)).decode()
    r = await client.post(
        f"/chats/{chat_id}/messages", json={"encrypted_payload": blob}, headers=a.headers
    )
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    assert msg["encrypted_payload"] == blob
    assert msg["text"] is None

    # Получатель читает блоб из истории
    r = await client.get(f"/chats/{chat_id}/messages", headers=b.headers)
    fetched = next(m for m in r.json() if m["id"] == msg["id"])
    assert fetched["encrypted_payload"] == blob
    assert fetched["text"] is None

    # Шифроблоб в ОБЫЧНЫЙ чат → 400
    r2 = await client.post("/chats", json={"user_id": b.id}, headers=a.headers)
    plain_chat = r2.json()["id"]
    r = await client.post(
        f"/chats/{plain_chat}/messages", json={"encrypted_payload": blob}, headers=a.headers
    )
    assert r.status_code == 400


async def test_secret_messages_restrictions(client, register_user):
    a = await register_user("rs_a")
    b = await register_user("rs_b")
    c = await register_user("rs_c")
    chat_id = await _secret_chat(client, a, b)

    blob = base64.b64encode(os.urandom(48)).decode()
    msg_id = (await client.post(
        f"/chats/{chat_id}/messages", json={"encrypted_payload": blob}, headers=a.headers
    )).json()["message"]["id"]

    # Редактирование запрещено (v1)
    r = await client.patch(f"/messages/{msg_id}", json={"content": "new"}, headers=a.headers)
    assert r.status_code == 403

    # Форвард из секретного чата запрещён
    r2 = await client.post("/chats", json={"user_id": c.id}, headers=a.headers)
    other_chat = r2.json()["id"]
    r = await client.post(
        f"/chats/{other_chat}/messages", json={"forward_message_id": msg_id}, headers=a.headers
    )
    assert r.status_code == 400

    # Поиск не находит секретные сообщения (text NULL → вне FTS)
    r = await client.get("/search/messages", params={"q": "что угодно"}, headers=a.headers)
    assert r.status_code == 200

    # Удаление работает (метаданные — не секрет)
    r = await client.delete(f"/messages/{msg_id}", headers=a.headers)
    assert r.status_code == 200


async def test_secret_chat_respects_blocks(client, register_user):
    a = await register_user("bk_a")
    b = await register_user("bk_b")
    chat_id = await _secret_chat(client, a, b)

    await client.post(f"/users/{a.id}/block", headers=b.headers)
    blob = base64.b64encode(os.urandom(48)).decode()
    r = await client.post(
        f"/chats/{chat_id}/messages", json={"encrypted_payload": blob}, headers=a.headers
    )
    assert r.status_code == 403

    # И новый секретный чат с блокировщиком не создать
    r = await client.post(
        "/chats/secret", json={"user_id": b.id, "eph_pub": _b64()}, headers=a.headers
    )
    assert r.status_code == 403
