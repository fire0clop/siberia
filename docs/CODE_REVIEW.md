# Siberia — глобальное ревью кода (2026-09-06)

> **Статус на 2026-09-08: закрыто.** Все пункты Critical/High и Medium этого
> отчёта исправлены, рекомендованный порядок §6 пройден полностью; сверх того
> реализованы 5 из 6 фич Sprint 4 (стикеры/GIF отложены). Покрытие: 76
> бэкенд-тестов + 27 iOS-тестов, обе платформы в CI. Документ сохранён как
> исторический артефакт; актуальное состояние — README.md и git log.

Срез по `main` @ `7c04226`. Проверено: бэкенд целиком (~9.9k строк Python), iOS целиком (~14.7k строк Swift), миграции, CI, docker, документация. Сборка iOS (`xcodebuild`, Xcode 26.0.1, симулятор) — зелёная. CI на GitHub — последние 3 прогона зелёные (ruff + e2e 48 проверок).

Легенда: **C** критично · **H** высокий · **M** средний · **L** низкий. Все пункты C/H проверены по коду вручную, остальные — по отчётам покомпонентного ревью с выборочной проверкой. «Вероятно» — поведение зависит от тайминга/внешней системы.

---

## 1. Общая картина

**Что сделано и работает как заявлено**

- Auth: bcrypt, JWT access/refresh, ротация refresh с детектом повторного использования, привязка к `device_id`, blacklist сессий в Redis (HTTP и WS). Email-верификация с lockout, TOTP.
- `sync_seq` per chat: `FOR UPDATE` + unique `(chat_id, seq)`, `GET /chats/{id}/sync`. Атомарный захват scheduled-сообщений воркером через `UPDATE … RETURNING`.
- Pub/sub fan-out через Redis действительно работает на несколько инстансов API (ws_manager — только локальный реестр для shutdown).
- ARQ-воркер есть в docker-compose, Redis-настройки совпадают с API.
- WS-auth: header в приоритете, `?token=` отключён в production.
- iOS: ICE-кандидаты корректно буферизуются до `setRemoteDescription`, `RefreshGate` дедуплицирует параллельные 401, Keychain с `AfterFirstUnlock`, сигналинг буферизует кадры до `attach`.
- Миграции: после 014/017 tz-naive колонок больше нет; enum-типы в 002–004 создаются (хоть и «случайно», см. §6).
- Секреты (`.env`, `.p8`) в git не попали.

**Чего нет совсем (по коду, не по докам)**

- Юнит-тестов бэкенда — ноль. E2E-скрипт покрывает auth/DM/sync/edit/delete/search, но не покрывает группы, каналы, медиа, реакции, pin, drafts, scheduled, mute, блокировки, privacy, звонки, forward, 2FA, push. Ни один из критичных пунктов ниже e2e не поймал бы.
- Тестового таргета iOS нет; `SiberiaTests/ChatCacheServiceTests.swift` не подключён и **не скомпилируется** (использует поля, которых нет в `ChatSummary`, пропускает обязательный `createdAt`).
- TURN не подключён (только Google STUN) — звонки за NAT не соединятся.
- Push на друзей/группы/роли не отправляются; VoIP push есть, но см. C-3.
- Локализация, iPad, accessibility — по плану, не начато.

---

## 2. Бэкенд — баги и дыры

### Critical

| # | Где | Что |
|---|-----|-----|
| C-1 | `routes/auth.py:36-42` | **Rate limit глобальный, а не per-IP.** `Limiter(InMemoryBucket(...))` заворачивается в `SingleBucketFactory`, чей `get()` игнорирует ключ (проверено по исходникам pyrate-limiter 4.1.0). Все клиенты делят 10 req/min на register+login и 60 req/min на refresh. Один аноним 10 запросами в минуту блокирует логин всем; refresh упрётся в 429 при десятках активных юзеров. README обещает per-endpoint лимиты. |
| C-2 | `services/auth.py:364, 284, 343` | **Начатый и брошенный `/2fa/setup` блокирует логин навсегда.** `setup_totp` пишет `"pending:<secret>"` (даже поверх активного секрета), `login_user` считает любой truthy `totp_secret` включённой 2FA, `complete_2fa_login` делает `pyotp.TOTP("pending:...")` → base32-ошибка → 500 на любой код. `disable_totp` отказывается от pending. Выход только через `/2fa/confirm` с живым access-токеном. Украденный access-токен = lockout жертвы. |
| C-3 | `services/message.py:143-152` | **Блокировка не действует в уже существующем DM.** `check_not_blocked` вызывается только при создании нового приватного чата (`services/chat.py:94`, `message.py:65`). Заблокированный продолжает писать по HTTP и WS. |
| C-4 | `schemas/user.py:36`, `services/user_service.py:115` | **Email каждого пользователя виден всем авторизованным.** `UserOut.email` обязателен и всегда заполняется: `/users/{id}`, `/users/search`, `/chats/{id}/members`, `/friends`, `/calls/history`, WS `call_incoming`. Перебор по `/users/{int}` тривиален. |

