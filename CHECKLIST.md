# Siberia Backend — Чек-лист состояния проекта

> Статусы: ✅ Готово | ⚠️ Частично / есть проблемы | ❌ Не реализовано | 🐛 Баг

---

## 1. Аутентификация и сессии

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 1.1 | `POST /auth/register` | ✅ | Работает. Берёт `X-Device-ID` из заголовка |
| 1.2 | `POST /auth/login` | ✅ | Исправлено: `device_id` читается из заголовка `X-Device-ID` (приоритет), fallback на тело |
| 1.3 | `POST /auth/refresh` | ✅ | Работает, проверяет device_id |
| 1.4 | `POST /auth/logout` | ✅ | Инвалидирует сессию через refresh_token |
| 1.5 | Лимит 5 сессий на пользователя | ✅ | Исправлено: добавлен `with_for_update()` — гонка устранена |
| 1.6 | Привязка токена к session_id в JWT | ✅ | В payload есть `session_id` |

---

## 2. Пользователи

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 2.1 | `GET /users/me` | ✅ | С bio, username, avatar_url, last_seen_at (privacy-фильтрация) |
| 2.2 | `PATCH /users/me` | ✅ | Обновление nickname, bio |
| 2.3 | `PATCH /users/me/avatar` | ✅ | Привязка media_id (тип image), генерирует avatar_url |
| 2.4 | `PATCH /users/me/username` | ✅ | Уникальный @username, паттерн `^[a-zA-Z0-9_]+$` |
| 2.5 | `GET /users/{id}` | ✅ | Публичный профиль с privacy-фильтрацией |
| 2.6 | `GET /users/{id}/presence` | ✅ | `{online, last_seen_at}`, учитывает privacy |
| 2.7 | `GET/PATCH /users/me/privacy` | ✅ | `last_seen`, `avatar`, `messages_from` (everyone/friends/nobody) |
| 2.8 | `GET /users/search?q=` | ✅ | Поиск по nickname и @username. Скрывает заблокированных |
| 2.9 | `GET /users/me/badge` | ✅ | Кол-во непрочитанных сообщений |
| 2.10 | Валидация email / пароля / никнейма | ✅ | EmailStr, min/max length |
| 2.11 | Хеширование паролей | ✅ | bcrypt через passlib |

---

## 3. Сессии устройств

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 3.1 | `GET /sessions` | ✅ | Работает |
| 3.2 | `DELETE /sessions/{id}` | ✅ | Проверяет принадлежность сессии пользователю |
| 3.3 | `POST /sessions/revoke_all` | ✅ | Отзывает все кроме текущей |

---

## 4. Друзья

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 4.1 | `POST /friends/add/{user_id}` | ✅ | Работает, проверяет дубликат и self-add |
| 4.2 | `GET /friends/requests` | ✅ | Только входящие заявки с `request_id` |
| 4.3 | `POST /friends/accept/{request_id}` | ✅ | Проверяет что пользователь — адресат |
| 4.4 | `GET /friends` | ✅ | Список принятых друзей как `UserOut[]` |
| 4.5 | Отклонение заявки (`reject`) | ✅ | `POST /friends/reject/{request_id}`. Повторная заявка после reject работает |
| 4.6 | Удаление из друзей | ✅ | `DELETE /friends/{user_id}`. Чат и история сохраняются |
| 4.7 | Блокировка пользователя | ✅ | `POST/DELETE /users/{id}/block`, `GET /users/me/blocked`. При блоке дружба удаляется |

---

## 5. Чаты

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 5.1 | `POST /chats` | ✅ | Создаёт или возвращает существующий приватный чат |
| 5.2 | Проверка дружбы при создании чата | ✅ | Убрана. Теперь `messages_from` в privacy (everyone/friends/nobody) контролирует первый контакт |
| 5.3 | `GET /chats` | ✅ | Сортировка `nulls_last()` + вторичный ключ `desc(Chat.id)` |
| 5.4 | Список участников в `ChatOut` | ✅ | `GET /chats/{id}/members` — `[{user, role, joined_at}]` с пагинацией |
| 5.5 | Групповые чаты | ✅ | Реализовано в Phase 6 — роли, инвайты, системные msg |

---

