"""At-rest защита: рефреш-токены в базе — хеши, TOTP-секреты — шифр."""
import pyotp
from sqlalchemy import text


async def test_refresh_token_stored_as_hash_not_plaintext(client, register_user):
    u = await register_user("hash_rt")

    from db import async_session_maker
    async with async_session_maker() as db:
        stored = (await db.execute(
            text("SELECT refresh_token FROM sessions WHERE user_id = :uid"), {"uid": u.id}
        )).scalar()

    # Настоящий refresh-токен — это JWT (три части через точку), длинный.
    # В базе не должно быть ни его самого, ни чего-либо кроме SHA-256 hex.
    assert stored != u.refresh
    assert "." not in stored
    assert len(stored) == 64 and all(c in "0123456789abcdef" for c in stored)

    # И токен при этом продолжает работать (сравнение идёт по хешу)
    r = await client.post(
        "/auth/refresh",
        json={"refresh_token": u.refresh, "device_id": u.device_id},
        headers={"X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 200


async def test_totp_secret_stored_encrypted(client, register_user):
    u = await register_user("enc_totp")

    r = await client.post("/auth/2fa/setup", headers=u.headers)
    secret = r.json()["secret"]
    await client.post(
        "/auth/2fa/confirm",
        json={"totp_code": pyotp.TOTP(secret).now()},
        headers=u.headers,
    )

    from db import async_session_maker
    async with async_session_maker() as db:
        stored = (await db.execute(
            text("SELECT totp_secret FROM users WHERE id = :uid"), {"uid": u.id}
        )).scalar()

    # В базе — шифр (enc:v1:...), а не base32-секрет
    assert stored.startswith("enc:v1:")
    assert secret not in stored

    # 2FA при этом работает: логин требует код, верный код проходит
    r = await client.post(
        "/auth/login",
        json={"email": u.email, "password": u.password},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    body = r.json()
    assert body["requires_2fa"] is True
    r = await client.post(
        "/auth/2fa/verify",
        json={"temp_token": body["temp_token"], "totp_code": pyotp.TOTP(secret).now()},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 200, r.text
    assert r.json()["access_token"]
