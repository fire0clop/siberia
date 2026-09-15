"""Глобальный per-IP rate limit: страховка от спама запросами на всё API."""
from config import settings


async def test_global_limit_kicks_in_per_ip(client, monkeypatch):
    monkeypatch.setattr(settings, "GLOBAL_RATE_LIMIT_PER_MINUTE", 5)

    ip_a = {"X-Forwarded-For": "203.0.113.10"}
    ip_b = {"X-Forwarded-For": "203.0.113.20"}

    # Первые 5 запросов с IP A проходят (401 — без токена, но НЕ 429)
    for i in range(5):
        r = await client.get("/users/me", headers=ip_a)
        assert r.status_code != 429, f"request {i} unexpectedly limited"

    # Шестой — отбой с Retry-After
    r = await client.get("/users/me", headers=ip_a)
    assert r.status_code == 429
    assert r.headers.get("retry-after")

    # Другой IP живёт своим бюджетом
    r = await client.get("/users/me", headers=ip_b)
    assert r.status_code != 429


async def test_health_exempt_from_global_limit(client, monkeypatch):
    monkeypatch.setattr(settings, "GLOBAL_RATE_LIMIT_PER_MINUTE", 3)
    ip = {"X-Forwarded-For": "203.0.113.30"}

    # Пробы здоровья не должны считаться и не должны отбиваться
    for _ in range(10):
        r = await client.get("/health/live", headers=ip)
        assert r.status_code == 200

    # Бюджет обычных запросов при этом не потрачен
    for _ in range(3):
        assert (await client.get("/users/me", headers=ip)).status_code != 429
    assert (await client.get("/users/me", headers=ip)).status_code == 429


async def test_zero_disables_global_limit(client, monkeypatch):
    monkeypatch.setattr(settings, "GLOBAL_RATE_LIMIT_PER_MINUTE", 0)
    ip = {"X-Forwarded-For": "203.0.113.40"}
    for _ in range(20):
        assert (await client.get("/users/me", headers=ip)).status_code != 429
