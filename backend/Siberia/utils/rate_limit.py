"""Per-key (per-IP) rate limiting for fastapi-limiter.

Раньше в Limiter() передавался голый InMemoryBucket — pyrate-limiter
заворачивает его в SingleBucketFactory, чей get() игнорирует ключ item'а.
fastapi-limiter честно передаёт ключ "ip:route:dep", но все клиенты попадали
в ОДИН общий бакет: 10 запросов в минуту от одного анонима блокировали
логин/регистрацию для всех.

PerKeyBucketFactory маршрутизирует каждый ключ в собственный InMemoryBucket.

Ограничение (сознательное, как и раньше): бакеты in-memory, то есть лимиты
считаются на каждый процесс отдельно. Для multi-worker/multi-instance
понадобится RedisBucket — отдельная задача из «Блока 8».
"""
from __future__ import annotations

from pyrate_limiter import (
    AbstractBucket,
    BucketFactory,
    InMemoryBucket,
    Limiter,
    MonotonicClock,
    Rate,
    RateItem,
)


class PerKeyBucketFactory(BucketFactory):
    """Отдельный InMemoryBucket на каждый ключ (fastapi-limiter шлёт "ip:route:dep")."""

    # Жёсткий потолок числа ключей, чтобы враждебный трафик с миллионов IP
    # не растил память безгранично.
    _MAX_KEYS = 10_000

    def __init__(self, rates: list[Rate]):
        self._rates = rates
        self._buckets: dict[str, InMemoryBucket] = {}
        self._clock = MonotonicClock()

    def wrap_item(self, name: str, weight: int = 1) -> RateItem:
        return RateItem(name, self._clock.now(), weight=weight)

    def get(self, item: RateItem) -> AbstractBucket:
        bucket = self._buckets.get(item.name)
        if bucket is None:
            if len(self._buckets) >= self._MAX_KEYS:
                self._evict_idle()
            bucket = self.create(InMemoryBucket, self._rates)
            self._buckets[item.name] = bucket
        return bucket

    def _evict_idle(self) -> None:
        """Выбрасываем бакеты, у которых все записи старше самого длинного окна."""
        now = self._clock.now()
        for key, bucket in list(self._buckets.items()):
            bucket.leak(now)
            if not bucket.items:
                self.dispose(bucket)
                del self._buckets[key]
        if len(self._buckets) >= self._MAX_KEYS:
            # Все бакеты активны (распределённая атака) — сбрасываем всё разом:
            # потерять состояние лимитов безопаснее, чем расти памятью.
            for bucket in self._buckets.values():
                self.dispose(bucket)
            self._buckets.clear()


def per_ip_limiter(*rates: Rate) -> Limiter:
    """Limiter с независимым бакетом на каждый ключ (IP + route)."""
    return Limiter(PerKeyBucketFactory(list(rates)))
