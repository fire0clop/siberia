import asyncio
import logging
from fastapi import WebSocket

logger = logging.getLogger("siberia.ws")


class _ConnectionManager:
    """Реестр активных WebSocket-соединений для graceful shutdown."""

    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()

    def register(self, ws: WebSocket) -> None:
        self._connections.add(ws)

    def unregister(self, ws: WebSocket) -> None:
        self._connections.discard(ws)

    @property
    def count(self) -> int:
        return len(self._connections)

    async def shutdown(self) -> None:
        """Закрыть все активные соединения при остановке сервера."""
        if not self._connections:
            return
        logger.info("Closing %d active WebSocket connections", self.count)
        await asyncio.gather(
            *(ws.close(code=1001) for ws in list(self._connections)),
            return_exceptions=True,
        )
        self._connections.clear()


ws_manager = _ConnectionManager()