## 6. Сообщения

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 6.1 | `POST /chats/{id}/messages` | ✅ | Работает |
| 6.2 | `GET /chats/{id}/messages` | ✅ | История с пагинацией |
| 6.3 | `POST /messages` (авточат) | ✅ | Автоматически создаёт/находит чат |
| 6.4 | `PATCH /messages/{id}` — редактирование | ✅ | Только своё сообщение |
| 6.5 | `DELETE /messages/{id}` — мягкое удаление | ✅ | Soft delete, текст очищается |
| 6.6 | Идемпотентность по `client_message_id` | ✅ | Корректно обрабатывает дублирование |
| 6.7 | Ответ на сообщение (`reply_to`) | ✅ | Работает, проверяет что reply из того же чата |
| 6.8 | Статусы сообщений (sent/delivered/read) | ⚠️ | Модель есть, `mark_read` есть, но **нет `GET` статуса для конкретного сообщения** |
| 6.9 | Ограничение длины сообщения | ✅ | Исправлено: `max_length=4096` в схемах |
| 6.10 | Статусы мягко удалённых сообщений не чистятся | ✅ | Исправлено: `soft_delete_message` теперь удаляет строки из `message_statuses` |

---

## 7. Синхронизация

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 7.1 | `GET /chats/{id}/sync` | ✅ | Работает с `after_seq` |
| 7.2 | События: `message_new`, `message_edit`, `message_delete` | ✅ | Все три генерируются |
| 7.3 | Событие `read_receipt` | ✅ | Генерируется при mark_read |
| 7.4 | Монотонный `sync_seq` | ✅ | Инкрементируется при каждом изменении |

---

## 8. WebSocket

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 8.1 | `WS /ws/{chat_id}` — комната чата | ✅ | Работает |
| 8.2 | `WS /ws/me` — персональный канал | ✅ | Работает |
| 8.3 | Отправка сообщений через WS | ✅ | `{"type": "message", "text": "..."}` |
| 8.4 | Индикатор печатания | ✅ | `{"type": "typing"}` — broadcast в Redis |
| 8.5 | Отметка прочитанного через WS | ✅ | `{"type": "read", "message_id": N}` |
| 8.6 | Проверка токена при подключении | ✅ | Закрывает соединение с кодом 1008 |
| 8.7 | Проверка токена на каждое сообщение | ✅ | `_token_expired()` проверяется на каждый входящий WS-фрейм. Heartbeat закрывает `1001` при таймауте |
| 8.8 | Проверка членства в чате при typing | ✅ | Исправлено: перед publish typing проверяется актуальное членство |
| 8.9 | Ошибки бизнес-логики через WS | ✅ | Исправлено: HTTPException отправляется клиенту как `{"type":"error","code":N,"detail":"..."}` |

---

## 9. Поиск

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 9.1 | `GET /search/messages?q=` | ✅ | Полнотекстовый поиск через PostgreSQL `tsvector` |
| 9.2 | Фильтрация по чату (`chat_id`) | ✅ | Опционально |
| 9.3 | Поиск только в доступных чатах | ✅ | Проверяет членство |

---

## 10. Health & Инфраструктура

| # | Функционал | Статус | Комментарий |
|---|-----------|--------|-------------|
| 10.1 | `GET /health/live` | ✅ | Проверяет что процесс жив |
| 10.2 | `GET /health/ready` | ✅ | Проверяет PostgreSQL + Redis |
| 10.3 | `GET /health` | ✅ | |
| 10.4 | `X-Request-ID` в заголовках | ✅ | Middleware добавляет UUID |
| 10.5 | Структурированные ошибки JSON | ✅ | `{"error": {"code", "message", "request_id"}}` |
| 10.6 | `GET /metrics` (Prometheus) | ✅ | `prometheus-fastapi-instrumentator` подключён в `main.py`, опциональный импорт |
| 10.7 | CORS | ✅ | `CORSMiddleware` в `main.py`. `CORS_ORIGINS` из `.env` |
| 10.8 | Rate limiting | ✅ | `fastapi-limiter` 0.2.0 + `pyrate_limiter`. `/login` и `/register` — 10/min, `/refresh` — 60/min |

---

## 11. Баги и технический долг

