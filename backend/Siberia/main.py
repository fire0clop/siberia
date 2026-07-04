from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware

from config import settings
from db import engine
from utils.redis import close_redis
from utils.logging_config import setup_logging
from utils.ws_manager import ws_manager
from utils.middleware import RequestContextMiddleware
from utils.handlers import (
    http_exception_handler,
    validation_exception_handler,
    unhandled_exception_handler,
)

from routes.auth import router as auth_router
from routes.user import router as user_router
from routes.session import router as session_router
from routes.chat import router as chat_router
from routes.message import router as message_router
from routes.friend import router as friend_router
from routes.ws import router as ws_router
from routes.health import router as health_router
from routes.search import router as search_router
from routes.devices import router as devices_router
from routes.media import router as media_router
from routes.channel import router as channel_router
from routes.call import router as call_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # ── Startup ───────────────────────────────────────────────────────────────
    setup_logging(debug=settings.DEBUG)

    yield

    # ── Shutdown ──────────────────────────────────────────────────────────────
    # 1. Закрыть все WebSocket-соединения (код 1001 = Going Away)
    await ws_manager.shutdown()
    # 2. Освободить пул соединений к БД
    await engine.dispose()
    # 3. Закрыть Redis
    await close_redis()


app = FastAPI(title="Siberia", lifespan=lifespan)

# ── CORS ──────────────────────────────────────────────────────────────────────
# Dev:  CORS_ORIGINS="*"
# Prod: CORS_ORIGINS="https://app.example.com,https://admin.example.com"
_origins = [o.strip() for o in settings.CORS_ORIGINS.split(",") if o.strip()]

# Safety guard: в production "*" + credentials небезопасно и приводит к ошибкам браузера.
# Падаем с явной ошибкой при старте, а не молча.
if settings.ENV.lower() == "production" and ("*" in _origins or not _origins):
    raise RuntimeError(
        "CORS_ORIGINS='*' is forbidden when ENV=production. "
        "Set explicit comma-separated list, e.g. CORS_ORIGINS='https://app.example.com'."
    )

# Safety guard: дефолтный / короткий SECRET_KEY в production означает,
# что любой может подделать JWT. Падаем при старте, а не молча.
_WEAK_SECRETS = {"supersecretkey", "secret", "change-me-to-a-long-random-string", "ci-test-secret-key"}
if settings.ENV.lower() == "production" and (
    settings.SECRET_KEY in _WEAK_SECRETS or len(settings.SECRET_KEY) < 32
):
    raise RuntimeError(
        "SECRET_KEY is too weak for ENV=production. "
        "Generate one: python -c \"import secrets; print(secrets.token_urlsafe(48))\""
    )

app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID"],
)

# ── Middleware & handlers ─────────────────────────────────────────────────────
app.add_middleware(RequestContextMiddleware)

app.add_exception_handler(HTTPException, http_exception_handler)
app.add_exception_handler(RequestValidationError, validation_exception_handler)
app.add_exception_handler(Exception, unhandled_exception_handler)

# ── Prometheus (опционально) ──────────────────────────────────────────────────
try:
    from prometheus_fastapi_instrumentator import Instrumentator
    Instrumentator().instrument(app).expose(app, endpoint="/metrics")
except ImportError:
    pass

# ── Роуты ─────────────────────────────────────────────────────────────────────
app.include_router(health_router)
app.include_router(auth_router)
app.include_router(user_router)
app.include_router(session_router)
app.include_router(chat_router)
app.include_router(message_router)
app.include_router(friend_router)
app.include_router(search_router)
app.include_router(devices_router)
app.include_router(media_router)
app.include_router(channel_router)
app.include_router(call_router)
app.include_router(ws_router)
