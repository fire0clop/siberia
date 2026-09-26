"""Мультидевайс (стадия 3a): реестр публичных ключей устройств."""
import base64
import os


def _b64(n=32):
    return base64.b64encode(os.urandom(n)).decode()


async def test_register_and_list_devices(client, register_user):
    a = await register_user("dev_a")
    b = await register_user("dev_b")

    k1 = _b64()
    r = await client.put("/e2e/devices", json={"device_id": "iphone-1", "public_key": k1}, headers=a.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["device_id"] == "iphone-1" and body["public_key"] == k1

    # Второе устройство того же юзера
    k2 = _b64()
    r = await client.put("/e2e/devices", json={"device_id": "ipad-1", "public_key": k2}, headers=a.headers)
    assert r.status_code == 200, r.text

    # b видит ОБА устройства a
    r = await client.get(f"/e2e/devices/{a.id}", headers=b.headers)
    assert r.status_code == 200, r.text
    devs = r.json()["devices"]
    assert {d["device_id"] for d in devs} == {"iphone-1", "ipad-1"}
    assert {d["public_key"] for d in devs} == {k1, k2}


async def test_device_key_upsert_is_idempotent(client, register_user):
    a = await register_user("dev_up")
    r = await client.put("/e2e/devices", json={"device_id": "d1", "public_key": _b64()}, headers=a.headers)
    assert r.status_code == 200

    new_key = _b64()
    r = await client.put("/e2e/devices", json={"device_id": "d1", "public_key": new_key}, headers=a.headers)
    assert r.status_code == 200

    r = await client.get(f"/e2e/devices/{a.id}", headers=a.headers)
    devs = r.json()["devices"]
    assert len(devs) == 1  # то же device_id — обновление, не дубль
    assert devs[0]["public_key"] == new_key


async def test_device_key_validated(client, register_user):
    a = await register_user("dev_val")
    # Не 32 байта → 400
    short = base64.b64encode(os.urandom(16)).decode()
    r = await client.put("/e2e/devices", json={"device_id": "d", "public_key": short}, headers=a.headers)
    assert r.status_code in (400, 422)


async def test_list_devices_empty_for_unknown(client, register_user):
    a = await register_user("dev_empty")
    b = await register_user("dev_empty2")
    r = await client.get(f"/e2e/devices/{b.id}", headers=a.headers)
    assert r.status_code == 200
    assert r.json()["devices"] == []
