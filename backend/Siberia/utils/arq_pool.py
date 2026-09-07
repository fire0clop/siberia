"""Ленивый ARQ-пул для постановки фоновых задач из API-процесса."""
import logging

from arq import create_pool
from arq.connections import RedisSettings

from config import settings

logger = logging.getLogger(__name__)

_pool = None


async def enqueue_job(fn_name: str, *args, **kwargs) -> bool:
    """Ставит задачу в очередь ARQ. Ошибки только логируются (best-effort)."""
    global _pool
    try:
        if _pool is None:
            _pool = await create_pool(RedisSettings.from_dsn(settings.REDIS_URL))
        await _pool.enqueue_job(fn_name, *args, **kwargs)
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("arq enqueue %s failed: %s", fn_name, exc)
        return False