### High

| # | Где | Что |
|---|-----|-----|
| H-1 | `routes/auth.py:127-159` | Нет rate limit на `/2fa/verify`, `/2fa/confirm`, `DELETE /2fa`. 6 цифр, `valid_window=1` → брутфорс за 5-минутное окно pre-auth токена; 2FA можно снести брутфорсом с украденным access-токеном. |
| H-2 | `routes/ws.py:145-147` vs `:206` | **Idle-пользователи уходят в offline через 90 с.** `pong` съедается внутри `_recv_with_heartbeat` и не доходит до `presence_refresh`; ключ `ws:conn:{uid}` (TTL 90 с) протухает. Следствия: `is_online=false` → полноценные alert-пуши онлайн-юзерам; `presence_disconnect` уводит счётчик в −1 и шлёт offline при живых соединениях. |
| H-3 | `services/auth.py:412-437` | Refresh без row-lock: два параллельных refresh с одним токеном оба проходят проверку, проигравший на следующем refresh триггерит reuse-детект → **удаляются все сессии пользователя**. iOS-клиент это провоцирует (см. iOS H-6). |
| H-4 | `services/auth.py:284-315` | При включённой 2FA сессия создаётся, старое устройство вытесняется, `LoginEvent(success=True)` и «новое устройство» отправляются **до** проверки TOTP. Знающий пароль может выкинуть жертву с устройства и «обелить» свой IP. |
| H-5 | `services/sync_engine.py:17-21` | **Stale `sync_seq` под `FOR UPDATE`.** Если `Chat` уже загружен в сессию раньше (например `get_private_chat_between` в `message.py:308→178`), identity map вернёт старый объект без refresh атрибутов. Под конкурентной отправкой → `stale+1` → unique violation → 500. Аналогично в `group_service.py:110/142, 189/213, 301/327`, `channel_service.py:67/85, 122/136`. Лечится `populate_existing()`. |
| H-6 | `services/message.py:236`, `worker.py:64-82` | Scheduled-сообщения сразу создают `MessageStatus` (непрочитанные в badge до отправки), а при доставке `created_at`/`id` от момента планирования → сообщение сортируется в глубину истории. Envelope `message_new` из воркера имеет `payload={}` — iOS его не показывает (guard падает). |
| H-7 | `services/call_service.py:88-98` | Звонок в `ringing` никем не таймаутится → один зависший звонок (упавшее приложение звонящего) **навсегда блокирует звонки обоим** (409). `initiate_call` без лока — два параллельных проходят. |
| H-8 | `services/media_service.py:188-202, 121-122` | Аватар группы недоступен участникам (авторизация только через `Message.media_id`); `avatar_media_id` в PATCH не валидируется → FK IntegrityError → 500. Upload читает весь файл в память до проверки размера (до 500 МБ на запрос) — тривиальный memory DoS. |
| H-9 | `services/push_fcm.py:18` | FCM Legacy HTTP API (`fcm.googleapis.com/fcm/send`) выключен Google в 2024 — Android push мёртв. |
| H-10 | `Dockerfile:24`, нет `.dockerignore` | `COPY . .` запекает `.env` и `secrets/*.p8` в слой образа. Bind-mount `./secrets` в compose при этом избыточен. |

### Medium