| # | Проблема | Файл:строка | Приоритет |
|---|---------|-------------|-----------|
| ✅ 11.1 | Гонка при создании сессии: добавлен `with_for_update()` на запрос сессий | `services/auth.py` | Высокий |
| ✅ 11.2 | `device_id`: логин теперь читает `X-Device-ID` из заголовка (приоритет) с fallback на тело | `routes/auth.py` | Высокий |
| ✅ 11.3 | Заменён `datetime.utcnow()` на `datetime.now(timezone.utc)` везде | `services/auth.py`, `services/message.py`, `models/*.py` | Средний |
| ✅ 11.4 | Сортировка чатов: добавлен `.nulls_last()` и вторичный `desc(Chat.id)` | `services/chat.py` | Средний |
| ✅ 11.5 | При soft delete сообщения теперь явно удаляются строки из `message_statuses` | `services/message.py` | Средний |
| ✅ 11.6 | Добавлен `max_length=4096` для контента сообщений | `schemas/message.py` | Средний |
| ✅ 11.7 | Добавлены `min_length`/`max_length` для nickname (1–50) и password (8–128) | `schemas/user.py` | Средний |
| ⏭ 11.8 | Alembic-миграция использует `create_all()` — не меняем, уже применена в prod | `alembic/versions/001_baseline_schema.py` | Низкий |
| ⏭ 11.9 | E2E-тест не чистит данные — требует `DELETE /users/me`, это новая фича | `tests/e2e_api_runner.py` | Низкий |
| ✅ 11.10 | WS: проверка срока токена на каждый кадр; typing проверяет членство; ошибки отправляются клиенту | `routes/ws.py` | Низкий |

---

## 12. Полный Roadmap до уровня Telegram

> Голосовые сообщения и кружочки (video notes) — включены. Звонки (voice/video call) — вне скоупа.
> Статусы: ❌ Не начато | 🔄 В процессе | ✅ Готово | ⏭ Пропущено намеренно

---

### Фаза 1 — Production Readiness
> Без этого нельзя запустить вообще. ~3-5 дней.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P1.1 | **CORS middleware** | ✅ | `CORSMiddleware` в `main.py`. `CORS_ORIGINS` из `.env` (default `*`). `expose_headers: X-Request-ID` |
| P1.2 | **Rate limiting** | ✅ | `fastapi-limiter` 0.2.0 + `pyrate_limiter`. `/auth/login` и `/auth/register` — 10 req/min с IP; `/auth/refresh` — 60/min |
| P1.3 | **WS Heartbeat** | ✅ | `_recv_with_heartbeat()` в `ws.py`. Ping каждые 25s, ждёт pong 10s, иначе закрывает `1001` |
| P1.4 | **Graceful shutdown** | ✅ | `lifespan`: `ws_manager.shutdown()` → `engine.dispose()` → `close_redis()`. `utils/ws_manager.py` |
| P1.5 | **Структурированное логирование** | ✅ | `utils/logging_config.py`: JSON-форматтер без доп. зависимостей. `request_id`, `user_id`, `path` в каждой строке |

---

### Фаза 2 — Push-уведомления (APNs / FCM)
> Без этого сообщения не приходят когда приложение закрыто. ~1-2 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P2.1 | **Таблица `push_tokens`** | ✅ | `models/push_token.py` + миграция `002_push_and_mute.py` |
| P2.2 | **`POST /devices/push-token`** | ✅ | Upsert по `device_token`. `routes/devices.py` |
| P2.3 | **`DELETE /devices/push-token`** | ✅ | Удаляет токен текущего пользователя. `routes/devices.py` |
| P2.4 | **Интеграция APNs** | ✅ | `services/push_apns.py`. JWT из `.p8` ключа, кеш 50 мин. Требует `httpx[http2]` + настройки в `.env` |
| P2.5 | **Интеграция FCM** | ✅ | `services/push_fcm.py`. Legacy HTTP API, только `FCM_SERVER_KEY` в `.env` |
| P2.6 | **`services/push_dispatcher.py`** | ✅ | Проверяет онлайн/мут, выбирает платформу, fire-and-forget через `asyncio.create_task` |
| P2.7 | **Статус онлайн** | ✅ | Redis счётчик `ws:conn:{user_id}`. Инкремент при connect, декремент при disconnect. `utils/redis.py` |
| P2.8 | **Отправка пуша при новом сообщении** | ✅ | `services/message.py::create_message` запускает dispatcher после broadcast |
| P2.9 | **Тихий пуш (badge update)** | ✅ | Если получатель онлайн → `content-available: 1` без alert |
| P2.10 | **`GET /users/me/badge`** | ✅ | Считает непрочитанные MessageStatus. `routes/user.py` |
| P2.11 | **Мут чата** | ✅ | `models/chat_mute.py` + `POST/DELETE /chats/{id}/mute`. Поддерживает `muted_until` (null = навсегда) |
| P2.12 | **Обработка невалидных токенов** | ✅ | APNs 410/BadDeviceToken и FCM NotRegistered → `asyncio.create_task(_remove_invalid_token)` |

