"""Стадия 4b: зашифрованный бэкап identity-ключа под пассфразу."""
import base64
import os


def _b64(n=48):
    return base64.b64encode(os.urandom(n)).decode()


async def test_backup_put_get_roundtrip(client, register_user):
    a = await register_user("bk_a")

    ct, salt = _b64(64), _b64(16)
    r = await client.put(
        "/e2e/backup",
        json={"ciphertext": ct, "salt": salt, "iterations": 210_000},
        headers=a.headers,
    )
    assert r.status_code == 200, r.text

    r = await client.get("/e2e/backup", headers=a.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ciphertext"] == ct
    assert body["salt"] == salt
    assert body["iterations"] == 210_000


async def test_backup_replace(client, register_user):
    a = await register_user("bk_rep")
    await client.put("/e2e/backup", json={"ciphertext": _b64(), "salt": _b64(16), "iterations": 210_000}, headers=a.headers)
    ct2 = _b64(64)
    await client.put("/e2e/backup", json={"ciphertext": ct2, "salt": _b64(16), "iterations": 300_000}, headers=a.headers)
    r = await client.get("/e2e/backup", headers=a.headers)
    assert r.json()["ciphertext"] == ct2
    assert r.json()["iterations"] == 300_000


async def test_backup_absent_is_404(client, register_user):
    a = await register_user("bk_none")
    r = await client.get("/e2e/backup", headers=a.headers)
    assert r.status_code == 404


async def test_backup_is_per_user(client, register_user):
    a = await register_user("bk_own1")
    b = await register_user("bk_own2")
    await client.put("/e2e/backup", json={"ciphertext": _b64(), "salt": _b64(16), "iterations": 210_000}, headers=a.headers)
    # b своего бэкапа не клал → 404, чужой не отдаётся
    r = await client.get("/e2e/backup", headers=b.headers)
    assert r.status_code == 404


async def test_backup_rejects_weak_iterations(client, register_user):
    a = await register_user("bk_weak")
    r = await client.put(
        "/e2e/backup",
        json={"ciphertext": _b64(), "salt": _b64(16), "iterations": 1000},
        headers=a.headers,
    )
    assert r.status_code == 422  # ниже минимума PBKDF2
