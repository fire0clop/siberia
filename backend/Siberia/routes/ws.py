import asyncio
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, HTTPException
from sqlalchemy.future import select

from config import settings
from db import async_session_maker
from models.user import User
from models.chat_member import ChatMember
from services.message import create_message, mark_read
from utils.jwt import decode_token
from utils.redis import publish, subscribe, presence_connect, presence_disconnect, presence_refresh, is_session_revoked, typing_can_publish
from utils.ws_manager import ws_manager
from services.user_service import update_last_seen
from services.presence_broadcast import broadcast_presence
from models.privacy_settings import PrivacySetting


async def _is_invisible(user_id: int) -> bool:
    """Возвращает True если у пользователя включен invisible_mode."""
    async with async_session_maker() as _db:
        ps = await _db.get(PrivacySetting, user_id)
        return bool(ps and ps.invisible_mode)


def _chat_presence_envelope(user_id: int, chat_id: int, online: bool) -> str:
    return json.dumps({
        "v": 1,
        "type": "presence_change",
        "event": "presence_change",
        "chat_id": chat_id,
        "payload": {
            "user_id": user_id,
            "online": online,
            "last_seen_at": datetime.now(timezone.utc).isoformat(),
        },
    })

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ws", tags=["WebSocket"])

# Heartbeat: сервер шлёт ping каждые WS_PING_INTERVAL секунд, ждёт pong WS_PING_TIMEOUT — иначе закрывает
_PING_INTERVAL = settings.WS_PING_INTERVAL
_PING_TIMEOUT = settings.WS_PING_TIMEOUT


async def _get_user_from_token(token: str, db):
    try:
        payload = decode_token(token)
    except Exception:
        return None
    if payload.get("type") != "access":
        return None
    user_id = int(payload.get("sub"))
    result = await db.execute(
        select(User).where(User.id == user_id, User.deleted_at.is_(None))
    )
    return result.scalars().first()


def _extract_token(websocket: WebSocket) -> str | None:
    """Достаём access-token либо из Authorization header (Bearer ...), либо из ?token=.

    Header — предпочтительный способ: не попадает в логи прокси / access-логи.
    ?token= разрешён только вне production: там URL со всеми query-параметрами
    оседает в access-логах балансировщика.
    """
    auth = websocket.headers.get("authorization") or websocket.headers.get("Authorization")
    if auth and auth.lower().startswith("bearer "):
        return auth.split(" ", 1)[1].strip() or None
    if settings.ENV.lower() == "production":
        return None
    qp = websocket.query_params.get("token")
    return qp or None


async def _check_membership(db, user_id: int, chat_id: int):
    result = await db.execute(
        select(ChatMember).where(
            ChatMember.user_id == user_id,
            ChatMember.chat_id == chat_id,
        )
    )
    return result.scalars().first()


def _token_expired(token: str) -> bool:
    """True если токен не валиден или истёк. НЕ проверяет revoke (это async)."""
    try:
        payload = decode_token(token)
        return datetime.now(timezone.utc).timestamp() > payload.get("exp", 0)
    except Exception:
        return True


async def _token_invalid(token: str) -> bool:
    """True если токен истёк ИЛИ сессия отозвана (revoked в Redis)."""
    if _token_expired(token):
        return True
    try:
        payload = decode_token(token)
    except Exception:
        return True
    return await is_session_revoked(payload.get("session_id"))


async def _recv_with_heartbeat(websocket: WebSocket, token: str):
    """
    Ждёт следующий фрейм от клиента.
    Отправляет ping если клиент молчит _PING_INTERVAL секунд.
    Закрывает соединение если нет pong за _PING_TIMEOUT секунд после ping.
    Возвращает raw str или None при закрытии.
    """
    waiting_pong = False

    while True:
        timeout = _PING_TIMEOUT if waiting_pong else _PING_INTERVAL
        try:
            raw = await asyncio.wait_for(websocket.receive_text(), timeout=timeout)
        except asyncio.TimeoutError:
            if waiting_pong:
                # Клиент не ответил на ping — разрываем
                await websocket.close(code=1001)
                return None
            # Пора отправить ping
            try:
                await websocket.send_text(json.dumps({"type": "ping"}))
            except Exception as exc:
                logger.debug("WS send ping failed: %s", exc)
                return None
            waiting_pong = True
            continue

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("WS got invalid JSON frame, skipping")
            continue

        if data.get("type") == "pong":
            waiting_pong = False
            continue

        return raw  # валидный фрейм — передаём в основной обработчик


