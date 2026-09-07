"""Отказ Redis не должен ронять авторизованный трафик: fallback на БД.

Источник правды об отзыве — таблица sessions (revoke удаляет строку);
Redis лишь кеш. Раньше любой Redis-сбой в is_session_revoked давал 500
на каждый запрос.
"""
from sqlalchemy import text


async def test_redis_down_falls_back_to_db_and_allows_live_session(client, register_user, monkeypatch):
    u = await register_user("rf_a")

    import utils.deps as deps_mod

    async def redis_broken(session_id):
        raise ConnectionError("redis is down")

    monkeypatch.setattr(deps_mod, "is_session_revoked", redis_broken)

    # Живая сессия (строка в БД есть) — запрос проходит
    r = await client.get("/users/me", headers=u.headers)
    assert r.status_code == 200, f"Redis outage must not 500 authed traffic: {r.status_code} {r.text}"


async def test_redis_down_still_rejects_revoked_session(client, register_user, monkeypatch):
    u = await register_user("rf_b")

    import utils.deps as deps_mod

    async def redis_broken(session_id):
        raise ConnectionError("redis is down")

    monkeypatch.setattr(deps_mod, "is_session_revoked", redis_broken)

    # «Отзываем» сессию на уровне источника правды — удаляем строку из БД
    from db import async_session_maker
    async with async_session_maker() as db:
        await db.execute(text("DELETE FROM sessions"))
        await db.commit()

    r = await client.get("/users/me", headers=u.headers)
    assert r.status_code == 401, "revoked session must stay rejected even with Redis down"


async def test_garbage_sub_gives_401_not_500(client):
    """Токен с мусорным sub — 401, а не 500."""
    from jose import jwt as jose_jwt
    from config import settings

    bad = jose_jwt.encode(
        {"sub": "not-a-number", "type": "access", "session_id": 1, "exp": 9999999999},
        settings.SECRET_KEY,
        algorithm=settings.ALGORITHM,
    )
    r = await client.get("/users/me", headers={"Authorization": f"Bearer {bad}"})
    assert r.status_code == 401