- `routes/ws.py:187-193, 294-300` — падение pubsub-listener (Redis-хикап) → зомби-сокет: открыт, ничего не получает, клиент не переподключается.
- `routes/ws.py:270-272` — членство в чате проверяется только на handshake; выгнанный из группы продолжает получать все события чата до дисконнекта.
- `services/push_apns.py:82-87`, `push_dispatcher.py:149-169` — тихие пуши идут с `apns-push-type: alert`, priority 10; для content-available нужны `background`/5 (вероятно, Apple их режет).
- `utils/redis.py:5-8`, `utils/deps.py:37` — у Redis-клиента нет таймаутов, `is_session_revoked` без обработки ошибок → раздел сети с Redis вешает весь авторизованный трафик.
- `docker-compose.yml:21-27` — Redis без `--appendonly`; рестарт может потерять `revoked_session:*` → отозванные access-токены оживают до `ACCESS_TOKEN_EXPIRE_DAYS` (минимум сутки, гранулярность в днях).
- `services/email_service.py:21,28` — `smtplib.SMTP` без `timeout` → зависшие потоки executor'а.
- `worker.py:41-55 vs 72-82` — «at-most-once» = «possibly-never»: `send_at` обнуляется в одной транзакции, если воркер упал до commit второй — сообщение потеряно без ретрая.
- `models/session.py:22` — refresh-токены хранятся в БД в открытом виде.
- `services/chat.py:17-41` — `get_private_chat_between` без фильтра `type == private`: 2-местная группа считается DM. Нет unique на пару → параллельные `POST /chats` создают дубли DM (и saved chat).
- `services/chat.py:131-158` — pin не проверяет, что сообщение из этого чата; в DM закрепить нельзя вообще (роль `member` → 403).
- `services/message.py:117-126` — упоминания матчатся по `nickname`, а `@handle` — это `username`. Mentions и их push-приоритет фактически не работают.
- `schemas/chat.py:31`, `services/group_service.py` — роль `member` разрешена в каналах (даёт право постить), обратно в `subscriber` понизить нельзя; `remove_member` не уменьшает `subscribers_count`; счётчик — неатомарный read-modify-write.
- `routes/friend.py:65,77`, `routes/user.py:232,301-304`, `routes/call.py:71-77` — `UserOut` строится напрямую из ORM в обход privacy-фильтра (`last_seen_at`, `avatar`); `/presence` отдаёт `online` при `last_seen=nobody`.
- N+1: `build_user_out` в циклах (`routes/chat.py:294`, до 500 участников), `bulk_mark_read` тянет все id сообщений `<= up_to` и суёт их в `IN (...)`, `_get_badge` и `/users/me/badge` считают `len(all())`.
- `services/s3.py:36-49` + `media_service.py:204-231` — два слоя кеша presigned URL по 3000 с при TTL 3600 → можно отдать протухшую ссылку.
- Чужие неотправленные scheduled-сообщения читаются через `/messages/{id}/history`, forward, reactions, search (нет фильтра `send_at`).
- Нет проверки блокировки при добавлении в группу / join по инвайту.
- `push_apns.py:91,161` — новый `httpx.AsyncClient(http2=True)` на каждый пуш; Apple штрафует за connection churn.
- `services/sync_engine.py:69-75` — каждое событие публикуется и в `chat:{id}`, и в `user:{id}` каждого участника, с новой DB-сессией на каждый publish. Клиент на обоих сокетах получает всё дважды.
- `/register` читает `X-Device-ID` только из заголовка, `/login` — ещё из тела; при `device_id=None` все безголовочные устройства схлопываются в одну сессию → взаимный reuse-детект.
- Детект «нового устройства» чисто по IP (`user_agent` не используется) → на мобильном алерт при каждом логине.

### Low

`int(payload["sub"])` вне try → 500 вместо 401 (`utils/deps.py:30`, `routes/ws.py:58`); одно pubsub-соединение Redis на каждый WS-клиент (лимит `maxclients` = потолок WS); fire-and-forget `create_task` без хранения ссылки (5 мест); порядок shutdown в `main.py:41-47` (engine/redis закрываются пока `finally` WS-хендлеров ещё бегут); pre-auth токены переигрываются 5 мин (`jti` не трекается); `X-Request-ID` логируется без ограничения; `/metrics` без auth; `arq-worker` стартует параллельно с `alembic upgrade` → исключение на первом тике; MinIO-бакет анонимно читаемый (обесценивает presigned expiry); `POST /chats` с `user_id == self` каждый раз создаёт новый одиночный чат; owner может понизить сам себя до `member` (чат без владельца); `end_call` от caller на ringing ставит `missed` вместо `cancelled`; `Call.chat_id` никогда не заполняется; `/calls/history?limit=-1` → 500; удалённые (soft) пользователи по-прежнему френдятся/блокируются/получают DM; расширение файла берётся от клиента без проверки длины → переполнение `s3_key VARCHAR(512)` после успешного PUT (сирота в S3); `image/svg+xml` разрешён для аватарок; soft-deleted сообщения по-прежнему отдают `media`/`reply_to`/реакции; pytest в production-зависимостях, `arq` ставится дважды; контейнер под root.

