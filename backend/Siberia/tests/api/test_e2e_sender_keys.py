"""Групповое E2E (стадия 3b): транспорт sender-key (SKDM) + member-devices.

Сервер криптографию не делает — проверяем контракты: раздача ключей адресно
устройствам, выборка адресованных мне, идемпотентность по эпохе, доступ только
участникам.
"""
import base64
import os


def _b64(n=32):
    return base64.b64encode(os.urandom(n)).decode()


async def _register_device(client, u, device_id):
    r = await client.put(
        "/e2e/devices", json={"device_id": device_id, "public_key": _b64()}, headers=u.headers
    )
    assert r.status_code == 200, r.text


async def _group(client, owner, members):
    r = await client.post(
        "/chats/group",
        json={"title": "g", "user_ids": [m.id for m in members]},
        headers=owner.headers,
    )
    assert r.status_code == 200, r.text
    return r.json()["id"]


async def test_member_devices_lists_all_member_devices(client, register_user):
    a = await register_user("sk_a")
    b = await register_user("sk_b")
    await _register_device(client, a, "a1")
    await _register_device(client, b, "b1")
    await _register_device(client, b, "b2")
    chat_id = await _group(client, a, [b])

    r = await client.get(f"/chats/{chat_id}/member-devices", headers=a.headers)
    assert r.status_code == 200, r.text
    devs = r.json()["devices"]
    pairs = {(d["user_id"], d["device_id"]) for d in devs}
    assert pairs == {(a.id, "a1"), (b.id, "b1"), (b.id, "b2")}


async def test_sender_key_distribution_roundtrip(client, register_user):
    a = await register_user("sk2_a")
    b = await register_user("sk2_b")
    await _register_device(client, a, "a1")
    await _register_device(client, b, "b1")
    chat_id = await _group(client, a, [b])

    ct = _b64(64)
    r = await client.post(
        f"/chats/{chat_id}/sender-keys",
        json={
            "from_device_id": "a1",
            "key_epoch": 0,
            "distributions": [{"to_user_id": b.id, "to_device_id": "b1", "ciphertext": ct}],
        },
        headers=a.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["stored"] == 1

    # b/b1 забирает адресованный ему SKDM
    r = await client.get(f"/chats/{chat_id}/sender-keys", params={"device_id": "b1"}, headers=b.headers)
    assert r.status_code == 200, r.text
    keys = r.json()["keys"]
    assert len(keys) == 1
    assert keys[0]["from_user_id"] == a.id
    assert keys[0]["from_device_id"] == "a1"
    assert keys[0]["ciphertext"] == ct

    # другому устройству b (b2) — ничего
    r = await client.get(f"/chats/{chat_id}/sender-keys", params={"device_id": "b2"}, headers=b.headers)
    assert r.json()["keys"] == []


async def test_sender_key_upsert_by_epoch(client, register_user):
    a = await register_user("sk3_a")
    b = await register_user("sk3_b")
    await _register_device(client, a, "a1")
    await _register_device(client, b, "b1")
    chat_id = await _group(client, a, [b])

    async def push(ct, epoch):
        return await client.post(
            f"/chats/{chat_id}/sender-keys",
            json={"from_device_id": "a1", "key_epoch": epoch,
                  "distributions": [{"to_user_id": b.id, "to_device_id": "b1", "ciphertext": ct}]},
            headers=a.headers,
        )

    ct0, ct0b, ct1 = _b64(64), _b64(64), _b64(64)
    await push(ct0, 0)
    await push(ct0b, 0)   # та же эпоха → апдейт, не дубль
    await push(ct1, 1)    # новая эпоха → отдельная строка

    r = await client.get(f"/chats/{chat_id}/sender-keys", params={"device_id": "b1"}, headers=b.headers)
    keys = r.json()["keys"]
    by_epoch = {k["key_epoch"]: k["ciphertext"] for k in keys}
    assert by_epoch == {0: ct0b, 1: ct1}


async def test_sender_keys_require_membership(client, register_user):
    a = await register_user("sk4_a")
    b = await register_user("sk4_b")
    outsider = await register_user("sk4_x")
    await _register_device(client, a, "a1")
    await _register_device(client, b, "b1")
    chat_id = await _group(client, a, [b])

    r = await client.get(f"/chats/{chat_id}/member-devices", headers=outsider.headers)
    assert r.status_code == 403
    r = await client.get(f"/chats/{chat_id}/sender-keys", params={"device_id": "x1"}, headers=outsider.headers)
    assert r.status_code == 403
    r = await client.post(
        f"/chats/{chat_id}/sender-keys",
        json={"from_device_id": "x1", "key_epoch": 0,
              "distributions": [{"to_user_id": a.id, "to_device_id": "a1", "ciphertext": _b64(64)}]},
        headers=outsider.headers,
    )
    assert r.status_code == 403
