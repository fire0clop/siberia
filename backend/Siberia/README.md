# Siberia Backend — Документация API

**Стек:** FastAPI · PostgreSQL (asyncpg) · Redis (pub/sub + кеш) · S3-совместимое хранилище · WebSocket

**Интерактивная документация (Swagger UI):** `http://<host>:<port>/docs`  
**OpenAPI JSON:** `http://<host>:<port>/openapi.json`  
**Базовый URL (локально):** `http://127.0.0.1:8000`

---

## Содержание

1. [Архитектура](#архитектура)
2. [Общие правила](#общие-правила)
3. [Модели данных](#модели-данных)
4. [Аутентификация — `/auth`](#аутентификация--auth)
5. [Пользователи — `/users`](#пользователи--users)
6. [Сессии — `/sessions`](#сессии--sessions)
7. [Друзья — `/friends`](#друзья--friends)
8. [Чаты — `/chats`](#чаты--chats)
9. [Сообщения — `/messages`](#сообщения--messages)
10. [Каналы — `/channels`](#каналы--channels)
11. [Медиа — `/media`](#медиа--media)
12. [Устройства / Push — `/devices`](#устройства--push--devices)
13. [Поиск — `/search`](#поиск--search)
14. [WebSocket — `/ws`](#websocket--ws)
15. [Real-time события](#real-time-события)
16. [Коды ошибок](#коды-ошибок)
17. [Запуск бэкенда](#запуск-бэкенда)

---

## Архитектура

```
Клиент (iOS/Android/Web)
        │  REST (JSON)            │  WebSocket (ws://)
        ▼                         ▼
   FastAPI (uvicorn)         /ws/me  /ws/{chat_id}
        │                         │
        ├── PostgreSQL (asyncpg)  ─┤
        ├── Redis pub/sub ─────────┘  (real-time sync между инстансами)
        ├── Redis cache             (профили пользователей, TTL 5 мин)
        ├── S3-совместимое хранилище (медиафайлы, presigned URL)
        └── ARQ worker             (отложенные сообщения, push-уведомления)
```

**Ключевые принципы:**

- **JWT**: `access_token` (Bearer) для API, `refresh_token` для обновления пары. Каждая сессия привязана к `device_id`.
- **Sync-seq**: каждый чат имеет монотонный счётчик `sync_seq`. При переподключении клиент запрашивает `GET /chats/{id}/sync?after_seq=N` и получает все пропущенные события.
- **Redis pub/sub**: при создании/редактировании/удалении сообщения событие публикуется в канале `chat:{id}` и `user:{user_id}` для всех участников — позволяет масштабировать на несколько инстансов API.
- **Presence**: статус онлайн — Redis-счётчик `ws:conn:{user_id}`. Инкрементируется при WS-подключении, декрементируется при разрыве.
- **Мягкое удаление**: пользователи не удаляются, а получают `deleted_at`; данные анонимизируются.

---

## Общие правила

| Аспект | Значение |
|--------|----------|
| Формат | JSON, UTF-8 |
| Заголовок тела | `Content-Type: application/json` |
| Авторизация | `Authorization: Bearer <access_token>` |
| Даты | ISO 8601, UTC (например `2026-04-05T12:00:00`) |
| Идентификатор запроса | Заголовок `X-Request-ID` — можно передавать свой, дублируется в ответе |

**Формат ошибки:**

```json
{
  "error": {
    "code": "http_403",
    "message": "Access denied",
    "request_id": "uuid"
  }
}
```

При `422` добавляется `error.fields` — массив ошибок валидации Pydantic.

**Rate limiting:** эндпоинты `/auth/register` и `/auth/login` — 10 запросов/минуту; `/auth/refresh` — 60 запросов/минуту.

---

## Модели данных

### `UserOut` — публичный профиль пользователя

```json
{
  "id": 1,
  "public_id": "550e8400-e29b-41d4-a716-446655440000",
  "username": "john_doe",
  "nickname": "John",
  "bio": "Привет, я использую Siberia!",
  "email": "user@example.com",
  "email_verified": true,
  "avatar_media_id": "uuid или null",
  "last_seen_at": "2026-04-05T10:00:00 или null",
  "created_at": "2026-01-01T00:00:00"
}
```

> `last_seen_at` виден только если настройки приватности получателя это разрешают.

### `AuthResponse` — ответ на логин/регистрацию

```json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "token_type": "bearer",
  "user": { "...UserOut..." },
  "requires_2fa": false,
  "temp_token": null
}
```

При включённой 2FA логин возвращает: `{ "requires_2fa": true, "temp_token": "..." }` — нужно пройти `/auth/2fa/verify`.

### `Token` — пара токенов

```json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "token_type": "bearer"
}
```

### `ChatOut` — чат

```json
{
  "id": 10,
  "type": "private",
  "title": null,
  "description": null,
  "avatar_media_id": null,
  "last_message_id": 42,
  "sync_seq": 15,
  "unread_count": 3,
  "pinned_message_id": null,
  "invite_slug": null,
  "is_public": false,
  "subscribers_count": 0,
  "draft_text": null,
  "created_at": "2026-04-01T00:00:00"
}
```

`type`: `"private"` | `"group"` | `"saved"` | `"channel"`

### `MessageOut` — сообщение

```json
{
  "id": 100,
  "chat_id": 10,
  "user_id": 2,
  "text": "Привет!",
  "media_id": null,
  "reply_to_message_id": null,
  "forward_message_id": null,
  "client_message_id": "uuid или null",
  "send_at": null,
  "edited_at": null,
  "deleted_at": null,
  "deleted": false,
  "reactions": [
    { "emoji": "👍", "user_id": 3 }
  ],
  "status": "read",
  "created_at": "2026-04-05T10:01:00"
}
```

`status`: `"sent"` | `"delivered"` | `"read"` | `null`  
Удалённые: `deleted: true`, `text: null`, `media_id: null`

### `ChatMemberOut`

```json
{
  "user": { "...UserOut..." },
  "role": "admin",
  "joined_at": "2026-04-01T10:00:00"
}
```

`role`: `"owner"` | `"admin"` | `"member"` | `"subscriber"`

### `SessionOut`

```json
{
  "id": 12,
  "device_id": "my-device-uuid",
  "user_agent": "MyApp/1.0 (iPhone)",
  "created_at": "2026-04-01T00:00:00",
  "last_active": "2026-04-05T09:00:00"
}
```

### `FriendRequestOut`

```json
{
  "request_id": 5,
  "user": { "...UserOut..." }
}
```

Поле `user` — тот, кто отправил заявку (вы — получатель).

### `LoginHistoryItem`

```json
{
  "id": 1,
  "ip_address": "1.2.3.4",
  "user_agent": "MyApp/1.0",
  "success": true,
  "created_at": "2026-04-05T10:00:00"
}
```

---

## Аутентификация — `/auth`

### `POST /auth/register`

Создать новый аккаунт.

**Заголовки:**

| Заголовок | Описание |
|-----------|----------|
| `X-Device-ID` | Стабильный ID устройства (UUID-строка). Сохраняется в сессии. |
| `User-Agent` | Опционально. |

**Тело:**

```json
{
  "email": "user@example.com",
  "nickname": "John",
  "password": "secret123"
}
```

**Ответ:** `200 AuthResponse`

**Ошибки:** `400` — Email/никнейм уже заняты · `422` — неверный email

---

### `POST /auth/login`

Войти в существующий аккаунт.

**Заголовки:** `X-Device-ID`, `User-Agent` (опционально)

**Тело:**

```json
{
  "email": "user@example.com",
  "password": "secret123",
  "device_id": "my-device-uuid"
}
```

**Ответ нормальный:** `200 AuthResponse` (с токенами и `user`)

**Ответ при 2FA:** `200 AuthResponse` с `requires_2fa: true` и `temp_token` (без обычных токенов — нужно пройти `/auth/2fa/verify`)

**Ошибки:** `401` — неверные данные

---

### `POST /auth/refresh`

Обновить пару токенов.

**Тело:**

```json
{
  "refresh_token": "eyJ...",
  "device_id": "тот же device_id, что у сессии"
}
```

> `device_id` должен **точно совпадать** с тем, что записано в сессии при создании. При несоответствии — `401 Invalid device`.

**Ответ:** `200 Token`

**Ошибки:** `401` — невалидный/истёкший refresh, неверное устройство, сессия не найдена

---

### `POST /auth/logout`

Завершить сессию (инвалидировать refresh-токен).

**Тело:**

```json
{
  "refresh_token": "eyJ..."
}
```

**Ответ:** `200 { "detail": "Logged out" }`

---

### `POST /auth/verify-email` 🔒

Подтвердить email кодом из письма.

**Тело:**

```json
{ "code": "123456" }
```

**Ответ:** `200 { "detail": "Email verified" }`

**Ошибки:** `400` — неверный/истёкший код

---

### `POST /auth/resend-verification` 🔒

Отправить новое письмо с кодом подтверждения.

**Ответ:** `200 { "detail": "Verification code sent" }`

**Ошибки:** `400` — email уже подтверждён

---

### `POST /auth/2fa/setup` 🔒

Начать настройку двухфакторной аутентификации (TOTP).

**Ответ:**

```json
{
  "secret": "BASE32SECRET",
  "otpauth_url": "otpauth://totp/Siberia:user@example.com?secret=...&issuer=Siberia"
}
```

Отображать `otpauth_url` как QR-код (Google Authenticator, Authy и т.д.).

---

### `POST /auth/2fa/confirm` 🔒

Подтвердить настройку 2FA (проверить первый TOTP-код).

**Тело:**

```json
{ "totp_code": "123456" }
```

**Ответ:** `200 { "detail": "2FA enabled" }`

**Ошибки:** `400` — неверный TOTP-код

---

### `POST /auth/2fa/verify`

Завершить вход с 2FA (после получения `temp_token` на этапе логина).

**Тело:**

```json
{
  "temp_token": "...",
  "totp_code": "123456"
}
```

**Заголовки:** `X-Device-ID`, `User-Agent`

**Ответ:** `200 AuthResponse` (с полными токенами)

**Ошибки:** `401` — неверный temp_token · `400` — неверный TOTP-код

---

### `DELETE /auth/2fa` 🔒

Отключить 2FA.

**Тело:**

```json
{ "totp_code": "123456" }
```

**Ответ:** `200 { "detail": "2FA disabled" }`

---

## Пользователи — `/users`

Все эндпоинты требуют 🔒 `Authorization: Bearer <access_token>`.

### `GET /users/me`

Получить свой профиль.

**Ответ:** `200 UserOut`

---

### `PATCH /users/me`

Обновить никнейм и/или bio.

**Тело:**

```json
{
  "nickname": "NewNick",
  "bio": "Мой новый статус"
}
```

Оба поля опциональны. `nickname` должен быть уникальным.

**Ответ:** `200 UserOut`

**Ошибки:** `409` — никнейм занят

---

### `PATCH /users/me/username`

Сменить юзернейм (логин).

**Тело:**

```json
{ "username": "new_username" }
```

**Ответ:** `200 UserOut`

**Ошибки:** `409` — юзернейм занят

---

### `PATCH /users/me/avatar`

Установить аватар (предварительно загрузить через `POST /media/upload`).

**Тело:**

```json
{ "media_id": "uuid загруженного изображения" }
```

**Ответ:** `200 UserOut`

**Ошибки:** `404` — медиа не найдено · `403` — медиа принадлежит другому пользователю · `400` — не изображение

---

### `PATCH /users/me/password`

Сменить пароль.

**Тело:**

```json
{
  "current_password": "old_secret",
  "new_password": "new_secret"
}
```

**Ответ:** `200 { "detail": "Password changed" }`

**Ошибки:** `400` — неверный текущий пароль

---

### `DELETE /users/me`

Удалить аккаунт (мягкое удаление: данные анонимизируются).

**Ответ:** `200 { "detail": "Account deleted" }`

---

### `GET /users/me/badge`

Количество непрочитанных сообщений во всех чатах.

**Ответ:**

```json
{ "unread": 5 }
```

---

### `GET /users/me/privacy`

Настройки приватности текущего пользователя.

**Ответ:**

```json
{
  "last_seen": "everyone",
  "avatar": "everyone",
  "messages_from": "everyone"
}
```

Возможные значения: `"everyone"` | `"friends"` | `"nobody"`

---

### `PATCH /users/me/privacy`

Изменить настройки приватности.

**Тело:** (все поля опциональны)

```json
{
  "last_seen": "friends",
  "avatar": "everyone",
  "messages_from": "friends"
}
```

**Ответ:** обновлённый объект настроек

---

### `GET /users/me/login-history`

История входов в аккаунт.

**Query:** `limit` (1–100, по умолчанию 20)

**Ответ:** `200 LoginHistoryItem[]`

---

### `GET /users/me/blocked`

Список заблокированных пользователей.

**Ответ:** `200 UserOut[]`

---

### `POST /users/{user_id}/block`

Заблокировать пользователя.

**Ответ:** `200 { "detail": "User blocked" }`

---

### `DELETE /users/{user_id}/block`

Разблокировать пользователя.

**Ответ:** `200 { "detail": "User unblocked" }`

---

### `GET /users/search?q=<строка>`

Поиск пользователей по никнейму или юзернейму.

**Query:** `q` — минимум 1 символ

**Ответ:** `200 UserOut[]`

---

### `GET /users/{user_id}`

Получить профиль другого пользователя.

**Ответ:** `200 UserOut`

**Ошибки:** `404` — пользователь не найден

---

### `GET /users/{user_id}/presence`

Статус онлайн и время последнего визита.

**Ответ:**

```json
{
  "user_id": 5,
  "online": true,
  "last_seen_at": "2026-04-05T10:00:00 или null"
}
```

`last_seen_at` возвращается `null` если настройки приватности получателя запрещают.

---

## Сессии — `/sessions`

Все эндпоинты требуют 🔒.

### `GET /sessions`

Список всех активных сессий.

**Ответ:** `200 SessionOut[]`

---

### `DELETE /sessions/{session_id}`

Завершить конкретную сессию (выйти на другом устройстве).

**Ответ:** `200 { "detail": "Session removed" }`

**Ошибки:** `404` — сессия не найдена или принадлежит другому пользователю

---

### `POST /sessions/revoke_all`

Завершить все сессии кроме текущей.

**Ответ:** `200 { "detail": "All sessions revoked" }`

---

## Друзья — `/friends`

Все эндпоинты требуют 🔒.

### `POST /friends/add/{user_id}`

Отправить заявку в друзья.

**Ответ:** `200` — объект заявки

**Ошибки:** `400` — нельзя добавить себя / заявка уже существует

---

### `GET /friends/requests`

Входящие заявки (вы — получатель).

**Ответ:** `200 FriendRequestOut[]`

---

### `GET /friends/requests/sent`

Исходящие заявки (вы — отправитель).

**Ответ:** `200 FriendRequestOut[]` (поле `user` — получатель заявки)

---

### `POST /friends/accept/{request_id}`

Принять заявку. `request_id` берётся из `GET /friends/requests`.

**Ответ:** `200` — обновлённая заявка

**Ошибки:** `404` — заявка не найдена или не ваша · `400` — заявка уже не в статусе pending

---

### `POST /friends/reject/{request_id}`

Отклонить заявку.

**Ответ:** `200`

**Ошибки:** `404` — заявка не найдена · `400` — заявка не pending

---

### `DELETE /friends/{user_id}`

Удалить из друзей.

**Ответ:** `200`

---

### `GET /friends`

Список принятых друзей.

**Ответ:** `200 UserOut[]`

---

## Чаты — `/chats`

Все эндпоинты требуют 🔒.

### `POST /chats`

Создать приватный чат с другим пользователем (нужно быть друзьями).  
Если чат уже существует — возвращается существующий.

**Тело:**

```json
{ "user_id": 5 }
```

**Ответ:** `200 ChatOut`

**Ошибки:** `404` — пользователь не найден · `403` — не друзья

---

### `GET /chats`

Список чатов текущего пользователя (включая черновики сообщений).

**Ответ:** `200 ChatOut[]` (сортировка по `last_message_id` убывающая)

---

### `POST /chats/group`

Создать групповой чат.

**Тело:**

```json
{
  "title": "Название группы",
  "description": "Опционально",
  "user_ids": [2, 3, 4]
}
```

**Ответ:** `200 ChatOut`

---

### `GET /chats/saved`

Получить (или создать) чат «Избранное» (Saved Messages) для текущего пользователя.

**Ответ:** `200 ChatOut`

---

### `GET /chats/join/{slug}`

Вступить в группу по ссылке-приглашению (`slug` из `invite_link`).

**Ответ:** `200 ChatOut`

**Ошибки:** `404` — ссылка не найдена

---

### `GET /chats/{chat_id}`

Получить информацию о чате.

**Ответ:** `200 ChatOut`

**Ошибки:** `403` — нет доступа · `404` — не найден

---

### `PATCH /chats/{chat_id}`

Обновить группу (только admin/owner).

**Тело:** (все поля опциональны)

```json
{
  "title": "Новое название",
  "description": "Описание",
  "avatar_media_id": "uuid"
}
```

**Ответ:** `200 ChatOut`

---

### `GET /chats/{chat_id}/messages`

История сообщений (только участник чата).

**Query:**

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `limit` | 50 | 1–200 |
| `offset` | 0 | Смещение (используй `before_id`/`after_id` для курсорной пагинации) |
| `before_id` | — | Сообщения строго до этого ID (новые → старые) |
| `after_id` | — | Сообщения строго после этого ID (старые → новые) |
| `around_message_id` | — | Контекст вокруг сообщения (по `limit/2` в каждую сторону) |

**Ответ:** `200 MessageOut[]`

---

### `POST /chats/{chat_id}/messages`

Отправить сообщение в чат.

**Тело:**

```json
{
  "content": "Текст сообщения",
  "client_message_id": "uuid (опционально, для идемпотентности)",
  "reply_to_message_id": 99,
  "media_id": "uuid медиафайла (опционально)",
  "forward_message_id": 50,
  "send_at": "2026-04-10T12:00:00 (опционально, ISO UTC)"
}
```

`client_message_id` — UUID; повтор запроса с тем же значением вернёт то же сообщение и `idempotent: true`.  
`send_at` — запланировать отправку на будущее время.

**Ответ:**

```json
{
  "message": { "...MessageOut..." },
  "idempotent": false
}
```

**Ошибки:** `403` — не участник · `409` — конфликт идемпотентности

---

### `GET /chats/{chat_id}/messages/scheduled`

Список запланированных сообщений (только своих, только будущих).

**Ответ:** `200` — массив объектов сообщений с `send_at`

---

### `POST /chats/{chat_id}/read`

Отметить сообщения прочитанными (оптом, до указанного ID включительно).

**Тело:**

```json
{ "up_to_message_id": 100 }
```

**Ответ:** `200 { "detail": "Messages marked as read" }`

---

### `GET /chats/{chat_id}/sync`

Догоняющая синхронизация по `seq`.

**Query:**

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `after_seq` | 0 | Вернуть события с seq > N |
| `limit` | 100 | 1–500 |

**Ответ:**

```json
{
  "updates": [
    {
      "seq": 16,
      "event": "message_new",
      "message_id": 101,
      "payload": { "...зависит от event..." },
      "created_at": "2026-04-05T10:01:00"
    }
  ],
  "latest_seq": 16
}
```

Типы событий `event`: `message_new` · `message_edit` · `message_delete` · `read_receipt` · `member_added` · `member_removed` · `member_left` · `chat_updated` · `role_changed` · `reaction_update` · `message_pinned`

---

### `POST /chats/{chat_id}/mute`

Замьютить чат.

**Тело:**

```json
{ "muted_until": "2026-04-10T00:00:00 или null (навсегда)" }
```

**Ответ:** `200 { "detail": "Chat muted" }`

---

### `DELETE /chats/{chat_id}/mute`

Снять мут.

**Ответ:** `200 { "detail": "Chat unmuted" }`

---

### `GET /chats/{chat_id}/members`

Список участников.

**Query:** `limit` (1–500, по умолчанию 100), `offset`

**Ответ:** `200 ChatMemberOut[]`

---

### `POST /chats/{chat_id}/members`

Добавить участников в группу (admin/owner).

**Тело:**

```json
{ "user_ids": [5, 6, 7] }
```

**Ответ:** `200 { "detail": "Members added" }`

---

### `DELETE /chats/{chat_id}/members/{user_id}`

Исключить участника (admin/owner).

**Ответ:** `200 { "detail": "Member removed" }`

---

### `POST /chats/{chat_id}/leave`

Покинуть чат.

**Ответ:** `200 { "detail": "Left the chat" }`

---

### `PATCH /chats/{chat_id}/members/{user_id}/role`

Изменить роль участника (только owner).

**Тело:**

```json
{ "role": "admin" }
```

Допустимые значения: `"admin"` | `"member"`

**Ответ:** `200 { "detail": "Role updated" }`

---

### `POST /chats/{chat_id}/invite-link`

Создать ссылку-приглашение (admin/owner).

**Ответ:**

```json
{ "invite_link": "abc123xyz" }
```

---

### `DELETE /chats/{chat_id}/invite-link`

Отозвать ссылку-приглашение.

**Ответ:** `200 { "detail": "Invite link revoked" }`

---

### `POST /chats/{chat_id}/pin/{message_id}`

Закрепить сообщение (admin/owner).

**Ответ:** `200 { "detail": "Message pinned" }`

---

### `DELETE /chats/{chat_id}/pin`

Открепить сообщение.

**Ответ:** `200 { "detail": "Pin removed" }`

---

### `PUT /chats/{chat_id}/draft`

Сохранить черновик сообщения.

**Тело:**

```json
{ "text": "Черновик..." }
```

**Ответ:** `200 { "detail": "Draft saved" }`

---

### `DELETE /chats/{chat_id}/draft`

Удалить черновик.

**Ответ:** `200 { "detail": "Draft deleted" }`

---

## Сообщения — `/messages`

Все эндпоинты требуют 🔒.

### `POST /messages`

Отправить сообщение напрямую пользователю (авто-создание/поиск существующего приватного чата).

**Тело:**

```json
{
  "user_id": 5,
  "content": "Привет!",
  "client_message_id": "uuid (опционально)",
  "reply_to_message_id": null
}
```

**Ответ:**

```json
{
  "chat_id": 10,
  "message": { "...MessageOut..." },
  "idempotent": false
}
```

---

### `PATCH /messages/{message_id}`

Редактировать своё сообщение.

**Тело:**

```json
{ "content": "Исправленный текст" }
```

**Ответ:** `200 MessageOut`

**Ошибки:** `403` — не ваше сообщение · `404` — не найдено

---

### `DELETE /messages/{message_id}`

Мягкое удаление своего сообщения.

**Ответ:** `200 { "detail": "Message deleted" }`

---

### `POST /messages/{message_id}/reactions`

Поставить реакцию на сообщение.

**Тело:**

```json
{ "emoji": "👍" }
```

**Ответ:**

```json
{
  "reactions": [
    { "emoji": "👍", "user_id": 1 },
    { "emoji": "❤️", "user_id": 2 }
  ]
}
```

---

### `DELETE /messages/{message_id}/reactions`

Убрать свою реакцию с сообщения.

**Ответ:** `200 { "reactions": [...] }`

---

### `DELETE /messages/{message_id}/scheduled`

Отменить запланированное сообщение (пока не отправлено).

**Ответ:** `200 { "detail": "Scheduled message cancelled" }`

**Ошибки:** `404` — не найдено · `403` — не ваше · `400` — уже отправлено

---

## Каналы — `/channels`

Все эндпоинты требуют 🔒.

### `POST /channels`

Создать канал.

**Тело:**

```json
{
  "title": "Мой канал",
  "description": "Описание",
  "is_public": true
}
```

**Ответ:** `200 ChatOut`

---

### `GET /channels/{channel_id}`

Получить информацию о канале.

**Ответ:** `200 ChatOut`

---

### `PATCH /channels/{channel_id}`

Обновить канал (только owner/admin).

**Тело:** (все поля опциональны)

```json
{
  "title": "Новое название",
  "description": "Описание",
  "is_public": false,
  "avatar_media_id": "uuid"
}
```

**Ответ:** `200 ChatOut`

---

### `POST /channels/{channel_id}/subscribe`

Подписаться на канал.

**Ответ:** `200 ChatOut`

---

### `DELETE /channels/{channel_id}/subscribe`

Отписаться от канала.

**Ответ:** `200 { "detail": "Unsubscribed" }`

---

### `GET /channels/join/{slug}`

Подписаться на канал по ссылке-приглашению.

**Ответ:** `200 ChatOut`

---

## Медиа — `/media`

Все эндпоинты требуют 🔒.

### `POST /media/upload`

Загрузить файл (multipart/form-data).

**Форма:**

| Поле | Тип | Описание |
|------|-----|----------|
| `file` | файл | Медиафайл |
| `type` | строка | `"image"` \| `"video"` \| `"audio"` \| `"document"` |
| `duration_sec` | int | Опционально, для аудио/видео |

**Ответ:**

```json
{
  "id": "uuid",
  "type": "image",
  "mime_type": "image/jpeg",
  "size_bytes": 204800,
  "duration_sec": null,
  "width": 1920,
  "height": 1080,
  "original_name": "photo.jpg"
}
```

После загрузки `id` передаётся в `media_id` при отправке сообщения или в `PATCH /users/me/avatar`.

---

### `GET /media/{media_id}/url`

Получить временный presigned URL для скачивания.

**Ответ:**

```json
{
  "url": "https://...",
  "expires_in": 3600
}
```

---

## Устройства / Push — `/devices`

Все эндпоинты требуют 🔒.

### `POST /devices/push-token`

Зарегистрировать push-токен устройства. Вызывать при каждом запуске приложения.

**Тело:**

```json
{
  "device_token": "APNs или FCM токен",
  "platform": "ios"
}
```

`platform`: `"ios"` | `"android"`

**Ответ:** `200 { "detail": "Push token registered" }`

---

### `DELETE /devices/push-token`

Удалить push-токен (вызывать при logout или отключении уведомлений).

**Тело:** то же что при регистрации

**Ответ:** `200 { "detail": "Push token removed" }`

---

## Поиск — `/search`

Все эндпоинты требуют 🔒.

### `GET /search/messages`

Поиск по тексту сообщений в доступных чатах.

**Query:**

| Параметр | Обязательный | Описание |
|----------|--------------|----------|
| `q` | да | Минимум 1 символ |
| `chat_id` | нет | Ограничить поиск одним чатом |
| `date_from` | нет | ISO datetime — начало периода |
| `date_to` | нет | ISO datetime — конец периода |
| `limit` | нет | 1–100, по умолчанию 30 |

**Ответ:**

```json
{
  "results": [
    {
      "id": 100,
      "chat_id": 10,
      "user_id": 2,
      "text": "Привет, это тест",
      "created_at": "2026-04-05T10:00:00",
      "edited_at": null
    }
  ]
}
```

---

### `GET /search`

Глобальный поиск (пользователи + каналы + сообщения).

**Query:** `q` (обязательно), `limit` (1–50, по умолчанию 20)

**Ответ:** комбинированный объект с секциями `users`, `channels`, `messages`

---

### `GET /search/channels`

Поиск публичных каналов по названию.

**Query:** `q` (обязательно), `limit` (1–100, по умолчанию 20)

**Ответ:**

```json
[
  {
    "id": 15,
    "title": "Siberia News",
    "description": "Новости",
    "avatar_media_id": null,
    "subscribers_count": 1024,
    "is_public": true
  }
]
```

---

## Health — `/health`

Не требует авторизации.

| Эндпоинт | Описание |
|----------|----------|
| `GET /health` | Общий статус |
| `GET /health/live` | Процесс жив (200) |
| `GET /health/ready` | PostgreSQL + Redis доступны (200) или нет (503) |

**Метрики Prometheus:** `GET /metrics`

---

## WebSocket — `/ws`

### Персональный канал `/ws/me`

**URL:** `ws://<host>/ws/me?token=<access_token>`

Принимает все события из всех чатов пользователя (для обновления списка чатов, бейджей). Только для чтения — исходящие сообщения игнорируются.

При истечении токена или удалении пользователя — закрытие `1008`.

---

### Комната чата `/ws/{chat_id}`

**URL:** `ws://<host>/ws/{chat_id}?token=<access_token>`

Если токен невалиден или пользователь не участник — закрытие `1008`.

**Heartbeat:** сервер шлёт `{"type": "ping"}` каждые 25 секунд. Клиент должен ответить `{"type": "pong"}`. Нет ответа в течение 10 секунд — соединение закрывается с кодом `1001`.

#### Входящие события (от клиента к серверу)

**Отправить сообщение:**

```json
{
  "type": "message",
  "text": "Привет!",
  "client_message_id": "uuid (опционально)",
  "reply_to_message_id": 99
}
```

**Индикатор набора текста:**

```json
{ "type": "typing" }
```

**Отметить прочитанным:**

```json
{ "type": "read", "message_id": 100 }
```

**Ответ pong:**

```json
{ "type": "pong" }
```

#### Исходящие события (от сервера к клиенту)

Все события приходят в едином v1-конверте:

```json
{
  "v": 1,
  "chat_id": 10,
  "seq": 42,
  "event": "message_new",
  "message_id": 101,
  "payload": { "...зависит от event..." }
}
```

**Ping от сервера:**

```json
{ "type": "ping" }
```

**Ошибка бизнес-логики:**

```json
{ "type": "error", "code": 403, "detail": "Not a member" }
```

---

## Real-time события

| `event` | Когда публикуется | Поля `payload` |
|---------|-------------------|----------------|
| `message_new` | Новое сообщение | `user_id`, `text`, `media_id`, `client_message_id`, `reply_to_message_id`, `created_at` |
| `message_edit` | Редактирование | `text`, `edited_at` |
| `message_delete` | Мягкое удаление | _(пусто)_ |
| `read_receipt` | Прочтение | `reader_id`, `up_to_message_id` |
| `typing` | Индикатор набора | `user_id` _(без seq, не пишется в sync_log)_ |
| `member_added` | Добавлен участник | `user_ids: [...]` |
| `member_removed` | Исключён участник | `user_id` |
| `member_left` | Участник покинул чат | `user_id` |
| `chat_updated` | Изменено название/описание | `title`, `description` |
| `role_changed` | Смена роли | `user_id`, `role` |
| `reaction_update` | Изменение реакций | `reactions: [{"emoji", "user_id"}]` |
| `message_pinned` | Закреплено/откреплено сообщение | `message_id` или `null` |

Все события кроме `typing` записываются в `chat_update_log` с монотонным `seq` и доступны через `GET /chats/{id}/sync`.

---

## Коды ошибок

| HTTP | Когда |
|------|-------|
| `400` | Нарушение бизнес-правила (подробности в `message`) |
| `401` | Нет/неверный Bearer, refresh истёк/неверный, неверное устройство |
| `403` | Нет прав (не участник, не admin и т.д.) |
| `404` | Сущность не найдена |
| `409` | Конфликт (никнейм занят, гонка идемпотентности) |
| `422` | Ошибка валидации Pydantic (поле `error.fields`) |
| `429` | Rate limit превышен |
| `500` | Необработанное исключение |
| `503` | PostgreSQL или Redis недоступны (`/health/ready`) |

---

## Запуск бэкенда

### Вариант 1 — Docker Compose (рекомендуется)

```bash
# 1. Скопировать конфигурацию
cp .env.example .env
# 2. Заполнить .env (минимум DATABASE_URL, SECRET_KEY, ALGORITHM)

# 3. Запустить все сервисы
docker compose up -d

# Сервис API будет доступен на http://localhost:8000
# Миграции применяются автоматически при старте контейнера api
```

Сервисы в `docker-compose.yml`:
- `postgres` — PostgreSQL 16
- `redis` — Redis 7
- `api` — FastAPI (uvicorn), порт 8000
- `arq-worker` — ARQ воркер для отложенных задач

---

### Вариант 2 — Локальный запуск

**Требования:** Python 3.12+, PostgreSQL, Redis

```bash
# 1. Создать виртуальное окружение
python -m venv .venv
source .venv/bin/activate          # Linux/macOS
# .venv\Scripts\activate           # Windows

# 2. Установить зависимости
pip install -r requirements.txt

# 3. Настроить окружение
cp .env.example .env
# Отредактировать .env

# 4. Применить миграции БД
alembic upgrade head

# 5. Запустить API
uvicorn main:app --reload --host 0.0.0.0 --port 8000

# 6. (Опционально) Запустить ARQ воркер в отдельном терминале
arq worker.WorkerSettings
```

---

### Переменные окружения

| Переменная | Обязательная | По умолчанию | Описание |
|------------|:---:|---------|----------|
| `DATABASE_URL` | ✅ | — | `postgresql+asyncpg://user:pass@host:5432/db` |
| `SECRET_KEY` | ✅ | — | Секрет для подписи JWT (длинная случайная строка) |
| `ALGORITHM` | ✅ | — | Алгоритм JWT (обычно `HS256`) |
| `ACCESS_TOKEN_EXPIRE_DAYS` | ✅ | — | Срок жизни access-токена в днях |
| `REFRESH_TOKEN_EXPIRE_DAYS` | ✅ | — | Срок жизни refresh-токена в днях |
| `REDIS_URL` | — | `redis://localhost:6379/0` | URL Redis |
| `DEBUG` | — | `false` | `true` — подробные SQL-логи |
| `CORS_ORIGINS` | — | `*` | Origins через запятую: `https://app.example.com` |
| `APNS_KEY_PATH` | — | — | Путь к .p8 файлу (iOS push) |
| `APNS_KEY_ID` | — | — | 10-символьный Key ID (Apple Developer) |
| `APNS_TEAM_ID` | — | — | 10-символьный Team ID |
| `APNS_BUNDLE_ID` | — | — | Bundle ID приложения |
| `APNS_SANDBOX` | — | `true` | `true` = sandbox (TestFlight), `false` = production |
| `FCM_SERVER_KEY` | — | — | Legacy Server Key (Firebase) |
| `S3_BUCKET` | — | — | Имя бакета |
| `S3_ENDPOINT` | — | — | `""` = AWS, `https://<id>.r2.cloudflarestorage.com` = R2 |
| `S3_KEY_ID` | — | — | Access Key ID |
| `S3_SECRET` | — | — | Secret Access Key |
| `S3_REGION` | — | `auto` | Регион (для R2 — `auto`) |
| `SMTP_HOST` | — | `localhost` | SMTP-сервер |
| `SMTP_PORT` | — | `587` | Порт SMTP |
| `SMTP_USER` | — | — | Логин SMTP |
| `SMTP_PASSWORD` | — | — | Пароль SMTP |
| `SMTP_FROM` | — | `noreply@siberia.app` | Адрес отправителя |
| `SMTP_TLS` | — | `true` | Использовать STARTTLS |

---

### Полезные команды

```bash
# Создать новую миграцию (после изменения моделей)
alembic revision --autogenerate -m "описание изменений"

# Применить миграции
alembic upgrade head

# Откатить последнюю миграцию
alembic downgrade -1

# Запустить E2E тесты (нужен запущенный сервер)
python tests/e2e_api_runner.py
# BASE_URL=http://localhost:8000 python tests/e2e_api_runner.py

# Линтинг (ruff)
ruff check .
ruff format .
```

### Swagger UI

После запуска: **`http://localhost:8000/docs`**

ReDoc: `http://localhost:8000/redoc`

OpenAPI JSON: `http://localhost:8000/openapi.json`