---

## 3. iOS — баги и дыры

### Critical

| # | Где | Что |
|---|-----|-----|
| C-5 | `ChatDetailViewModel.swift:255-259` | **Группы и каналы рендерятся как DM.** `title` перезаписывается ником первого «не-я» участника без проверки `isGroup` (он ставится позже и только для `type == "group"`; `"channel"` не обрабатывается нигде в Chats). Итог: аватар и кнопки звонка — на случайного участника, у 2-местной группы включается presence-polling, у канала открывается `PartnerProfileSheet` с «Заблокировать» на случайного подписчика. Read-only режима для подписчиков нет. |
| C-6 | `ChatDetailViewModel+Realtime.swift:95-119` | **Входящие в открытом чате не помечаются прочитанными.** `markRead` вызывается только при открытии и при переходе `setAtBottom(true)`. Параллельно `AppState.handleMessageNew` дёргает перезагрузку списка → у чата, который ты читаешь, растёт unread-бейдж. |
| C-7 | `MessageNotifications.swift:192`, `:162-163` | **Тап по пушу — тупик.** `.siberiaOpenChat` постится, но слушателя нет нигде. Для APNs-пуша ещё и ключи не совпадают: клиент читает `chatId/messageId`, бэкенд шлёт `chat_id/message_id`. `didReceiveRemoteNotification` нет, silent-пуши бейджа игнорируются. |
| C-8 | `CallKitManager.swift:61-78`, `AppState.swift:195` | **Двойной report в CallKit ломает звонок.** Бэкенд шлёт и VoIP push, и WS `call_incoming`; второй `reportNewIncomingCall` с тем же UUID возвращает `callUUIDAlreadyExists`, error-ветка делает `unregister(callId:)` → CXAnswer/CXEnd падают в `action.fail()`, `endCall` становится no-op: **ни ответить через CallKit, ни завершить из приложения**. |
| C-9 | `APIClient.swift:178-206`, `AppState.swift:51-56` | **Провал refresh никогда не разлогинивает.** `refreshFailed` бросается, но никто не чистит токены и не сбрасывает `isAuthenticated` (README врёт, что VM зовёт `logout()`). Токены в Keychain переживают переустановку, а `device_id` в UserDefaults — нет → после переустановки приложение открывает главный экран, где каждый запрос падает «Сессия истекла», а WS вечно ретраит мёртвый токен. |

### High