---

### Фаза 3 — Медиасистема
> Фундамент для аватаров, голосовых, кружочков, файлов. ~2-3 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P3.1 | **S3-хранилище** | ✅ | `services/s3.py` — aioboto3, upload_bytes / presigned_url / delete_object. Конфиг: `S3_BUCKET`, `S3_ENDPOINT`, `S3_KEY_ID`, `S3_SECRET`, `S3_REGION` |
| P3.2 | **Модель `Media`** | ✅ | `models/media.py` — UUID PK, type ENUM, mime_type, size_bytes, s3_key, thumbnail_s3_key, duration_sec, width, height, original_name |
| P3.3 | **`POST /media/upload`** | ✅ | `routes/media.py` — multipart, MIME whitelist, size limits (image 20MB / video 200MB / voice 25MB / video_note 50MB / doc 100MB / audio 50MB) |
| P3.4 | **Presigned URL для приватных файлов** | ✅ | `GET /media/{media_id}/url` — TTL 1h, проверка: uploader или член чата где есть это медиа |
| P3.5 | **Thumbnail-генератор** | ✅ | `services/thumbnail.py` — Pillow (images, run_in_executor), ffmpeg (video/video_note, gracefully skipped if missing) |
| P3.6 | **Поле `media_id` в Message** | ✅ | `models/message.py` + `schemas/message.py` — media_id UUID FK nullable, Pydantic validator: либо content либо media_id |
| P3.7 | **Голосовые сообщения** | ✅ | `type=voice`, audio/ogg, audio/m4a, audio/aac, max 25MB, `duration_sec` передаётся в Form |
| P3.8 | **Кружочки (Video Notes)** | ✅ | `type=video_note`, video/mp4 или quicktime, max 50MB, thumbnail через ffmpeg |
| P3.9 | **Документы и файлы** | ✅ | `type=document`, любой MIME, max 100MB, `original_name` сохраняется из `file.filename` |
| P3.10 | **Изображения** | ✅ | `type=image`, thumbnail 320px JPEG через Pillow, width/height из PIL |
| P3.11 | **Видео** | ✅ | `type=video`, thumbnail через ffmpeg, duration_sec, streaming через presigned URL |

---

### Фаза 4 — Профиль пользователя
> Зависит от Фазы 3 (аватар). ~1 неделя.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P4.1 | **Аватар** | ✅ | `avatar_media_id UUID FK NULLABLE` в `users`. `PATCH /users/me/avatar` проверяет владельца и тип (image). `UserOut` содержит `avatar_media_id` + `avatar_url` (presigned, генерируется inline) |
| P4.2 | **Bio / описание** | ✅ | `bio VARCHAR(200) NULLABLE` в `users`. `PATCH /users/me` принимает `{nickname, bio}` |
| P4.3 | **Статус "онлайн / последний визит"** | ✅ | Redis `ws:conn:{user_id}` (из Phase 1). `last_seen_at` обновляется при WS connect/disconnect. `GET /users/{id}/presence` → `{online, last_seen_at}`. Фильтрация по privacy |
| P4.4 | **Настройки приватности** | ✅ | `models/privacy_settings.py` — таблица с `Visibility ENUM[everyone/friends/nobody]`. `GET/PATCH /users/me/privacy`. Auto-create на первый запрос |
| P4.5 | **Уникальный @username** | ✅ | `username VARCHAR(32) UNIQUE` в `users`, паттерн `^[a-zA-Z0-9_]+$`. `PATCH /users/me/username`. Поиск по nickname и username (strip @) |
| P4.6 | **`GET /users/{id}`** | ✅ | Публичный профиль с privacy-фильтрацией (last_seen, avatar). `services/user_service.py::build_user_out()` |

---

