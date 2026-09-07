"""2FA: незавершённый setup не должен блокировать вход (регрессия C-2)."""
import pyotp


async def test_abandoned_2fa_setup_does_not_lock_login(client, register_user):
    u = await register_user("locked")

    # Начали setup и бросили — код не подтверждён
    r = await client.post("/auth/2fa/setup", headers=u.headers)
    assert r.status_code == 200

    # Логин обязан работать как без 2FA (раньше: requires_2fa=True и 500 на любой код)
    r = await client.post(
        "/auth/login",
        json={"email": u.email, "password": u.password},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body.get("requires_2fa") is False
    assert body.get("access_token")


async def test_full_2fa_flow_and_wrong_code(client, register_user):
    u = await register_user("twofa")

    r = await client.post("/auth/2fa/setup", headers=u.headers)
    secret = r.json()["secret"]
    code = pyotp.TOTP(secret).now()
    r = await client.post("/auth/2fa/confirm", json={"totp_code": code}, headers=u.headers)
    assert r.status_code == 200, r.text

    # Логин теперь требует 2FA и НЕ выдаёт токены
    r = await client.post(
        "/auth/login",
        json={"email": u.email, "password": u.password},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    body = r.json()
    assert body["requires_2fa"] is True
    assert body.get("access_token") is None
    temp = body["temp_token"]

    # Неверный код → 401
    r = await client.post(
        "/auth/2fa/verify",
        json={"temp_token": temp, "totp_code": "000000"},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 401

    # Верный код → полноценные токены
    r = await client.post(
        "/auth/2fa/verify",
        json={"temp_token": temp, "totp_code": pyotp.TOTP(secret).now()},
        headers={"X-Device-ID": u.device_id, "X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 200, r.text
    assert r.json()["access_token"]


async def test_setup_refuses_to_overwrite_active_secret(client, register_user):
    """Атака: украденный access-токен + повторный setup ломал владельцу 2FA."""
    u = await register_user("owner")

    r = await client.post("/auth/2fa/setup", headers=u.headers)
    secret = r.json()["secret"]
    code = pyotp.TOTP(secret).now()
    await client.post("/auth/2fa/confirm", json={"totp_code": code}, headers=u.headers)

    r = await client.post("/auth/2fa/setup", headers=u.headers)
    assert r.status_code == 400

    # Активный секрет не тронут: логин по-прежнему требует 2FA со СТАРЫМ секретом
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
    assert r.status_code == 200


async def test_no_session_created_before_totp_verified(client, register_user):
    """Логин с паролем (без TOTP) не должен создавать/вытеснять сессии (H-4)."""
    u = await register_user("sess")

    r = await client.post("/auth/2fa/setup", headers=u.headers)
    secret = r.json()["secret"]
    await client.post(
        "/auth/2fa/confirm",
        json={"totp_code": pyotp.TOTP(secret).now()},
        headers=u.headers,
    )

    r = await client.get("/sessions", headers=u.headers)
    sessions_before = len(r.json())

    # Пароль верный, но TOTP не введён — новых сессий быть не должно
    await client.post(
        "/auth/login",
        json={"email": u.email, "password": u.password},
        headers={"X-Device-ID": "attacker-device", "X-Forwarded-For": "10.66.66.66"},
    )
    r = await client.get("/sessions", headers=u.headers)
    assert len(r.json()) == sessions_before