- `ChatDetailViewModel.swift:158-178` — `.task` не проверяет `Task.isCancelled`; уход из чата во время загрузки → `onDisappear` закрывает сокет, а живой `onAppear` открывает его заново и запускает presence-polling с сильным `self` → утечка VM + живого WS на каждый брошенный чат.
- `ChatDetailView.swift:493-496` (вероятно) — load-more триггер в первой строке `LazyVStack` срабатывает до scroll-to-bottom; `loadMore` prepend'ит без сохранения якоря → прыжок вьюпорта и каскад догрузок.
- `+Realtime.swift:79` — reconnect зовёт `loadMessages()` → история заменяется последними 50, `hasMoreMessages` сбрасывается; пролистанное теряется.
- `ChatDetailViewModel.swift:441-444` — «Удалить у меня» на неотправленном сообщении не убирает его из persistent-очереди → повторно отправится при следующем reconnect.
- `MessageBubbleView.swift:167-172`, `ChatMediaViews.swift`, `MediaGalleryView.swift:241` (вероятно) — на failure `AsyncImage` инвалидируется кеш и перезапрашивается `/media/{id}/url` → бесконечный цикл запросов на битую картинку.
- `ChatDetailViewModel.swift:31,34` — read receipts не инициализируются из REST (моделей с last-read нет) → при открытии все свои сообщения с одной галкой.
- `GroupInfoSheet.swift:236`, `PartnerProfileSheet.swift:234` — после «выйти из группы»/«заблокировать» экран чата остаётся открытым, можно писать.
- `RealtimeClient.swift:96-100` — после отмены receive-loop безусловно `scheduleReconnect()`; `reconnectMeSocket()` (зовётся на каждый VoIP push) делает disconnect+connect подряд → старый цикл через 2 с сносит свежий сокет ровно в момент прихода offer/ICE (вероятно).
- `RealtimeClient.swift:41`, `AppState.sendOverMe` — отправка в nil-сокет молча теряется; SDP/ICE не ставятся в очередь → блип WS при установке звонка = звонок не соединится.
- `RealtimeClient.swift:64,119-120` — WS никогда не обновляет access-токен (401 на handshake = вечный backoff со старым токеном); `attempt` не сбрасывается после успешного reopen (после первой аварии каждая следующая ждёт полные 30 с); нет reconnect `/ws/me` на `scenePhase == .active`.
- `VoIPPushManager.swift:41-48`, `PushTokenService.swift:28` — VoIP-токен приходит один раз на старте; если не залогинен → 401 и никаких ретраев после логина (свежая установка не получает звонки до холодного перезапуска). `unregister` не вызывается никогда; `logout` оставляет токены привязанными к старому юзеру.
- `AppInfo.plist:12-13` — `NSAllowsArbitraryLoads=true` уезжает в Release (один plist на обе конфигурации).
- `VoIPPushManager.swift:76-94`, `AppState.swift:10,41` — report в CallKit из `Task { @MainActor }` (делегат возвращается раньше); `AppState.shared` — weak static, при push-запуске убитого приложения он nil → Accept попадает в «no context», но action всё равно fulfill'ится → CallKit показывает соединённый звонок, за которым ничего нет.
- `CallKitManager.swift:157-176, 201-203` — fulfill CXAction ждёт сетевой запрос; медленный ответ → `timedOutPerforming → fail()`, потом `fulfill()` на проваленном action; при ошибке accept action всё равно fulfill.
- `CallManager.swift:20-28` — TURN нет (TODO).
- `CallManager.swift:501-504` — ICE `.failed/.closed` только ставят `phase=.ended` (нет `CallService.end`, нет CallKit-репорта, `activeCall` не nil); `.disconnected` не обрабатывается → зависший экран до ручного End.

### Medium

- `APIClient.swift:130-176` — `upload()` без 401→refresh→retry; после истечения access-токена загрузка медиа падает.
- `APIClient.swift:97-107, 204-205` — после gate нет проверки «токен уже ротирован» → N параллельных 401 = до N последовательных ротаций (см. бэкенд H-3); пара токенов пишется неатомарно.
- `ChatDetailViewModel.swift:290-293` — ответ `sync` выкидывается, кроме `latestSeq`: пропущенные edit/delete/reaction и >50 сообщений не применяются. «Gap recovery через sync» — номинальный.
- `RealtimeClient.swift:77-79` — `onReconnect` стреляет сразу после `resume()` на каждой попытке → `runSync + loadMessages + flushPendingQueue` на каждом тике backoff'а в офлайне.
- `AppState.swift:124-126` — любой неизвестный кадр на `/ws/me` → `GET /chats`; бэкенд шлёт туда все события всех чатов → перезагрузка списка на каждую реакцию/read receipt где угодно. Плюс `ChatsView.load()` делает `members` + `messages?limit=1` per chat (N+1).
- `AppState.swift:168-200` — второй входящий во время первого перетирает `incomingCall`, второй CallKit-report падает (maxCallsPerGroup=1) → unregister → Accept первого без контекста.
- `ActiveCallView.swift:213-220` — тикер живёт до `phase == .ended`, `forceTeardownAllCalls` nil'ит `activeCall` без `.ended` → 2 Hz task навсегда.
- `CallKitManager.swift:84-95` — при провале `CXStartCallAction` `manager.start()` всё равно запускается, но CallKit не активирует аудио (manual-audio) → немой звонок без ошибки.
- `pbxproj:284,318` `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — `APIClient`, `TokenStorage`, `ChatCacheService` и все сервисы стали main-actor: JSON encode/decode кеша чатов и запись на диск идут на главном потоке; `TokenStorage.shared.accessToken` читается из socket-актора без `await` (в Swift 6 — ошибка компиляции).
- `CallManager.swift:392-395` — `minBitrateBps=1.2 Mbps` + `maintainResolution` запрещает энкодеру адаптироваться на плохом сотовом → фризы.
- `CallSignaling.swift:84` — `pendingInbound` растёт бесконечно для call id, которые не attach/detach.
- `APIConfig.swift:29-35` — `INFOPLIST_KEY_SiberiaAPIBaseURL` в pbxproj не задан → всегда хардкод: Debug `192.168.1.134`, Release `https://api.siberia.app`.
- UI: реакции без optimistic update; mute-состояние и 2FA-состояние не загружаются (всегда «выключено»); создание группы при нуле друзей — вечный спиннер; `TwoFactorSetupView` при ошибке — спиннер навсегда; повторный forward того же сообщения не открывает пикер; pinned-баннер только если pin среди последних 50, unpin не обрабатывается; глобальный поиск открывает чат снизу без прыжка к сообщению и с заголовком «Чат #id»; подтверждение scheduled показывается красным тостом ошибки; `VoiceRecorder` не запрашивает `requestRecordPermission` → первая запись молча теряется; галерея из профиля открывает не тот элемент; index-out-of-range в галерее при удалении медиа по WS (вероятно); долгий тап по чату вероятно ещё и навигирует.

