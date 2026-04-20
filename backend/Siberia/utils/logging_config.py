import json
import logging
import traceback


class _JSONFormatter(logging.Formatter):
    """Выводит каждую запись лога как одну JSON-строку."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict = {
            "time": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key in ("request_id", "user_id", "path"):
            val = record.__dict__.get(key)
            if val is not None:
                entry[key] = val

        if record.exc_info:
            entry["exc"] = traceback.format_exception(*record.exc_info)

        return json.dumps(entry, ensure_ascii=False)


def setup_logging(debug: bool = False) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(_JSONFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.DEBUG if debug else logging.INFO)

    # Приглушаем шумные библиотечные логгеры
    logging.getLogger("sqlalchemy.engine").setLevel(
        logging.INFO if debug else logging.WARNING
    )
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.error").setLevel(logging.WARNING)
