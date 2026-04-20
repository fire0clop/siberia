import redis.asyncio as redis

from config import settings

redis_client = redis.from_url(
    settings.REDIS_URL,
    decode_responses=True,
)


async def publish(channel: str, message: str):
    await redis_client.publish(channel, message)


async def subscribe(channel: str):
    pubsub = redis_client.pubsub()
    await pubsub.subscribe(channel)
    return pubsub


async def redis_ping() -> bool:
    try:
        return await redis_client.ping()
    except Exception:
        return False


async def close_redis():
    await redis_client.aclose()


# ── Online presence ───────────────────────────────────────────────────────────
# Счётчик активных WS-соединений пользователя.
# Если > 0 → считаем пользователя онлайн → шлём тихий пуш вместо полного.

_PRESENCE_TTL = 90  # секунд — немного больше PING_INTERVAL(25) + PING_TIMEOUT(10) * 2


async def presence_connect(user_id: int) -> bool:
    """Инкрементирует счётчик подключений. Возвращает True если это был первый
    коннект (т.е. user только что стал онлайн) — чтобы вызывающий разослал presence_change."""
    key = f"ws:conn:{user_id}"
    val = await redis_client.incr(key)
    await redis_client.expire(key, _PRESENCE_TTL)
    return int(val) == 1


async def presence_disconnect(user_id: int) -> bool:
    """Декрементирует счётчик. Возвращает True если это был последний дисконнект
    (счётчик дошёл до 0) — чтобы разослать «ушёл в офлайн»."""
    key = f"ws:conn:{user_id}"
    val = await redis_client.decr(key)
    if val <= 0:
        await redis_client.delete(key)
        return True
    return False


async def presence_refresh(user_id: int) -> None:
    """Вызывать при каждом входящем WS-фрейме чтобы не протух TTL."""
    await redis_client.expire(f"ws:conn:{user_id}", _PRESENCE_TTL)


async def is_online(user_id: int) -> bool:
    val = await redis_client.get(f"ws:conn:{user_id}")
    return bool(val and int(val) > 0)


# ── Generic cache helpers ─────────────────────────────────────────────────────

async def cache_set(key: str, value: str, ttl: int = 300) -> None:
    await redis_client.set(key, value, ex=ttl)


async def cache_get(key: str) -> str | None:
    return await redis_client.get(key)


async def cache_delete(key: str) -> None:
    await redis_client.delete(key)


# ── Session revocation blacklist ──────────────────────────────────────────────
# Когда сессия удаляется (logout, revoke, kick, change password, delete account),
# мы кладём session_id в blacklist на время равное access-token TTL.
# Любой HTTP-запрос и WS-кадр с access-токеном этой сессии будет отклонён.

_REVOKED_PREFIX = "revoked_session:"


async def mark_session_revoked(session_id: int, ttl_seconds: int) -> None:
    if session_id is None or ttl_seconds <= 0:
        return
    await redis_client.set(f"{_REVOKED_PREFIX}{session_id}", "1", ex=ttl_seconds)


async def is_session_revoked(session_id) -> bool:
    if session_id is None:
        return False
    try:
        sid = int(session_id)
    except (TypeError, ValueError):
        return False
    val = await redis_client.get(f"{_REVOKED_PREFIX}{sid}")
    return val is not None


# ── Email verification anti-brute-force ───────────────────────────────────────

_VERIFY_ATTEMPTS_PREFIX = "verify_attempts:"
_VERIFY_LOCKOUT_PREFIX = "verify_lockout:"


async def verify_attempts_inc(user_id: int, ttl_seconds: int) -> int:
    """Инкрементирует счётчик попыток ввода email-кода. Возвращает текущее значение."""
    key = f"{_VERIFY_ATTEMPTS_PREFIX}{user_id}"
    val = await redis_client.incr(key)
    if val == 1:
        await redis_client.expire(key, ttl_seconds)
    return int(val)


async def verify_attempts_reset(user_id: int) -> None:
    await redis_client.delete(f"{_VERIFY_ATTEMPTS_PREFIX}{user_id}")
    await redis_client.delete(f"{_VERIFY_LOCKOUT_PREFIX}{user_id}")


async def verify_set_lockout(user_id: int, ttl_seconds: int) -> None:
    await redis_client.set(f"{_VERIFY_LOCKOUT_PREFIX}{user_id}", "1", ex=ttl_seconds)


async def verify_is_locked(user_id: int) -> bool:
    val = await redis_client.get(f"{_VERIFY_LOCKOUT_PREFIX}{user_id}")
    return val is not None


# ── Typing indicator throttle ─────────────────────────────────────────────────
# Не публикуем typing-event чаще чем раз в N секунд для одной пары (chat, user).

_TYPING_THROTTLE_PREFIX = "typing_throttle:"
_TYPING_THROTTLE_SEC = 3


async def typing_can_publish(chat_id: int, user_id: int) -> bool:
    """Возвращает True если для этой (chat, user)-пары прошло достаточно времени
    с последнего typing-event. Если True — отметка ставится автоматически."""
    key = f"{_TYPING_THROTTLE_PREFIX}{chat_id}:{user_id}"
    # SET с NX: установится только если ключа нет → True
    result = await redis_client.set(key, "1", ex=_TYPING_THROTTLE_SEC, nx=True)
    return bool(result)