### Low

`print` в Release (`AppState.swift:334,336`, `ChatDetailView.swift:336,346`); `CrashReporter` не подключён и signal-handler не async-signal-safe; иконка CallKit — полноцветный AppIcon вместо маски; `Dictionary(uniqueKeysWithValues:)` трапнется на битом кеше; local notification всегда с заголовком «Siberia» (`senderName` не передаётся); backoff без jitter; `aps-environment=development`; мёртвый код: `IncomingCallView`, `AppState.accept/declineIncomingCall`, `FullscreenImageView`, `RowPressStyle`, `updateMuteState`, `PushTokenService.unregister`, `onSetHistoryId`; неиспользуемые методы сервисов: `updateChatMeta`, `createInviteLink/revokeInviteLink/joinByInvite` (UI инвайт-ссылок нет), `ChannelService.unsubscribe` (**из канала выйти нельзя**), `searchMessages`; `pendingMessages` с `userId: 0` до загрузки `/users/me` (пузырь не на той стороне); «invalid» в тексте любой ошибки регистрации → «Этот email уже зарегистрирован»; отмена исходящей заявки через `reject` (хак); пустые `catch {}` в Profile/ForwardPicker; `UIScreen.main.bounds`; хардкод `ru_RU`; копипаста hex-палитр в 4 файлах; deprecated API (`CXProviderConfiguration(localizedName:)`, `.allowBluetooth`).

---

## 4. Недоделки и хвосты (по коду)

**Бэкенд**
- Инвайт-ссылки для каналов создать невозможно (`generate_invite_link` требует `type == group`) → `GET /channels/join/{slug}` недостижим, приватные каналы незаходибельны.
- Публичный канал нельзя читать не подписавшись (нет preview-эндпоинта).
- Админы групп не могут удалять/редактировать чужие сообщения.
- `GET /chats` не отдаёт unread, last-message, собеседника DM → клиент вынужден делать N+1.
- Push: только `message_new` и VoIP; friend request/accept, add-to-group, role change, reactions — нет.
- Мёртвый код: `MediaOut`, `MessageSendResponse`, `get_unread_count`, `include_scheduled`, `is_blocked`, `s3.delete_object`, `cache_set/get/delete`, `_recv_with_heartbeat(token)` (аргумент не используется), дубль `is_online` в dispatcher.
- Дрейф миграций и моделей: `uq_chat_member` (БД) vs `uq_user_chat` (модель); `user_id/chat_id` NOT NULL в БД, nullable в модели; `users.created_at` есть в БД, нет в модели; DB-only индексы (`ix_messages_fts` и др.) отсутствуют в моделях → `alembic autogenerate` предложит их дропнуть. `create_type=False` на generic `sa.Enum` — no-op, работает случайно.

**iOS**
- Video notes («кружки»): режим переключается, запись отключена.
- Sync `updates` не применяются; gap recovery = полная перезагрузка последних 50.
- `remote-notification` background mode объявлен, обработчика нет.
- Тестовый таргет отсутствует, единственный тест-файл не компилируется.
- `README.md` iOS устарел по ~8 пунктам (токены «в UserDefaults», WS через `?token=`, `DELETE /sessions/all-other`, путь `Siberia 2/`, Xcode 15/iOS 17 vs реальные Xcode 26/iOS 26, refresh через header vs body, списки моделей).

