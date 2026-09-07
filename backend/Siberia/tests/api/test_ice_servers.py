"""GET /calls/ice-servers: STUN всегда, TURN с эфемерными HMAC-кредами."""
import base64
import hashlib
import hmac

from config import settings


async def test_stun_only_when_turn_not_configured(client, register_user, monkeypatch):
    monkeypatch.setattr(settings, "TURN_URLS", "")
    monkeypatch.setattr(settings, "TURN_STATIC_AUTH_SECRET", "")
    u = await register_user("ice_a")

    r = await client.get("/calls/ice-servers", headers=u.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ttl_expires_at"] is None
    urls = [s["urls"] for s in body["ice_servers"]]
    assert any(any("stun:" in u for u in group) for group in urls)
    # без TURN — только STUN, без кредов
    for s in body["ice_servers"]:
        assert s["username"] is None
        assert s["credential"] is None


async def test_turn_credentials_are_valid_hmac(client, register_user, monkeypatch):
    secret = "test-turn-secret"
    monkeypatch.setattr(settings, "TURN_URLS", "turn:turn.siberia.app:3478")
    monkeypatch.setattr(settings, "TURN_STATIC_AUTH_SECRET", secret)
    monkeypatch.setattr(settings, "TURN_TTL_SECONDS", 3600)
    u = await register_user("ice_b")

    r = await client.get("/calls/ice-servers", headers=u.headers)
    body = r.json()
    assert body["ttl_expires_at"] is not None

    turn = next(s for s in body["ice_servers"] if any("turn:" in x for x in s["urls"]))
    # username = "<expiry>:<user_id>"
    expiry_str, uid_str = turn["username"].split(":")
    assert int(uid_str) == u.id
    assert int(expiry_str) == body["ttl_expires_at"]

    # credential = base64(HMAC-SHA1(secret, username)) — проверяем сами
    expected = base64.b64encode(
        hmac.new(secret.encode(), turn["username"].encode(), hashlib.sha1).digest()
    ).decode()
    assert turn["credential"] == expected


async def test_ice_requires_auth(client):
    r = await client.get("/calls/ice-servers")
    assert r.status_code in (401, 403)
