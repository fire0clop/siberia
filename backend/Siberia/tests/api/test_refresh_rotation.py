"""Ротация refresh-токенов: grace-окно вместо отстрела всех сессий (H-3)."""


async def _refresh(client, u, token):
    return await client.post(
        "/auth/refresh",
        json={"refresh_token": token, "device_id": u.device_id},
        headers={"X-Forwarded-For": u.client_ip},
    )


async def test_normal_rotation(client, register_user):
    u = await register_user("rot")
    r = await _refresh(client, u, u.refresh)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["refresh_token"] != u.refresh
    assert body["access_token"]


async def test_grace_window_reissues_not_nuke(client, register_user):
    """Легитимная гонка: проигравший старым токеном получает НОВЫЙ рабочий
    токен (а не reuse-детект с удалением всех сессий). Токены в базе хранятся
    хешами, поэтому «вернуть токен победителя» нельзя — переиздаём."""
    u = await register_user("race")

    r1 = await _refresh(client, u, u.refresh)
    assert r1.status_code == 200

    # «Проигравший» шлёт тот же старый токен в пределах grace-окна — не 401
    r2 = await _refresh(client, u, u.refresh)
    assert r2.status_code == 200, f"grace refresh failed: {r2.text}"
    loser_refresh = r2.json()["refresh_token"]
    assert loser_refresh != u.refresh  # выдан новый токен, а не отказ

    # Гонка не отстрелила сессию: выданный проигравшему токен продолжает работать.
    # (Клиент после дабл-тапа оставляет ОДИН токен и им и пользуется —
    # именно это и проверяем: сессия жива, а не 401.)
    assert (await _refresh(client, u, loser_refresh)).status_code == 200


async def test_real_reuse_still_nukes_all_sessions(client, register_user):
    """Токен двух ротаций назад — настоящая кража: все сессии отзываются."""
    u = await register_user("theft")
    t0 = u.refresh

    t1 = (await _refresh(client, u, t0)).json()["refresh_token"]
    t2 = (await _refresh(client, u, t1)).json()["refresh_token"]

    # t0 уже не current и не prev (prev теперь t1) → reuse-детект
    r = await _refresh(client, u, t0)
    assert r.status_code == 401

    # И даже свежий t2 больше не работает — сессии удалены
    r = await _refresh(client, u, t2)
    assert r.status_code == 401


async def test_wrong_device_rejected(client, register_user):
    u = await register_user("dev")
    r = await client.post(
        "/auth/refresh",
        json={"refresh_token": u.refresh, "device_id": "other-device"},
        headers={"X-Forwarded-For": u.client_ip},
    )
    assert r.status_code == 401