**Документация корневая**
- README: «Requires Xcode 15+ and iOS 17+», «Swift 5.9» — фактически deployment target iOS 26.0, `SWIFT_VERSION = 5.0` в pbxproj, Xcode 26.
- README: «scales to multiple instances» — pub/sub да, rate limiter нет (in-memory per process, и вдобавок глобальный).
- README/`.env.example` описывают «Legacy Server Key» FCM, который мёртв.
- Backend README документирует только `?token=` для WS, который в production отключён.
- ROADMAP говорит «Push ✅ DONE (Sprint 3)» и тут же «push сейчас вообще не приходят» — противоречие.
- CHECKLIST.md всё ✅, кроме 6.8; по факту см. §2.
- Локальный `.env` без S3/SMTP → локально медиа и почта не работают; `ENV=production` нигде не выставляется → CORS/secret/WS-guards выключены, пока оператор не вспомнит.

---

## 5. Что неустойчиво архитектурно

1. **Presence** держится на TTL-ключе, который обновляется только «полезными» кадрами — любой тихий клиент выглядит офлайн (H-2). Плюс счётчик соединений DECR'ится в минус.
2. **Realtime-дедупликация** переложена на клиент (каждое событие ×2 через `chat:` и `user:`), но клиент дедуплицирует только `message_new` по id, остальное перезагружает список целиком.
3. **Refresh-ротация** без лока на сервере + без «уже ротирован» на клиенте + отсутствие logout на `refreshFailed` = три независимых пути к «все сессии удалены, приложение висит в мёртвом состоянии».
4. **Звонки**: два канала доставки `call_incoming` без дедупликации на клиенте, ringing без таймаута на сервере, ICE-failure без cleanup, сигналинг без очереди. Каждый из этих пунктов сам по себе ломает сценарий.
5. **Fan-out O(участников)** с новой DB-сессией на publish и `MessageStatus` на каждого участника канала на каждый пост — каналы на тысячи подписчиков лягут.
6. **Rate limiting** in-memory и (по ошибке) глобальный — не работает ни как защита, ни горизонтально.
7. **God-views/VM**: `ChatDetailView` 1159, `ChatsView` 938, `ProfileView` 884 строк, `ChatDetailViewModel` ~1040 строк в 3 файлах. Правки типа C-5 будут задевать всё.

---

## 6. Рекомендуемый порядок

**Сначала (ломает продукт или безопасность, каждое — часы, не дни):**
1. C-4 email из `UserOut` (сделать `Optional`, отдавать только себе).
2. C-3 `check_not_blocked` в `create_message`.
3. C-1 rate limiter: `Limiter(bucket_factory)` с per-key бакетами или fastapi-limiter поверх Redis; заодно H-1.
4. C-2 2FA pending: `login_user` должен проверять `not startswith("pending:")`, `setup_totp` не перезаписывать активный секрет.
5. H-2 `presence_refresh` на pong (или внутри `_recv_with_heartbeat`).
6. H-5 `populate_existing()` в `lock_chat_row`.
7. C-9 обработка `refreshFailed` → `AppState.logout()`; H-3 `FOR UPDATE` в refresh.
8. C-5 проверка типа чата до подстановки title/partner; read-only для subscriber.
9. C-6 `markRead` на входящее при `isAtBottom`.
10. C-7 слушатель `.siberiaOpenChat` + единые ключи `chat_id/message_id`.
11. C-8 дедуп `call_incoming` по `call_id` перед CallKit-report; H-7 таймаут ringing в воркере.
12. H-10 `.dockerignore`.

**Потом:** pytest-инфраструктура (Блок 4 плана) — без неё каждый фикс выше нечем закрепить; тест-таргет iOS; FCM v1 или выпилить Android-ветку; APNs headers для silent push; `GET /chats` с unread/last-message (убирает два N+1 и reload-шторм); sync `updates` на клиенте; TURN.

**Документацию** привести к коду одним заходом после первой волны фиксов — сейчас три файла (README, CHECKLIST, ROADMAP) описывают три разных состояния проекта.