### Фаза 5 — Завершение системы друзей
> Небольшая фаза. ~3-5 дней.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P5.1 | **`POST /friends/reject/{request_id}`** | ✅ | Только адресат. Статус → `rejected`. Повторная заявка работает (старая rejected-запись удаляется) |
| P5.2 | **`DELETE /friends/{user_id}`** | ✅ | Удаляет запись Friend в обоих направлениях. Чат и история остаются |
| P5.3 | **`GET /friends/requests/sent`** | ✅ | Исходящие pending-заявки. `/friends/requests/sent` стоит до `/friends/requests` |
| P5.4 | **Блокировка** | ✅ | `models/block.py`, `services/block_service.py`. `POST/DELETE /users/{id}/block`, `GET /users/me/blocked`. При блокировке удаляется дружба |
| P5.5 | **Проверка блокировки** | ✅ | `check_not_blocked()` встроен в `friends/add`, новый chat/DM. Поиск фильтрует обе стороны блока |
| P5.6 | **Открытые сообщения (без дружбы)** | ✅ | Убрана проверка дружбы из `create_chat` и `get_or_create_private_chat`. Настройка `messages_from` (everyone/friends/nobody) в `privacy_settings` контролирует кто может написать первым |

---

### Фаза 6 — Групповые чаты
> Большая фаза. ~2-3 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P6.1 | **Расширить модель Chat** | ✅ | Поля `type`, `avatar_media_id`, `description`, `max_members`, `invite_link` добавлены в `models/chat.py`. Миграция `006_group_chats` |
| P6.2 | **Роли участников** | ✅ | `MemberRole ENUM[owner/admin/member]` + `joined_at` в `models/chat_member.py`. Миграция `006_group_chats` |
| P6.3 | **`POST /chats/group`** | ✅ | `services/group_service.py::create_group_chat`. Создатель — owner. Системное сообщение. Минимум 2 участника |
| P6.4 | **`POST /chats/{id}/members`** | ✅ | `add_members()`. Проверяет роль admin+, max_members, пропускает существующих. Событие `member_added` |
| P6.5 | **`DELETE /chats/{id}/members/{user_id}`** | ✅ | `remove_member()`. Нельзя удалить owner. Admins не могут удалить друг друга. Событие `member_removed` |
| P6.6 | **`POST /chats/{id}/leave`** | ✅ | `leave_chat()`. Owner авто-передаёт права (oldest admin, затем oldest member). Событие `member_left` |
| P6.7 | **`PATCH /chats/{id}`** | ✅ | `update_group()`. Только admin+. title, description, avatar_media_id. Событие `chat_updated` |
| P6.8 | **`PATCH /chats/{id}/members/{user_id}/role`** | ✅ | `change_member_role()`. Только owner. При передаче owner — old owner → admin. Событие `role_changed` |
| P6.9 | **Инвайт-ссылки** | ✅ | `POST/DELETE /chats/{id}/invite-link`, `GET /chats/join/{slug}`. `secrets.token_urlsafe(24)`. Проверяет max_members |
| P6.10 | **Системные сообщения** | ✅ | `MessageType ENUM[text/system]` в `models/message.py`. Генерируются при create/add/remove/leave. user_id=None |
| P6.11 | **Sync-события для группы** | ✅ | `ChatUpdateEventType` расширен: `member_added`, `member_removed`, `member_left`, `chat_updated`, `role_changed` |
| P6.12 | **`GET /chats/{id}/members`** | ✅ | `get_members()`. Возвращает `[ChatMemberOut(user, role, joined_at)]`. Пагинация limit/offset |

---

### Фаза 7 — Расширенные возможности сообщений
> ~2 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P7.1 | **Реакции** | ✅ | `models/message_reaction.py`. `POST/DELETE /messages/{id}/reactions`. `reactions: dict[str,int]` в `MessageOut`. WS-событие `reaction_update`. `services/reaction_service.py` |
| P7.2 | **Пересылка сообщений** | ✅ | Поля `forwarded_from_message_id/user_id/chat_id` в `Message`. `MessageCreate.forward_message_id`. Копирует текст/медиа, сохраняет источник. Проверка доступа к оригинальному чату |
| P7.3 | **Закреплённые сообщения** | ✅ | `pinned_message_id FK NULLABLE` в `Chat`. `POST /chats/{id}/pin/{message_id}`, `DELETE /chats/{id}/pin`. WS-событие `message_pinned`. `pinned_message_id` в `ChatOut` |
| P7.4 | **Упоминания (@username)** | ✅ | `mention_user_ids JSONB` в `Message`. `_resolve_mentions()` парсит `@username` → user_id (только члены чата). Мьют игнорируется для упомянутых при push. `force_alert=True` в dispatcher |
| P7.5 | **Массовое прочтение** | ✅ | `POST /chats/{id}/read {up_to_message_id}`. `services/bulk_read_service.py` — batch UPDATE + INSERT. WS-событие `read_receipt` с `up_to_message_id` |
| P7.6 | **Сохранённые сообщения (Избранное)** | ✅ | `ChatType.saved`. `GET /chats/saved` — lazy-create через `get_or_create_saved_chat()`. Единственный участник — сам пользователь |
| P7.7 | **Черновики** | ✅ | `models/chat_draft.py`. `PUT/DELETE /chats/{id}/draft`. `draft_text` в `ChatOut` (заполняется через доп. запрос при необходимости). `services/chat.py::upsert_draft/delete_draft` |
| P7.8 | **Отложенная отправка** | ✅ | `send_at TIMESTAMP` в `Message`. При `send_at` указан — не broadcast/push. `GET /chats/{id}/messages/scheduled`. `DELETE /messages/{id}/scheduled`. ARQ-доставка — Phase 11 |

