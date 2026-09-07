"""Presence: pong должен продлевать TTL, протухший ключ — восстанавливаться (H-2)."""
import json


async def test_presence_refresh_recreates_expired_key():
    from utils.redis import is_online, presence_refresh, redis_client

    uid = 424242
    assert not await is_online(uid)

    # Ключ протух (или Redis рестартовал), а сокет жив: refresh обязан
    # восстановить ключ, а не сделать no-op EXPIRE по несуществующему.
    await presence_refresh(uid)
    assert await is_online(uid)
    ttl = await redis_client.ttl(f"ws:conn:{uid}")
    assert 0 < ttl <= 90


async def test_pong_frame_refreshes_presence():
    """_recv_with_heartbeat: pong — признак жизни, а не мусорный фрейм."""
    from routes.ws import _recv_with_heartbeat
    from utils.redis import is_online, redis_client

    uid = 515151

    class FakeWS:
        def __init__(self, frames):
            self.frames = list(frames)
            self.sent = []

        async def receive_text(self):
            return self.frames.pop(0)

        async def send_text(self, t):
            self.sent.append(t)

        async def close(self, code=1000):
            pass

    ws = FakeWS([
        json.dumps({"type": "pong"}),
        json.dumps({"type": "typing"}),
    ])

    raw = await _recv_with_heartbeat(ws, uid)
    assert json.loads(raw)["type"] == "typing"
    # Pong по пути обновил presence — молчаливый клиент больше не «офлайн»
    assert await is_online(uid)

    await redis_client.delete(f"ws:conn:{uid}")


async def test_presence_connect_disconnect_counter():
    from utils.redis import is_online, presence_connect, presence_disconnect

    uid = 616161
    assert await presence_connect(uid) is True    # первое соединение
    assert await presence_connect(uid) is False   # второе — уже онлайн
    assert await is_online(uid)
    assert await presence_disconnect(uid) is False  # одно из двух закрылось
    assert await presence_disconnect(uid) is True   # последнее → офлайн
    assert not await is_online(uid)
