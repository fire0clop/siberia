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


async def test_grace_window_converges_on_winners_token(client, register_user):
    """Легитимная гонка: второй refresh со старым токеном получает ТЕКУЩИЙ
    refresh победителя, а не reuse-детект с удалением всех сессий."""
    u = await register_user("race")

    r1 = await _refresh(client, u, u.refresh)
    assert r1.status_code == 200
    winner_refresh = r1.json()["refresh_token"]

    # «Проигравший» шлёт тот же старый токен в пределах grace-окна
    r2 = await _refresh(client, u, u.refresh)
    assert r2.status_code == 200, f"grace refresh failed: {r2.text}"
    assert r2.json()["refresh_token"] == winner_refresh

    # Обе стороны сошлись на одном токене — им можно пользоваться дальше
    r3 = await _refresh(client, u, winner_refresh)
    assert r3.status_code == 200


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