---

### Фаза 8 — Безопасность и аккаунт
> ~1-2 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P8.1 | **Верификация email** | ✅ | `models/email_verification.py`. 6-значный код, TTL 15 мин. `POST /auth/verify-email {code}`, `POST /auth/resend-verification`. `User.email_verified` в UserOut |
| P8.2 | **Двухфакторная аутентификация (TOTP)** | ✅ | `pyotp`. `POST /auth/2fa/setup` → `{secret, qr_url}`. `POST /auth/2fa/confirm`. При логине с 2FA → `{requires_2fa, temp_token}`. `POST /auth/2fa/verify {temp_token, totp_code}`. `DELETE /auth/2fa` |
| P8.3 | **Refresh token строгая ротация** | ✅ | В `refresh_tokens`: `session.refresh_token = None` + flush ПЕРЕД выдачей нового. Повторное использование старого → `_invalidate_session_on_token_reuse` — отзывает все сессии пользователя |
| P8.4 | **История входов** | ✅ | `models/login_event.py` (ip, user_agent, success, created_at). Записывается при каждом `login_user`. `GET /users/me/login-history?limit=20` |
| P8.5 | **`DELETE /users/me`** | ✅ | Soft delete: `users.deleted_at`, email → `deleted_{id}@deleted.local`, nickname → `Deleted_{id}`, очищает аватар, удаляет все сессии и push-токены. `deps.py` фильтрует удалённых пользователей |
| P8.6 | **`PATCH /users/me/password`** | ✅ | Проверяет текущий пароль, хеширует новый, отзывает все сессии кроме текущей |
| P8.7 | **Детектирование подозрительных входов** | ✅ | `_check_new_device()` — сравнивает IP с историей `login_events`. Новый IP + подтверждённый email → fire-and-forget `send_new_device_alert()` через SMTP |

---

### Фаза 9 — Расширенный поиск
> ~1 неделя.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P9.1 | **Поиск по дате** | ✅ | `GET /search/messages?date_from=&date_to=` — ISO 8601 datetime. Фильтры в `search_messages()` через `Message.created_at >= / <=` |
| P9.2 | **Глобальный поиск** | ✅ | `GET /search?q=` → `{users, messages, chats}`. `global_search()` в `message_search.py`. Пользователи: nickname/username (без блоков, без удалённых). Сообщения: full-text по доступным чатам. Чаты: по title |
| P9.3 | **Поиск пользователей без дружбы** | ✅ | `GET /users/search` открыт с Phase 5. В фиксе добавлен фильтр `deleted_at IS NULL`. Блоки фильтруются в обе стороны |
| P9.4 | **Jump to message** | ✅ | `GET /chats/{id}/messages?around_message_id={mid}&limit=N` → `half=N/2` сообщений до + pivot + после. `get_messages_around()` в `message_query.py`. Поле `is_pivot: bool` в каждом элементе |

---

