"""Pytest-инфраструктура (Блок 4 плана).

Принципы:
- Самодостаточность: локально фикстуры сами поднимают redis-server на отдельном
  порту и создают отдельную БД siberia_test (drop+create на сессию, схема —
  через `alembic upgrade head`, что заодно проверяет цепочку миграций).
- В CI переменные DATABASE_URL/REDIS_URL уже заданы — используем их
  (имя БД всё равно переписывается на siberia_test, чтобы не трогать данные e2e).
- Все env-переменные выставляются ДО импорта config/app.
"""
from __future__ import annotations

import asyncio
import os
import socket
import subprocess
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

BACKEND_DIR = Path(__file__).resolve().parent.parent
TEST_DB_NAME = "siberia_test"
_LOCAL_REDIS_PORT = 6399

# ── env ДО импорта приложения ────────────────────────────────────────────────

def _rewrite_db_name(url: str, dbname: str) -> str:
    parts = urlsplit(url)
    return urlunsplit(parts._replace(path=f"/{dbname}"))


_ext_db = os.environ.get("DATABASE_URL")  # задан в CI
if _ext_db:
    _test_db_url = _rewrite_db_name(_ext_db, TEST_DB_NAME)
    _admin_db_url = _ext_db  # база из CI (siberia) годится как admin-подключение
else:
    _user = os.environ.get("USER", "postgres")
    _test_db_url = f"postgresql+asyncpg://{_user}@localhost:5432/{TEST_DB_NAME}"
    _admin_db_url = f"postgresql+asyncpg://{_user}@localhost:5432/postgres"

_ext_redis = os.environ.get("REDIS_URL")  # задан в CI
_spawn_redis = _ext_redis is None
_redis_url = _ext_redis or f"redis://localhost:{_LOCAL_REDIS_PORT}/0"

os.environ["DATABASE_URL"] = _test_db_url
os.environ["REDIS_URL"] = _redis_url
os.environ.setdefault("SECRET_KEY", "pytest-secret-key-not-for-production-0123456789abcdef")
os.environ.setdefault("ALGORITHM", "HS256")
os.environ.setdefault("ACCESS_TOKEN_EXPIRE_DAYS", "1")
os.environ.setdefault("REFRESH_TOKEN_EXPIRE_DAYS", "30")
os.environ["ENV"] = "development"
os.environ["DEBUG"] = "false"
os.environ["CORS_ORIGINS"] = "*"
# SMTP заведомо мёртвый: письма — fire-and-forget, ошибки только логируются
os.environ["SMTP_HOST"] = "127.0.0.1"
os.environ["SMTP_PORT"] = "1"

import psycopg2  # noqa: E402
import pytest  # noqa: E402


def _sync_dsn(url: str) -> str:
    return url.replace("+asyncpg", "", 1).replace("postgresql+psycopg2", "postgresql", 1)


def _wait_port(host: str, port: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as s:
            s.settimeout(0.3)
            try:
                s.connect((host, port))
                return
            except OSError:
                time.sleep(0.1)
    raise RuntimeError(f"port {host}:{port} did not come up in {timeout}s")


# ── Session-scoped: redis + база + миграции ──────────────────────────────────

@pytest.fixture(scope="session", autouse=True)
def _redis_server():
    if not _spawn_redis:
        yield
        return
    proc = subprocess.Popen(
        ["redis-server", "--port", str(_LOCAL_REDIS_PORT), "--save", "", "--appendonly", "no"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        _wait_port("localhost", _LOCAL_REDIS_PORT)
        yield
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.fixture(scope="session", autouse=True)
def _test_database():
    conn = psycopg2.connect(_sync_dsn(_admin_db_url))
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{TEST_DB_NAME}" WITH (FORCE)')
        cur.execute(f'CREATE DATABASE "{TEST_DB_NAME}"')
    conn.close()

    # Схема через реальную цепочку миграций — она тоже под тестом
    subprocess.run(
        ["alembic", "upgrade", "head"],
        cwd=BACKEND_DIR,
        env={**os.environ, "DATABASE_URL": _test_db_url},
        check=True,
        capture_output=True,
        text=True,
    )
    yield


# ── Loop-паттерн: один event loop на сессию (engine в db.py один на процесс) ──

@pytest.fixture(scope="session")
def event_loop_policy():
    return asyncio.DefaultEventLoopPolicy()


# ── Per-test чистка ──────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
async def _clean_state(_redis_server, _test_database):
    """Перед каждым тестом: пустые таблицы и пустой Redis."""
    from db import async_session_maker
    from sqlalchemy import text
    from utils.redis import redis_client

    async with async_session_maker() as db:
        result = await db.execute(text(
            "SELECT tablename FROM pg_tables "
            "WHERE schemaname='public' AND tablename != 'alembic_version'"
        ))
        tables = [row[0] for row in result.all()]
        if tables:
            joined = ", ".join(f'"{t}"' for t in tables)
            await db.execute(text(f"TRUNCATE {joined} RESTART IDENTITY CASCADE"))
            await db.commit()
    await redis_client.flushdb()
    yield


# ── HTTP-клиент поверх ASGI ──────────────────────────────────────────────────

@pytest.fixture
async def client():
    import httpx
    from main import app

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        yield c


# ── Хелперы регистрации ──────────────────────────────────────────────────────

class TestUser:
    __test__ = False  # не собирать pytest'ом как тест-класс

    def __init__(self, email, nickname, password, device_id, access, refresh, user_id, client_ip):
        self.email = email
        self.nickname = nickname
        self.password = password
        self.device_id = device_id
        self.access = access
        self.refresh = refresh
        self.id = user_id
        self.client_ip = client_ip

    @property
    def headers(self) -> dict:
        # Уникальный X-Forwarded-For на пользователя: per-IP rate limit
        # не должен душить сами тесты (10 регистраций/мин на IP)
        return {
            "Authorization": f"Bearer {self.access}",
            "X-Device-ID": self.device_id,
            "X-Forwarded-For": self.client_ip,
        }


@pytest.fixture
def register_user(client):
    async def _register(prefix: str = "u", password: str = "password-123") -> TestUser:
        suffix = uuid.uuid4().hex[:10]
        email = f"{prefix}_{suffix}@example.com"
        nickname = f"{prefix}_{suffix}"
        device_id = f"dev-{suffix}"
        ip = f"10.{uuid.uuid4().bytes[0]}.{uuid.uuid4().bytes[0]}.{uuid.uuid4().bytes[0]}"
        r = await client.post(
            "/auth/register",
            json={"email": email, "nickname": nickname, "password": password},
            headers={"X-Device-ID": device_id, "X-Forwarded-For": ip},
        )
        assert r.status_code == 200, f"register failed: {r.status_code} {r.text}"
        body = r.json()
        return TestUser(
            email=email, nickname=nickname, password=password, device_id=device_id,
            access=body["access_token"], refresh=body["refresh_token"],
            user_id=body["user"]["id"], client_ip=ip,
        )
    return _register
