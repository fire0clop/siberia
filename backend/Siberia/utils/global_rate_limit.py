"""Глобальный per-IP rate limit — страховка от спама запросами в целом.

Точечные лимиты на /auth и /2fa остаются как были; этот слой ловит всё
остальное: залипшие клиентские циклы (как бесконечный ретрай битой
картинки), скрипты, перебор эндпоинтов. Порог щедрый — легитимный клиент
его не видит.

Не считает /health* (пробы оркестратора), /metrics (Prometheus) и
websocket-соединения (BaseHTTPMiddleware обрабатывает только http-scope).
"""
from __future__ import annotations

import logging

from pyrate_limiter import Duration, Limiter, Rate
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from config import settings
from utils.rate_limit import PerKeyBucketFactory

logger = logging.getLogger(__name__)

_EXEMPT_PREFIXES = ("/health", "/metrics")


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


class GlobalRateLimitMiddleware(BaseHTTPMiddleware):
    def __init__(self, app):
        super().__init__(app)
        self._limit = 0
        self._limiter: Limiter | None = None
        self._rebuild()

    def _rebuild(self) -> None:
        """Пересобирает лимитер при изменении настройки (удобно для тестов)."""
        limit = int(settings.GLOBAL_RATE_LIMIT_PER_MINUTE)
        if limit == self._limit and (self._limiter is not None or limit <= 0):
            return
        self._limit = limit
        self._limiter = (
            Limiter(PerKeyBucketFactory([Rate(limit, Duration.MINUTE)]))
            if limit > 0 else None
        )

    async def dispatch(self, request: Request, call_next):
        self._rebuild()
        limiter = self._limiter
        if limiter is None or request.url.path.startswith(_EXEMPT_PREFIXES):
            return await call_next(request)

        key = f"global:{_client_ip(request)}"
        allowed = await limiter.try_acquire_async(key, blocking=False)
        if not allowed:
            logger.warning("Global rate limit hit: %s %s", key, request.url.path)
            return JSONResponse(
                status_code=429,
                content={"detail": "Too many requests"},
                headers={"Retry-After": "30"},
            )
        return await call_next(request)
