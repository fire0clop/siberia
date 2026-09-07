"""FCM v1: OAuth2 JWT-bearer flow + корректная обработка ответов (H-9).

Legacy API мёртв; проверяем что новый путь строит валидный запрос к v1
endpoint и правильно трактует коды ответа (мок httpx, без реальной сети).
"""
import json
import subprocess

import httpx
import pytest

import services.push_fcm as fcm
from config import settings


@pytest.fixture
def sa_file(tmp_path):
    """Реальный сервис-аккаунт JSON с RSA-ключом (проверяет подпись RS256)."""
    private_key = subprocess.run(
        ["openssl", "genrsa", "2048"], capture_output=True, text=True
    ).stdout
    sa = {
        "type": "service_account",
        "project_id": "siberia-test",
        "client_email": "fcm@siberia-test.iam.gserviceaccount.com",
        "private_key": private_key,
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    p = tmp_path / "sa.json"
    p.write_text(json.dumps(sa))
    return str(p)


@pytest.fixture(autouse=True)
def _reset_fcm_state():
    # Модуль кеширует SA/токен на процесс — сбрасываем между тестами
    fcm._sa = None
    fcm._sa_failed = False
    fcm._token = None
    fcm._token_exp = 0.0
    yield
    fcm._sa = None
    fcm._sa_failed = False
    fcm._token = None
    fcm._token_exp = 0.0


class _FakeResp:
    def __init__(self, status, payload):
        self.status_code = status
        self._payload = payload
        self.text = json.dumps(payload)

    def json(self):
        return self._payload


def _install_fake_http(monkeypatch, captured, *, token_status=200, send_status=200, send_body=None):
    async def fake_post(self, url, **kwargs):
        if url.endswith("/token"):
            captured["token_request"] = kwargs.get("data")
            return _FakeResp(token_status, {"access_token": "ya29.fake", "expires_in": 3600})
        captured["send_url"] = url
        captured["send_json"] = kwargs.get("json")
        captured["send_headers"] = kwargs.get("headers")
        return _FakeResp(send_status, send_body or {})

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)


async def test_not_configured_skips(monkeypatch):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "")
    monkeypatch.setattr(settings, "FCM_CREDENTIALS_PATH", "")
    # Никакой сети — просто True
    assert await fcm.send("tok", "t", "b", {}) is True


async def test_send_builds_v1_request(monkeypatch, sa_file):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "siberia-test")
    monkeypatch.setattr(settings, "FCM_CREDENTIALS_PATH", sa_file)
    captured = {}
    _install_fake_http(monkeypatch, captured)

    ok = await fcm.send("device-abc", "Заголовок", "Тело", {"chat_id": 7})
    assert ok is True

    # Токен получен через JWT-bearer grant
    assert captured["token_request"]["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert captured["token_request"]["assertion"]

    # Запрос идёт на v1 endpoint с Bearer-токеном
    assert captured["send_url"] == "https://fcm.googleapis.com/v1/projects/siberia-test/messages:send"
    assert captured["send_headers"]["Authorization"] == "Bearer ya29.fake"
    msg = captured["send_json"]["message"]
    assert msg["token"] == "device-abc"
    assert msg["notification"] == {"title": "Заголовок", "body": "Тело"}
    assert msg["android"]["priority"] == "HIGH"
    # data-значения приведены к строкам
    assert msg["data"] == {"chat_id": "7"}


async def test_unregistered_token_returns_false(monkeypatch, sa_file):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "siberia-test")
    monkeypatch.setattr(settings, "FCM_CREDENTIALS_PATH", sa_file)
    captured = {}
    _install_fake_http(
        monkeypatch, captured,
        send_status=404,
        send_body={"error": {"status": "NOT_FOUND", "details": [{"errorCode": "UNREGISTERED"}]}},
    )
    # 404/UNREGISTERED → сигнал удалить токен
    assert await fcm.send("dead-token", "t", "b", {}) is False


async def test_server_error_keeps_token(monkeypatch, sa_file):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "siberia-test")
    monkeypatch.setattr(settings, "FCM_CREDENTIALS_PATH", sa_file)
    captured = {}
    _install_fake_http(monkeypatch, captured, send_status=500, send_body={"error": {"status": "INTERNAL"}})
    # 500 — не вина токена, не удаляем
    assert await fcm.send("tok", "t", "b", {}) is True


async def test_token_cached_between_sends(monkeypatch, sa_file):
    monkeypatch.setattr(settings, "FCM_PROJECT_ID", "siberia-test")
    monkeypatch.setattr(settings, "FCM_CREDENTIALS_PATH", sa_file)
    calls = {"token": 0}

    async def fake_post(self, url, **kwargs):
        if url.endswith("/token"):
            calls["token"] += 1
            return _FakeResp(200, {"access_token": "ya29.fake", "expires_in": 3600})
        return _FakeResp(200, {})

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    await fcm.send("t1", "a", "b", {})
    await fcm.send("t2", "a", "b", {})
    assert calls["token"] == 1  # второй send переиспользует токен
