"""PerKeyBucketFactory: лимиты должны считаться per-key, а не глобально.

Регрессия: Limiter(InMemoryBucket) заворачивался в SingleBucketFactory,
чей get() игнорирует ключ — все клиенты делили один бакет, и 10 запросов
одного анонима блокировали логин всем.
"""
from pyrate_limiter import Duration, Limiter, Rate

from utils.rate_limit import PerKeyBucketFactory, per_ip_limiter


def _limited(limiter: Limiter, key: str) -> bool:
    """True если запрос по ключу НЕ прошёл лимит."""
    return limiter.try_acquire(key, blocking=False) is False


def test_each_key_has_its_own_budget():
    limiter = per_ip_limiter(Rate(3, Duration.MINUTE))

    for _ in range(3):
        assert not _limited(limiter, "1.2.3.4:/auth/login")
    # четвёртый запрос с того же IP — отбой
    assert _limited(limiter, "1.2.3.4:/auth/login")

    # а другой IP живёт своим бюджетом
    for _ in range(3):
        assert not _limited(limiter, "5.6.7.8:/auth/login")
    assert _limited(limiter, "5.6.7.8:/auth/login")


def test_routes_do_not_share_budget():
    limiter = per_ip_limiter(Rate(2, Duration.MINUTE))
    for _ in range(2):
        assert not _limited(limiter, "1.2.3.4:/auth/login")
    assert _limited(limiter, "1.2.3.4:/auth/login")
    # другой route (другой суффикс ключа) — свой бюджет
    assert not _limited(limiter, "1.2.3.4:/auth/register")


def test_key_cap_does_not_grow_unbounded():
    factory = PerKeyBucketFactory([Rate(2, Duration.MINUTE)])
    factory._MAX_KEYS = 50  # маленький потолок для теста
    limiter = Limiter(factory)
    for i in range(120):
        limiter.try_acquire(f"ip-{i}", blocking=False)
    assert len(factory._buckets) <= 51  # потолок + текущий ключ