### Фаза 10 — Каналы
> Только если нужны по продукту. ~2-3 недели.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P10.1 | **Тип `channel` в Chat** | ✅ | `ChatType.channel`. `MemberRole.subscriber` добавлен. `create_message` блокирует subscriber. `_ROLE_RANK` обновлён в group_service |
| P10.2 | **`POST /channels`** | ✅ | `services/channel_service.py::create_channel`. `routes/channel.py`. `ChannelCreate {title, description, is_public}`. Создатель — owner |
| P10.3 | **`POST /channels/{id}/subscribe`** | ✅ | `subscribe_channel()` — публичные каналы свободно, приватные — через `GET /channels/join/{slug}`. Роль subscriber |
| P10.4 | **`DELETE /channels/{id}/subscribe`** | ✅ | `unsubscribe_channel()` — owner не может отписаться. WS-событие `member_left` |
| P10.5 | **Счётчик подписчиков** | ✅ | `chats.subscribers_count` INT, инкремент/декремент в subscribe/unsubscribe. В `ChatOut` |
| P10.6 | **Поиск каналов** | ✅ | `GET /search/channels?q=` — только публичные каналы, сортировка по `subscribers_count DESC` |

---

### Фаза 11 — Надёжность и производительность
> Параллельно с другими фазами. Ongoing.

| # | Задача | Статус | Что делать |
|---|-------|--------|-----------|
| P11.1 | **ARQ (фоновые задачи)** | ✅ | `worker.py` — ARQ поверх Redis. Cron: deliver scheduled msgs каждые 60с, cleanup expired verifications каждые 24ч |
| P11.2 | **Redis кеширование профилей** | ✅ | `user:profile:{id}` TTL 5 мин в `build_user_out()`. Инвалидация при PATCH /me, /me/avatar, /me/username |
| P11.3 | **Cursor-based пагинация** | ✅ | `before_id`/`after_id` Query params в `GET /chats/{id}/messages`. Offset-fallback сохранён |
| P11.4 | **Индексы БД** | ✅ | `alembic/versions/010_indexes.py` — 7 индексов: messages, chat_members, blocks, login_events |
| P11.5 | **Connection pooling** | ✅ | `db.py`: `pool_size=20, max_overflow=40` |
| P11.6 | **Prometheus метрики** | ✅ | `prometheus-fastapi-instrumentator` уже подключён в `main.py` (опционально) |
| P11.7 | **Docker Compose** | ✅ | `Dockerfile` (multi-stage), `docker-compose.yml` (api + postgres + redis + arq-worker), `.env.example` |
| P11.8 | **CI/CD** | ✅ | `.github/workflows/ci.yml` — ruff lint, E2E тесты, deploy on main merge |
| P11.9 | **E2E тест cleanup** | ✅ | `tests/e2e_api_runner.py` — секция Cleanup: DELETE /users/me для user_a и user_b |
| P11.10 | **Alembic автогенерация** | ✅ | `alembic/env.py`: `compare_type=True, compare_server_default=True` |

---

## Итог и порядок реализации

```
Сейчас готово:  Авторизация, сессии, профили (@username, bio, avatar, privacy),
                друзья (add/accept/reject/remove), блокировка, чаты 1-на-1 (открытые),
                сообщения (текст + медиа, reply, edit, delete), sync_seq, WebSocket,
                push (APNs/FCM), медиасистема (фото/видео/голос/кружочки/документы),
                поиск по тексту и пользователям, health-эндпоинты. Баги исправлены.

Фаза 1  ██████████  Production Readiness    ✅ ГОТОВО
Фаза 2  ██████████  Push-уведомления        ✅ ГОТОВО
Фаза 3  ██████████  Медиасистема            ✅ ГОТОВО
Фаза 4  ██████████  Профиль пользователя   ✅ ГОТОВО
Фаза 5  ██████████  Система друзей          ✅ ГОТОВО
Фаза 6  ██████████  Групповые чаты          ✅ ГОТОВО
Фаза 7  ██████████  Богатые сообщения       ✅ ГОТОВО
Фаза 8  ██████████  Безопасность            ✅ ГОТОВО
Фаза 9  ██████████  Расширенный поиск       ✅ ГОТОВО
Фаза 10 ██████████  Каналы                  ✅ ГОТОВО
Фаза 11 ██████████  Надёжность/DevOps       ✅ ГОТОВО
```

**Архитектурные принципы:**
- Масштабирование через Redis pub/sub уже заложено — несколько инстансов API работают
- `sync_seq` — главный механизм надёжности: клиент при reconnect делает `GET /chats/{id}/sync?after_seq=N`
- WS и Push не конкурируют: WS = real-time (приложение открыто), Push = уведомление (закрыто)
- Все новые таблицы — только через Alembic миграции, никакого `create_all`
- E2EE (end-to-end шифрование) — сознательно не включено в план: теряется серверный поиск, история на новых устройствах, и это отдельный проект на 2-3 месяца