# ─────────────────────────────────────────────────────────────────────────────
# /ws/me  — персональный канал (все чаты пользователя)
# ─────────────────────────────────────────────────────────────────────────────
@router.websocket("/me")
async def websocket_user_inbox(websocket: WebSocket):
    await websocket.accept()

    token = _extract_token(websocket)
    if not token:
        await websocket.close(code=1008)
        return

    async with async_session_maker() as db:
        user = await _get_user_from_token(token, db)
        if not user:
            await websocket.close(code=1008)
            return

    # Reject revoked sessions at handshake too
    if await _token_invalid(token):
        await websocket.close(code=1008)
        return

    ws_manager.register(websocket)
    first = await presence_connect(user.id)
    invisible = await _is_invisible(user.id)
    # В invisible mode НЕ объявляем всем что мы онлайн —
    # это произойдёт только в /ws/{chat_id} и только для собеседника по чату.
    if first and not invisible:
        await broadcast_presence(user.id, is_online=True)
    async with async_session_maker() as _db:
        await update_last_seen(_db, user.id)
    channel = f"user:{user.id}"
    pubsub = await subscribe(channel)

    async def _listener():
        try:
            async for msg in pubsub.listen():
                if msg["type"] == "message":
                    await websocket.send_text(msg["data"])
        except Exception as exc:
            logger.exception("WS /me pubsub listener failed: %s", exc)

    listener_task = asyncio.create_task(_listener())

    try:
        while True:
            raw = await _recv_with_heartbeat(websocket, token)
            if raw is None:
                break

            if await _token_invalid(token):
                await websocket.close(code=1008)
                break

            await presence_refresh(user.id)

            # ── Inbound call signaling (SDP offer/answer + ICE candidates) ──
            # Клиент пересылает сюда SDP/ICE — сервер валидирует участие в звонке
            # и пушит пиру через user:{peer_id} канал.
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if data.get("type") == "call_signal":
                call_id = data.get("call_id")
                kind    = data.get("kind")
                payload = data.get("payload") or {}
                if isinstance(call_id, int) and isinstance(kind, str):
                    try:
                        from services.call_service import relay_signal
                        async with async_session_maker() as _db:
                            await relay_signal(_db, user.id, call_id, kind, payload)
                    except HTTPException as exc:
                        try:
                            await websocket.send_text(json.dumps({
                                "type": "error", "code": exc.status_code, "detail": exc.detail,
                            }))
                        except Exception:
                            pass

    except WebSocketDisconnect:
        pass
    finally:
        ws_manager.unregister(websocket)
        last = await presence_disconnect(user.id)
        # Re-check invisible state on disconnect (мог измениться за время сессии)
        invisible = await _is_invisible(user.id)
        if last and not invisible:
            await broadcast_presence(user.id, is_online=False)
        async with async_session_maker() as _db:
            await update_last_seen(_db, user.id)
        listener_task.cancel()
        try:
            await listener_task
        except asyncio.CancelledError:
            pass
        await pubsub.unsubscribe(channel)
        await pubsub.aclose()


# ─────────────────────────────────────────────────────────────────────────────
# /ws/{chat_id}  — комната чата
# ─────────────────────────────────────────────────────────────────────────────
@router.websocket("/{chat_id}")
async def websocket_endpoint(websocket: WebSocket, chat_id: int):
    await websocket.accept()

    token = _extract_token(websocket)
    if not token:
        await websocket.close(code=1008)
        return

    async with async_session_maker() as db:
        user = await _get_user_from_token(token, db)
        if not user:
            await websocket.close(code=1008)
            return
        if not await _check_membership(db, user.id, chat_id):
            await websocket.close(code=1008)
            return

    if await _token_invalid(token):
        await websocket.close(code=1008)
        return

    ws_manager.register(websocket)
    first = await presence_connect(user.id)
    invisible = await _is_invisible(user.id)
    if first and not invisible:
        # Обычный режим — global broadcast другим (друзьям/DM-партнёрам)
        await broadcast_presence(user.id, is_online=True)
    if invisible:
        # Невидимка — публикуем «онлайн» только в комнату ЭТОГО чата.
        # Подписаны на неё только активные участники /ws/{chat_id}.
        await publish(f"chat:{chat_id}", _chat_presence_envelope(user.id, chat_id, online=True))
    async with async_session_maker() as _db:
        await update_last_seen(_db, user.id)
    channel = f"chat:{chat_id}"
    pubsub = await subscribe(channel)

    async def _listener():
        try:
            async for msg in pubsub.listen():
                if msg["type"] == "message":
                    await websocket.send_text(msg["data"])
        except Exception as exc:
            logger.exception("WS /{chat_id} pubsub listener failed: %s", exc)

    listener_task = asyncio.create_task(_listener())

    try:
        while True:
            raw = await _recv_with_heartbeat(websocket, token)
            if raw is None:
                break

            if await _token_invalid(token):
                await websocket.close(code=1008)
                break

            await presence_refresh(user.id)

            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue

            event = data.get("type")

            async with async_session_maker() as db:
                try:
                    if event == "message":
                        text = data.get("text")
                        if not text:
                            continue

                        from uuid import UUID as _UUID
                        cmid = None
                        if data.get("client_message_id"):
                            try:
                                cmid = _UUID(str(data["client_message_id"]))
                            except ValueError:
                                continue

                        rto_id = None
                        rto = data.get("reply_to_message_id")
                        if rto is not None:
                            try:
                                rto_id = int(rto)
                            except (TypeError, ValueError):
                                continue

                        await create_message(
                            db, user.id, chat_id, text,
                            client_message_id=cmid,
                            reply_to_message_id=rto_id,
                        )

                    elif event == "typing":
                        # Проверяем актуальное членство — пользователь мог покинуть чат
                        if not await _check_membership(db, user.id, chat_id):
                            continue
                        # Throttle: не публикуем чаще раза в 3 секунды на пару (chat, user)
                        if not await typing_can_publish(chat_id, user.id):
                            continue
                        await publish(
                            channel,
                            json.dumps({
                                "v": 1,
                                "chat_id": chat_id,
                                "event": "typing",
                                "payload": {"user_id": user.id},
                            }),
                        )

                    elif event == "read":
                        message_id = data.get("message_id")
                        if message_id is None:
                            continue
                        try:
                            mid = int(message_id)
                        except (TypeError, ValueError):
                            continue
                        await mark_read(db, mid, user.id)

                except HTTPException as exc:
                    # Отправляем ошибку клиенту вместо тихого пропуска
                    try:
                        await websocket.send_text(json.dumps({
                            "type": "error",
                            "code": exc.status_code,
                            "detail": exc.detail,
                        }))
                    except Exception as send_exc:
                        logger.debug("Failed to send WS error to client: %s", send_exc)

    except WebSocketDisconnect:
        pass
    finally:
        ws_manager.unregister(websocket)
        last = await presence_disconnect(user.id)
        invisible_now = await _is_invisible(user.id)
        if invisible_now:
            # Невидимка вышел из этого чата — сообщаем в комнату «оффлайн».
            await publish(
                f"chat:{chat_id}",
                _chat_presence_envelope(user.id, chat_id, online=False)
            )
        if last and not invisible_now:
            await broadcast_presence(user.id, is_online=False)
        async with async_session_maker() as _db:
            await update_last_seen(_db, user.id)
        listener_task.cancel()
        try:
            await listener_task
        except asyncio.CancelledError:
            pass
        await pubsub.unsubscribe(channel)
        await pubsub.aclose()
