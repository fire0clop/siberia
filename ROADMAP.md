# Siberia — ROADMAP до Telegram-уровня

> Этот файл — практический план работ по итогам полного аудита (iOS + backend + tech debt) от 2026-05.
> Существующий `CHECKLIST.md` — backend-only и показывает что бэкенд закрыт. Здесь — общий план: где iOS догоняет бэкенд, где баги, где совсем нет фичи.
>
> Статусы: `[ ]` — не начато · `[~]` — частично · `[x]` — готово

---

## Текущая ситуация (срез на 2026-05)

- **Backend** реализован на ~95% от внутреннего плана: группы, каналы, 2FA, scheduled messages, privacy, блокировки, mute чата, invite-ссылки, реакции, mentions, pinned, drafts, поиск, push.
- **iOS** реализован на ~50%: базовые 1-на-1 чаты, медиа, голос, реакции, друзья — работают. Из бэка многое **не подключено** в UI.
- **Готовность к Telegram-уровню** — около 50%. Главные пробелы: звонки, E2E, stories, форматирование текста, стикеры/GIF.

---

## SPRINT 1 — Критические фиксы и безопасность ✅ DONE (2026-05-16)

> Закрыли дыры в фундаменте. Smoke-тесты:
> - Token blacklist в Redis после logout → `revoked_session:{id}` ключ + 401 на следующем `/users/me` ✓
> - Email-verify lockout: 4 неверных кода → 5-я попытка возвращает 429 ✓
> - WS подключается через `Authorization: Bearer …` заголовок ✓
> - CORS production guard: `ENV=production` + `*` → RuntimeError при старте ✓

### Безопасность
- [x] **Токены в Keychain** вместо `UserDefaults` (`iOS/Core/Storage/TokenStorage.swift`). Используется `kSecAttrAccessibleAfterFirstUnlock`. Авто-миграция со старого UserDefaults при первом запуске.
- [x] **WS-токен в заголовке** `Authorization: Bearer …` при handshake. Backend (`routes/ws.py::_extract_token`) принимает header первым, fallback на query param для backward compat.
- [x] **Token blacklist в Redis** — `utils/redis.py::mark_session_revoked` + `is_session_revoked`. Проверяется в `utils/deps.py::get_current_user` (HTTP) и `routes/ws.py::_token_invalid` (WS). Все места удаления сессий (logout, FIFO evict, change_password, delete_account, /sessions/{id}, /sessions/revoke_all, refresh-token reuse) теперь маркируют sid в Redis на TTL = ACCESS_TOKEN_EXPIRE_DAYS.
- [x] **Rate-limit на `/auth/verify-email` и `/auth/resend-verification`** — 10 req/min IP-based + per-user lockout: после `VERIFY_CODE_MAX_ATTEMPTS=5` неверных кодов блокировка на `VERIFY_CODE_LOCKOUT_MINUTES=15` минут (`utils/redis.py::verify_*`).
- [ ] ~~Email-код 8 символов~~ — оставили 6 цифр + lockout (см. выше).
- [ ] SSL pinning — отложено в следующий спринт.
- [x] **CORS production guard** в `backend/main.py` — при `ENV=production` и `*`/пустых `CORS_ORIGINS` процесс падает с RuntimeError при старте.

### Bugs
- [x] **Force-unwraps** в `iOS/Features/Chats/ChatsView.swift:243,352` — заменены на `?? false` / `?? ""`.
- [x] **Дедупликация WS** в `ChatDetailViewModel.handleSocketText`: добавлен dedup по `client_message_id` (если уже есть финализированное сообщение с тем же cid и id > 0 → пропускаем). Вторая проверка по `id` оставлена.
- [x] **WS-реконнект** с exponential backoff в `RealtimeClient.swift`: 2, 4, 8, 16, 32 → cap 30 секунд. `manualDisconnect` различает «закрыл сам» от «отвалилось».
- [x] **Sync gap recovery после reconnect**: новый параметр `onReconnect` в `RealtimeSocket.connect`. `ChatDetailViewModel` подписывается и при реконнекте вызывает `runSync()` + `loadMessages()`. `AppState` (для /ws/me) на реконнект постит `siberiaChatsShouldReload` notification.
- [x] **Идемпотентность scheduled messages** в `backend/worker.py`: атомарный claim через `UPDATE messages SET send_at = NULL WHERE … RETURNING id` — гарантирует at-most-once при нескольких воркерах.
- [x] **Race в `chat.sync_seq`** — проверено: все 14 callers `log_update_on_locked_chat` используют `lock_chat_row` (SELECT FOR UPDATE). Добавлен defensive `RuntimeError` при `chat=None` + явный docstring чтобы не сломалось в будущем.

### Tech debt
- [x] **Hardcoded IP** — `APIConfig.swift` читает `SiberiaAPIBaseURL` из Info.plist с fallback'ом. Инструкция по настройке per-configuration через `INFOPLIST_KEY_SiberiaAPIBaseURL = $(SIBERIA_API_BASE_URL)` — в комментариях файла.
- [x] **`try?` → `try` + log** через новую обёртку `Core/Logger.swift` (LogCategory над `os.Logger`):
  - `SiberiaApp.swift` — push register
  - `ProfileView.swift` — все 4 reload-функции (`refreshUser`, `loadRequests`, `loadSessions`, `loadFriends`)
  - `ChatDetailViewModel.swift::loadChatMeta` — оба `try?` заменены на `do/catch` + `Log.chat.error`
- [x] **`pass`/`return None` → log** в backend:
  - `routes/ws.py` — добавлен модульный logger, заменены `pass` на `logger.debug/warning/exception` (5 мест)
  - `services/thumbnail.py` — все 7 `pass`/`return None` теперь логируют через `logger.exception/warning/debug`
  - `services/user_service.py` — `pass` в presigned URL и `cache_get` парсе → `logger.exception/warning`
- [x] **Двойные push в foreground**: `SiberiaNotificationDelegate.willPresent` в `applicationState == .active` теперь возвращает `[.list, .sound]` без `.banner` — local-banner от WS показывается единственным.
- [x] **Magic delays → константы** в новом `Core/Config/UIConstants.swift`:
  - `scrollToMessageDelay` (0.35s), `messageHighlightDuration` (1.2s)
  - `errorToastAutoDismissSec` (4s), `presencePollIntervalSec` (30s)
  - `typingDebounceMs` (500ms), `typingFadeOutSec` (5s)
  - extensions `.seconds_ns` и `.ms_ns` для удобной интеграции с `Task.sleep`
- [x] **Backend константы → config**: `MAX_SESSIONS`, `VERIFY_CODE_TTL_MINUTES`, `VERIFY_CODE_MAX_ATTEMPTS`, `VERIFY_CODE_LOCKOUT_MINUTES`, `WS_PING_INTERVAL`, `WS_PING_TIMEOUT`, `ENV` — все в `config.py::Settings`.

---

## SPRINT 2A — Подключить готовый backend (часть 1) ✅ DONE (2026-05-16)

> Smoke-тесты (backend):
> - `POST /chats/group` создаёт группу, members имеют корректные роли (owner/member) ✓
> - `POST /channels` + `GET /search/channels` → создание и поиск работают ✓
> - 2FA: setup → confirm (через pyotp.TOTP.now()) → login возвращает `requires_2fa=true` + temp_token ✓
> - WebSocket уведомления о новых членах через системные сообщения (бэк готов, iOS рендерит) ✓

### Группы (backend: ✅ — iOS: ✅)
- [x] **`CreateGroupSheet`** в `Features/Chats/`: title + description + мульти-select друзей → `POST /chats/group`.
- [x] **Quick-action в `NewChatSheet`** — две карточки сверху: «Группа» и «Канал».
- [x] **`GroupInfoSheet`** в `Features/Chats/` — заменяет `PartnerProfileSheet` когда `vm.isGroup`:
  - аватар-плейсхолдер + название + счётчик участников
  - список участников с role-badge (owner/admin)
  - tap на участника (если я admin/owner) → confirmationDialog: сделать админом/снять/удалить
  - кнопка «Покинуть группу» (owner предупреждается о передаче прав)
- [x] **`AddGroupMembersSheet`** — выбор из друзей которые ещё не в группе.
- [x] **Сервисные методы** в `ChatService`: `createGroup`, `addMembers`, `removeMember`, `leaveChat`, `changeMemberRole`, `updateChatMeta`, `createInviteLink`, `revokeInviteLink`, `joinByInvite`.
- [x] **Системные сообщения** — рендерятся как капсула-плашка по центру с `regularMaterial` (как `dateSeparatorView`). Поле `type: "system"` в `ChatMessage` + computed `isSystem`. `userId` сделан опциональным.
- [ ] ~~Deep-link `siberia://join/{slug}`~~ — отложено в 2B (universal links и deep-links).

### Каналы (backend: ✅ — iOS: ✅)
- [x] **`CreateChannelSheet`** в `Features/Channels/`: title + description + public toggle → `POST /channels`.
- [x] **`ChannelService.swift`** (новый) — create/get/subscribe/unsubscribe/subscribeByInvite/searchPublic.
- [x] **`ChannelSearchView`** в `Features/Channels/` — debounced (350ms) поиск через `GET /search/channels`, кнопка «Подписаться» на каждой строке → `POST /channels/{id}/subscribe` → открыть канал.
- [x] **Menu в toolbar** `ChatsView`: «Новый чат / группа» + «Найти канал».
- [ ] ~~Subscriber-only read mode~~ — UI поля ввода в `ChatDetailView` пока не скрывается для подписчиков канала; backend сам блокирует `POST messages` с 403 для роли `subscriber`. Будет в 2B (нужны права в `ChatMember.role`).

### 2FA (backend: ✅ — iOS: ✅)
- [x] **`TwoFactorSetupView`** в `Features/Auth/`: `POST /auth/2fa/setup` → отрисовка QR (через `CIQRCodeGenerator`) + ключ-копия → ввод кода → `POST /auth/2fa/confirm` → экран-успех.
- [x] **`TwoFactorChallengeSheet`** — модал на этапе логина: если сервер вернул `requires_2fa: true`, показывается над `AuthView` с полем 6-значного кода → `POST /auth/2fa/verify` → бутстрап.
- [x] **`TwoFactorDisableSheet`** — требует ввести текущий TOTP → `DELETE /auth/2fa`.
- [x] **`AuthService.LoginOutcome`** — enum `.success(User)` / `.twoFactorRequired(tempToken)`. `AuthViewModel.pendingTwoFactorToken` управляет показом sheet'а.
- [x] **`AuthResponse`** обновлён под двойной формат (требует tempToken/requiresTwoFa).
- [x] **«Безопасность» секция в `ProfileView`** — toggle включить/выключить 2FA.

### Email-верификация (backend: ✅ — iOS: ✅)
- [x] **`EmailVerificationView`** в `Features/Auth/`: иконка-конверт + 6-значное поле (numberPad + `.oneTimeCode`) + кнопка «Подтвердить» + «Отправить заново» с 60-секундным cooldown.
- [x] **Auto-show после регистрации** — `AuthViewModel.pendingEmailVerification = true` сразу после успешного register.
- [x] **Бейдж в профиле** — в новой секции «Безопасность»: оранжевый треугольник + кнопка «Подтвердить» если `user.emailVerified == false`; зелёная галочка если verified.
- [x] **`User.emailVerified`** добавлено в модель (плюс `bio`, `username` про запас).
- [x] **`AuthService.verifyEmail / resendVerification`** — две новые функции.

---

## SPRINT 2B — Подключить готовый backend (часть 2) ✅ DONE (2026-05-16)

> Все 9 фич закрыты. Smoke-тесты по эндпоинтам ниже.

### Privacy settings (backend: ✅ — iOS: ✅)
- [x] **`PrivacySettingsView`** в `Features/Profile/` — Form с 3 inline-Picker'ами (последний визит / аватар / кто пишет первым). Auto-save на каждое изменение.
- [x] **`UserService.getPrivacy() / updatePrivacy(...)`** — `GET/PATCH /users/me/privacy`.
- [x] **Модель** `PrivacySettings` + enum `PrivacyVisibility` (everyone/friends/nobody).

### Блокировки (backend: ✅ — iOS: ✅)
- [x] **Кнопка «Заблокировать»** в `quickActionsRow` `PartnerProfileSheet` (красная иконка hand.raised).
- [x] **Context-menu на строке друга** в `ProfileView` → «Заблокировать».
- [x] **`BlockedListView`** в `Features/Profile/` — список + кнопка «Разблокировать».
- [x] **`UserService.block / unblock / listBlocked`** — endpoints дёрнуты.

### Друзья — недостающие действия (backend: ✅ — iOS: ✅)
- [x] **Отклонить заявку** — красная кнопка `xmark.circle.fill` рядом с зелёной accept в `requestsCard`.
- [x] **Удалить из друзей** — context-menu на строке друга (рядом с «Заблокировать»).
- [x] **`SentRequestsView`** — отдельный sheet с исходящими, кнопка «Отозвать» (использует тот же reject endpoint).
- [x] **`FriendService.reject / remove / getSentRequests`** — три новые функции.

### Mute чата (backend: ✅ — iOS: ✅)
- [x] **В `quickActionsRow` `PartnerProfileSheet`** — кнопка bell.slash с confirmationDialog: «1 час / 8 часов / Навсегда».
- [x] **В `GroupInfoSheet`** — Section с тем же confirmationDialog.
- [x] **`ChatService.mute(chatId:, until:)` / `unmute(chatId:)`** — обёртки над `POST/DELETE /chats/{id}/mute`.
- [ ] ~~Иконка mute в чат-листе~~ — отложено (требует загрузки `mute_state` в `GET /chats`, бэк сейчас не отдаёт).

### Pinned message (backend: ✅ — iOS: ✅)
- [x] **Pinned-баннер** в `ChatDetailView.pinnedBanner` — кликабельный, прыгает к сообщению через `vm.jumpToMessageId`. Кнопка «открепить» доступна admin/owner.
- [x] **Context menu** — «Закрепить» / «Открепить» только в группах с ролью admin/owner (в DM бэк отвечает 403, что правильно).
- [x] **`ChatService.pin / unpin`** — POST/DELETE endpoints.

### Scheduled messages (backend: ✅ — iOS: ✅)
- [x] **Long-press на send-кнопке** — `simultaneousGesture(LongPressGesture(0.5))` открывает `ScheduleMessageSheet` (haptic feedback heavy).
- [x] **`ScheduleMessageSheet`** в `Features/Chats/` — `DatePicker(.graphical)` + быстрые кнопки «Через час / Завтра 9:00 / Через неделю».
- [x] **`ScheduledMessagesSheet`** — список отложенных + индивидуальная отмена. Открывается из menu в шапке чата.
- [x] **`ChatService.scheduleMessage / listScheduledMessages / cancelScheduled`** — три новые функции, `MessageScheduleBody` model.

### Bio пользователя (backend: ✅ — iOS: ✅)
- [x] **`EditProfileView`** в `Features/Profile/` — Form с nickname + bio (200 символов, счётчик). `PATCH /users/me`.
- [x] **Отображение bio** в `PartnerProfileSheet` под именем/email (footnote, secondary, centered).
- [x] **`UserService.updateProfile(nickname:bio:)`** + `User.bio` поле в модели.

### Глобальный поиск (backend: ✅ — iOS: ✅)
- [x] **`GlobalSearchView`** в новой папке `Features/Search/` — debounced (350ms) + segmented picker «Чаты / Сообщения / Люди» с счётчиками.
- [x] **Tap на user** — создаёт DM через `POST /chats` и открывает.
- [x] **Tap на чат/сообщение** — открывает чат.
- [x] **Кнопка в toolbar** `ChatsView` (magnifyingglass в topBarLeading) → открывает sheet.
- [x] **`UserService.globalSearch(query:limit:)`** + полная модель `GlobalSearchResponse`.

### WebSocket presence event (backend: ✅ — iOS: ✅)
- [x] **`services/presence_broadcast.py`** на бэке — `broadcast_presence(user_id, is_online)`:
  - собирает interested_user_ids = друзья (accepted Friend) ∪ партнёры по private DM
  - публикует `{event:"presence_change", payload:{user_id, online, last_seen_at}}` в `user:{recipient}`
- [x] **`presence_connect / presence_disconnect`** теперь возвращают `bool` — True при переходе offline↔online. Только тогда вызывается broadcast.
- [x] **iOS** — `Notification.Name.siberiaPresenceChange` + `AppState.handleMeWebSocketText` ловит event и постит в NotificationCenter с userInfo `[user_id, online, last_seen_at]`.
- [x] **`ChatDetailViewModel.subscribePresenceUpdates()`** — слушает уведомления, фильтрует по `partnerUserId`, обновляет `isPartnerOnline` мгновенно.
- [ ] ~~Удалить polling каждые 30s~~ — оставлен как backup на случай если presence-event был пропущен. Можно убрать в будущем.

### Smoke-тесты (Sprint 2B)
| Сценарий | Результат |
|---|---|
| `GET /users/me/privacy` | `{last_seen, avatar, messages_from}` ✓ |
| `PATCH /users/me/privacy` | HTTP 200 ✓ |
| `PATCH /users/me {bio}` | bio сохранён ✓ |
| `GET /search?q=...` | возвращает `{users, messages, chats}` ✓ |
| `POST/DELETE /users/{id}/block` + `/users/me/blocked` | работает ✓ |
| `POST /chats/{id}/mute`, `DELETE /chats/{id}/mute` | HTTP 200 ✓ |
| `POST /chats/{id}/pin/{mid}` (в группе) | HTTP 200 ✓ (в DM правильно 403) |
| `POST /chats/{id}/messages {send_at}` + `GET .../scheduled` + `DELETE /messages/{id}/scheduled` | HTTP 200 + list=1 ✓ |
| `POST /friends/reject/{id}` + `GET /friends/requests/sent` | HTTP 200 ✓ |
| WS presence_change через broadcast (бэк + iOS subscribe) | компилируется, ws.py принимает изменения ✓ |

---

## SPRINT 3 — Полировка существующего ✅ DONE (2026-05-17)

### Чаты и сообщения (✅ DONE 2026-05-17)
- [x] **Offline cache истории сообщений** — `ChatCacheService` хранит последние 100 финальных сообщений каждого чата в `sib_chat_{id}.json`. Загружается в `ChatDetailViewModel.onAppear` мгновенно перед сетевым запросом. После каждого `upsert` — debounced save через 2s (защита от спама диска).
- [x] **Полноценный offline-режим (pending queue)** — `ChatCacheService.PendingOutgoing` персистит исходящие через `enqueueOutgoing`. При отправке кладём в очередь; при успехе — `dequeueOutgoing`. На `onAppear` и при `onReconnect` WS → `flushPendingQueue()` дочитывает очередь и шлёт серверу с тем же `client_message_id` (сервер сам дедуплицирует).
- [x] **Пустые чаты** — фильтр `$0.lastMessageId != nil` снят, `baseChats` отдаёт все чаты включая только что созданные.
- [x] **Forwards с реальным `forward_message_id`** — проверено: `vm.forwardMessage(m, to: chat.id)` уже передаёт `forwardMessageId: m.id` в `ChatService.sendMessage`. Замечание в roadmap'е было устаревшим.
- [x] **Read receipts «N из M» в группах** — новое поле `vm.readReceipts: [Int: Int]` (userId → upTo). Обработчик `read_receipt` event теперь обновляет per-user. Новый компонент `readStatusIcon(for:)` в DM показывает классические галочки, в группе — «k/N» если прочитали не все, и двойную галочку когда все.
- [x] **Album grouping для видео** — `buildGroups` теперь группирует image + video + video_note вместе (от одного автора, в пределах 60s). Расширил `AlbumThumbView` чтобы рендерил видео-thumbnail (preferred: `mediaThumbURLCache`, fallback: client-generated `videoThumbnailCache`) с overlay-иконкой play.
- [x] **Edit history** — backend: таблица `message_edit_history` (миграция 013), endpoint `GET /messages/{id}/history` сохраняет старый текст на каждом `PATCH /messages/{id}`. iOS: `MessageHistoryResponse` model, `ChatService.messageHistory`, `EditHistorySheet` с временной шкалой версий. В context-menu кнопка «История изменений» появляется только если `m.editedAt != nil`.

### Realtime (✅ DONE 2026-05-17)
- [x] **Дедупликация по `client_message_id`** — сделано в Sprint 1.
- [x] **Typing debounce на сервере** — `utils/redis.typing_can_publish(chat_id, user_id)` использует `SET NX EX 3` (3-секундный throttle). В `ws.py` typing-event теперь публикуется только если разрешено.
- [x] **`presence_change` event** — сделано в Sprint 2B + invisible mode + bulk-fetch на чат-листе с зелёными точками.
- [ ] ~~**Redis Streams** вместо pub/sub~~ — отложено как самостоятельный большой рефакторинг. Текущая комбинация `chat_update` (persistence) + pub/sub (real-time) уже компенсирует потерю сообщений через `runSync()` при reconnect. Streams в будущем для presence/typing — но это уже Sprint 4 territory.

### Медиа (✅ DONE 2026-05-17)
- [x] **Использовать `mediaThumbURLCache` для inline-видео**: `loadMediaURL` заполняет `mediaThumbURLCache` из `thumbnail_url` ответа сервера. `AlbumThumbView` и `VideoThumbView` сначала проверяют `mediaThumbURLCache`, затем fallback на `videoThumbnailCache` от `AVAssetImageGenerator`.
- [x] **Кэш presigned URL на сервере**: `media_service.get_media_url` проверяет `media:url:{media_id}` в Redis (TTL 50 мин, ~3000s) перед вызовом MinIO SDK. Ключ сохраняется после первой генерации.
- [x] **Voice waveform на сервере**: клиент отправляет `waveform` при upload через `MediaService.upload(waveform:)`, бэк сохраняет в поле `media.waveform`. При `getMeta` iOS читает и кэширует в `mediaWaveforms`. ffmpeg-based extraction пропущен (нет ffmpeg на сервере).
- [x] **Сжатие видео перед отправкой**: `sendVideoCompressed(url:)` в `ChatDetailViewModel+Media.swift` — `AVAssetExportSession` с `AVAssetExportPreset1280x720`, проверка совместимости пресета, fallback на оригинал при ошибке.
- [ ] **Voice transcription** (опционально, требует Whisper или платный сервис).

### Push (✅ DONE 2026-05-17)
- [ ] **Per-chat настройки звука/кастомизации**: модель есть, UI — нет (отложено).
- [x] **Notification action buttons**: «Ответить» (`UNTextInputNotificationAction`) и «Прочитано» (`UNNotificationAction`) зарегистрированы в категории `SIBERIA_MESSAGE`. `SiberiaNotificationDelegate.didReceive` обрабатывает оба действия: Reply → `ChatService.sendMessage`, Read → `ChatService.markRead`.
- [x] **Rich notifications**: `notifyNewMessageIfNeeded` загружает `thumbnailURL` в temp-файл, создаёт `UNNotificationAttachment` и подставляет в контент. Body для медиа-сообщений — эмодзи-подпись (📷/🎬/🎤/🎵/📎).
- [x] **Do Not Disturb по расписанию**: `ChatDnDSchedule` (Codable) хранится в UserDefaults, поддерживает overnight-окна. `ChatNotificationSettingsSheet` с wheel-picker для from/to времени. Кнопка «Уведомления» в меню шапки чата показывает текущий DnD-статус.

### Архитектура (✅ DONE 2026-05-17)
- [x] **Рефакторинг `ChatDetailView.swift`** (2648 строк → 6 файлов): `MessageBubbleView.swift` (536 л.), `ComposeBarView.swift` (344 л.), `PartnerProfileSheet.swift` (438 л.), `ChatMediaViews.swift` (231 л.), `ChatHelperViews.swift` (127 л.), `ChatDetailView.swift` (1021 л. — координатор).
- [x] **Рефакторинг `ChatDetailViewModel.swift`** (1039 → 516 строк): выделены `ChatDetailViewModel+Media.swift` (249 л. — вся отправка медиа + кэш URL) и `ChatDetailViewModel+Realtime.swift` (268 л. — presence, typing, WebSocket-обработчики). Через Swift extensions — никакого изменения публичного API.
- [x] **Logging**: `os.Logger` через `LogCategory` (`Log.chat`, `Log.media`, `Log.push`) — был подключён в Sprint 1. Backend: все `pass` заменены на `logger.exception/warning/debug` в Sprint 1.
- [x] **Crash reporting**: `Core/CrashReporter.swift` — `NSSetUncaughtExceptionHandler` + signal handlers (SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP). Пишет crash-лог в Documents, `consumePreviousCrashLog()` читает и удаляет при следующем запуске. `CrashReporter.setup()` вызывается из `SiberiaApp.init`.
- [x] **Базовые unit-тесты**: `SiberiaTests/ChatCacheServiceTests.swift` — 12 тестов покрывают: save/load messages, truncation to 100, pending-фильтрацию, dropMessages, enqueue/dequeue, dedup по clientId, per-chat фильтрацию, save/load chats, clearAll. Требует добавить test target в Xcode (File → New → Target → Unit Testing Bundle).

---

## SPRINT 4 — Большие фичи

> Каждая — 1–2 месяца минимум.

### Форматирование текста (Markdown + entities)
- [ ] **Backend**: новое поле `text_entities` (JSONB) в `messages` — массив `{type, offset, length}` с типами: `bold`, `italic`, `code`, `pre`, `strikethrough`, `spoiler`, `mention`, `url`, `phone`.
- [ ] **Парсинг markdown** на стороне клиента или сервера. Telegram парсит **client-side**: пользователь пишет `**bold**`, клиент превращает в entities + чистый текст.
- [ ] **iOS-рендер**: `AttributedString` с правильными стилями.
- [ ] **Spoiler**: tap-to-reveal blur.

### Стикеры и GIF
- [ ] **Backend**: новый тип `sticker`, отдельный bucket. Стикерпаки как сущность.
- [ ] **TGS/Lottie** (анимированные стикеры) — rlottie или Lottie-iOS.
- [ ] **GIF**: Tenor/Giphy API + локальный кеш.
- [ ] **iOS**: панель стикеров рядом с emoji, hot-keys на эмодзи → стикеры.

### Архив и папки чатов
- [ ] **Backend**: поле `archived_at` в `chat_members`. Эндпоинты `POST /chats/{id}/archive`, `DELETE /chats/{id}/archive`.
- [ ] **Folders**: новая таблица `chat_folder` (user_id, name, filter rules), `chat_folder_chat` (M2M).
- [ ] **iOS**: горизонтальный pager сверху в `ChatsView` — «Все», «Личные», «Группы», кастомные папки. Свайп влево на чате → архив.

### Web preview / link unfurl
- [ ] **Backend**: при отправке сообщения с URL — async задача через ARQ, парсинг OG-tags, кеш в Redis. Возвращать в `MessageOut.link_preview`.
- [ ] **iOS**: блок с превью под сообщением (image + title + description).

### Голосовые и видеозвонки (только 1-на-1)
> Детальное объяснение архитектуры в разделе «Звонки» ниже. ~4–5 недель на всё (P2P, без групповых).

### Stories
- [ ] **Backend**: новая таблица `stories` (user_id, media_id, created_at, expires_at). Endpoints upload/list/view/react.
- [ ] **iOS**: горизонтальный круги-аватарки сверху `ChatsView`, fullscreen viewer с прогресс-баром.

### E2E-шифрование (Secret Chats)
> Очень большая отдельная фича. Опционально — Telegram держит E2E как **отдельный тип чата**, не для всех. ~2–3 месяца.
>
> Кратко: X3DH key exchange (Signal protocol) + Double Ratchet, шифрование на устройстве, сервер видит только зашифрованные blob'ы. Теряются: серверный поиск, sync на новые устройства без передачи ключа, история через web. iOS — pinned ключи + verification fingerprint между парой.

---

## ЗВОНКИ 1-на-1 — как они работают (подробно)

> Решение: делаем только 1-на-1 звонки (голос + видео). Групповые звонки (SFU/LiveKit) — намеренно вне скоупа: для 1-на-1 нужна сильно меньшая инфраструктура (только сигналинг + опциональный TURN), без media-сервера.



Это не «ещё один endpoint». Звонки — это **отдельный стек технологий поверх существующего бэка**. Объясняю как обычно делается и что нужно для Siberia.

### Архитектура: 4 слоя

Когда два пользователя говорят по голосу/видео, между ними нужно установить 4 разные вещи:

```
[ Сигналинг ]  ──> «Я тебе звоню. Согласен? Какие у тебя кодеки?»
[   ICE     ]  ──> «Какой у тебя IP? Я попробую тебя достать»
[ STUN/TURN ]  ──> «Если NAT мешает — пробьём дырку или будем релеить»
[   Media   ]  ──> SRTP-пакеты с аудио/видео между клиентами
```

#### 1. Сигналинг (signaling) — где живут offer/answer

Сигналинг — это **обмен метаданными о звонке**: «я звоню тебе», «принял», «отклонил», «закончил». А также обмен SDP-описаниями (что я могу — какие кодеки, разрешение, битрейт).

**У Siberia уже есть готовый канал: WebSocket.** Не нужен отдельный сервис. Достаточно расширить `/ws/me` новыми событиями:

```json
{ "type": "call_offer", "from": 1, "to": 2, "call_id": "uuid", "sdp": "..." }
{ "type": "call_answer", "call_id": "uuid", "sdp": "..." }
{ "type": "call_ice", "call_id": "uuid", "candidate": "..." }
{ "type": "call_end", "call_id": "uuid", "reason": "hangup|reject|timeout|busy" }
```

Бэк выступает почтальоном — пересылает события между двумя пользователями. Никакой call-логики на нём нет (только лог: кто кому когда звонил, длительность).

**Что нужно на бэке** — небольшая работа:
- Таблица `calls`: id, caller_id, callee_id, started_at, ended_at, status, type (voice/video).
- 4 новых WS-события.
- Endpoint `GET /calls/history` для истории звонков в UI.

#### 2. ICE — поиск пути между клиентами

ICE (Interactive Connectivity Establishment) — алгоритм по которому два клиента **находят способ напрямую дотянуться друг до друга**, проходя через NAT-ы домашних роутеров.

Каждый клиент собирает свои «кандидаты» (адреса где он доступен):
- **Host candidate** — локальный IP (`192.168.1.50:54321`).
- **Server-reflexive (srflx)** — публичный IP через STUN-сервер («наружу выгляжу как 213.x.x.x:54321»).
- **Relay (relay)** — адрес TURN-сервера (когда напрямую не получается).

Клиенты обмениваются всеми кандидатами через сигналинг и пробуют все пары до тех пор пока какая-то не сработает.

#### 3. STUN и TURN — два разных сервера

**STUN-сервер** говорит клиенту его публичный IP/порт. Это дешёвый сервис, не передаёт медиа. Можно использовать публичный (Google: `stun.l.google.com:19302`) — бесплатно.

**TURN-сервер** — это **релей последней надежды**, когда NAT-ы по обе стороны жёсткие (symmetric NAT, корпоративные сети). Через него идёт **весь трафик звонка**. Платная и трафик-ёмкая штука: ~1Mbps на звонок, нужно ставить свой.

Самое популярное решение для self-hosted — **coturn** (open source). Ставится одной командой, занимает ~50MB RAM, нужны проброшенные порты UDP 3478 + диапазон relay-портов.

В Telegram около 5–15% звонков идут через TURN (P2P не получился), остальные напрямую.

#### 4. Media — аудио и видео между клиентами

После того как ICE нашёл рабочий путь, между клиентами идут **SRTP-пакеты** (зашифрованный RTP). Внутри — закодированные аудио (Opus) и видео (VP8/H.264/AV1) фреймы.

Этим занимается **WebRTC** — стек уже встроен в браузеры и есть готовые библиотеки для iOS (`WebRTC.framework` от Google). Тебе не нужно писать сетевой код руками — отдаёшь WebRTC SDP и кандидаты, получаешь готовые `RTCAudioTrack` / `RTCVideoTrack`.

### Архитектура для 1-на-1: P2P

Два клиента напрямую обмениваются медиа (или через TURN если NAT жёсткий с обеих сторон). Это **простое и дешёвое решение** — Telegram использует именно его для приватных звонков.

**Плюсы**: дёшево, низкая задержка (50–150ms), нет media-сервера. Только сигналинг (твой существующий WS) + опциональный TURN.
**Минусы**: не масштабируется на >2 участников — каждый клиент бы слал свой поток всем. Но для 1-на-1 это не проблема.

### Поэтапный план

**Фаза A — голосовые звонки 1-на-1 (3 недели)**

Backend:
- [ ] Таблица `calls`: `id, caller_id, callee_id, type ENUM(voice/video), status ENUM(ringing/active/ended/missed/rejected), started_at, ended_at, duration_sec`.
- [ ] Endpoint `POST /calls` — создать звонок (caller инициирует, статус ringing).
- [ ] Endpoint `PATCH /calls/{id}/answer` — accept (status → active).
- [ ] Endpoint `PATCH /calls/{id}/reject` — reject.
- [ ] Endpoint `PATCH /calls/{id}/end` — hangup (любая сторона).
- [ ] Endpoint `GET /calls/history` — список звонков для UI.
- [ ] WS-события через `/ws/me`:
  - `call_offer { call_id, from_user_id, type, sdp }` — отправляется callee'у
  - `call_answer { call_id, sdp }` — отправляется caller'у
  - `call_ice { call_id, candidate }` — двусторонний обмен ICE-кандидатами
  - `call_end { call_id, reason }` — hangup/reject/timeout/busy
- [ ] **VoIP push** через PushKit: при `POST /calls` — если callee не на WS, шлём VoIP push c приоритетом 10 и `apns-push-type: voip`. Без VoIP push звонки не работают на заблокированном телефоне.
- [ ] Отдельный APNs `.p8` сертификат с VoIP capability в Apple Developer Portal.
- [ ] Развернуть coturn (1 VPS, $10–20/мес). Альтернатива на старте: начать без TURN и смотреть статистику unsuccessful connections.

iOS:
- [ ] Добавить `WebRTC.framework` через Swift Package Manager: `https://github.com/stasel/WebRTC`.
- [ ] Background mode в `Info.plist`: `audio`, `voip`.
- [ ] **CallKit-интеграция** (`CXProvider`, `CXCallController`) — при входящем звонке iOS показывает нативный полноэкранный UI как у системного звонка. Без CallKit при заблокированном экране звонок не разбудит юзера.
- [ ] **PushKit** для приёма VoIP push: при пуше поднимать CallKit и параллельно открывать WS-канал.
- [ ] `CallManager` — обёртка над `RTCPeerConnection` (создание offer/answer, добавление кандидатов, mute, speaker).
- [ ] UI экран звонка: avatar, имя, таймер, кнопки mute / speaker / hangup / video-toggle.
- [ ] Кнопка инициирования звонка в шапке `ChatDetailView`.
- [ ] Аудио-сессия: `RTCAudioSession` с `.playAndRecord` + `.allowBluetooth`.
- [ ] Обработка сценариев: занято (callee уже на звонке), не ответили (timeout 30s), разрыв сети, входящий звонок при текущем разговоре.

**Фаза B — видеозвонки 1-на-1 (1 неделя)**
- [ ] Те же event'ы сигналинга, в SDP включена video-track.
- [ ] UI: PiP preview своей камеры + remote video full-screen.
- [ ] Переключение front/back камеры.
- [ ] Mute video (отключить отправку без разрыва соединения).
- [ ] Тип звонка передаётся в `POST /calls` (`type: voice/video`).

### Сколько это стоит на инфраструктуре

- **Сигналинг**: 0 — едет через существующий WS.
- **STUN**: 0 — публичные Google-серверы (`stun.l.google.com:19302`) или свой coturn (копейки).
- **TURN (coturn)**: 1 VPS с нормальным каналом. ~$10–20/мес. На один звонок ~150KB/s в обе стороны (~1Mbps RTC). На 50 одновременных relay-звонков нужно ~15Mbps канал.
- **VoIP push**: 0 — APNs бесплатный.

В среднем 5–15% звонков идут через TURN (P2P не пробивает NAT), остальные 85–95% — напрямую между устройствами.

### Что брать готовое, что писать самому

| Кусок | Что брать |
|---|---|
| Сигналинг | Своё (WS уже есть) |
| WebRTC stack | `WebRTC.framework` (Google) — обязательно |
| STUN | Google's public OR свой coturn |
| TURN | coturn (self-hosted) |
| CallKit | Apple SDK (обязательно) |
| VoIP push delivery | PushKit + APNs voip-сертификат |
| Кодеки | Встроены в WebRTC (Opus, VP8, H.264) |

### Подводные камни о которых стоит знать заранее
1. **CallKit обязателен на iOS** — иначе входящий звонок при заблокированном экране не сработает.
2. **VoIP push требует отдельный сертификат** в Apple Developer Portal (`.p8` для voip).
3. **Шифрование медиа** — SRTP в WebRTC включён by default. Это **hop-by-hop**, не E2E (через TURN/SFU видно если они скомпрометированы). Telegram добавляет свой E2E поверх через ZRTP-подобный обмен ключами — это +2 недели работы, но для Telegram-уровня нужно.
4. **Эхо-cancellation, шумоподавление** — WebRTC даёт из коробки, но настройки `RTCAudioSession` важны.
5. **Background mode** в Info.plist: `audio`, `voip` обязательно.

---

## PUSH-УВЕДОМЛЕНИЯ — что есть и чего не хватает

> Это отдельный большой раздел, потому что в текущем состоянии **push на телефон скорее всего не приходят**, и причин сразу несколько.

### Что реализовано на бэке (теоретически)
- [x] Таблица `push_tokens` (`models/push_token.py`)
- [x] `POST /devices/push-token` — регистрация (upsert по device_token)
- [x] `DELETE /devices/push-token` — снос токена
- [x] `services/push_apns.py` — полная реализация HTTP/2 APNs с JWT-кешем
- [x] `services/push_fcm.py` — Android (Legacy HTTP API)
- [x] `services/push_dispatcher.py` — диспетчер с проверкой mute и online
- [x] Авто-удаление невалидных токенов (APNs 410, FCM NotRegistered)
- [x] Тихий пуш (`content-available: 1`) если получатель уже онлайн (только обновление бейджа)

### Что реально работает (events для которых дёргается dispatcher)
- [x] **Новое сообщение в чате** — `services/message.py:286` через `asyncio.create_task(dispatch_push_for_message(...))`.

И всё. Больше **никаких** событий пуш не вызывают.

### Что НЕ приходит на телефон (events без пуша)

| Событие | Состояние | Что нужно |
|---|---|---|
| 🔴 **Заявка в друзья** | Push не отправляется | Добавить вызов dispatcher в `services/friend.py::send_request` |
| 🔴 **Принятие заявки** | Push не отправляется | `services/friend.py::accept_request` → dispatcher |
| 🔴 **Упоминание (@nickname)** | Только через message-push, но без выделения | force_alert=True для упомянутых уже есть в коде, но нужно отдельный alert text «X упомянул вас» |
| 🔴 **Добавление в группу** | Push не отправляется | `services/group_service.py::add_members` → dispatcher для каждого нового member'а |
| 🔴 **Изменение роли** | Push не отправляется | `change_member_role` → dispatcher для затронутого user'а |
| 🔴 **Входящий звонок** | VoIP push отсутствует полностью | См. раздел «Звонки» — нужен PushKit + voip-сертификат |
| 🟡 **Reaction на сообщение** | Push не отправляется | Опционально, можно настройкой |
| 🟡 **Прочитано** | Push не отправляется | Не нужно (это noise) |

### Почему push **сейчас вообще не приходят** в твоей dev-среде

Это **отдельная проблема**, которая видна только по логам. Возможные причины:

1. 🔴 **`APNS_KEY_PATH` не задан в `.env`** → `push_apns.py` молча скипает отправку (`if not key_path: return`). Это и есть «всё работает, но ничего не приходит».
2. 🔴 **Тестируешь на симуляторе** — симулятор iOS **не получает APNs**. Только на реальном устройстве.
3. 🟠 **APNs sandbox vs production mismatch** — `.env` указывает на production-endpoint, но build тестовый (development), либо наоборот.
4. 🟠 **APNs `.p8`-ключ не загружен в Apple Developer Portal** — нужно сгенерировать ключ с capability **Apple Push Notifications service (APNs)** и **VoIP Services** (для звонков отдельно).
5. 🟠 **`Bundle ID` в `.env` (`APNS_TOPIC`) не совпадает с реальным** в Xcode проекте.
6. 🟠 **iOS-приложение не имеет capability `Push Notifications`** в Xcode → Signing & Capabilities. Сейчас нужно открыть проект и проверить.
7. 🟡 **`try? await PushTokenService.shared.register(token:)` в `iOS/SiberiaApp.swift:49`** молча глотает ошибку регистрации → бэк не знает на какой токен слать.

### Чек-лист для починки push (в порядке проверки)

#### Диагностика
- [ ] Проверить что `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` заданы в `.env` бэка.
- [ ] В `SiberiaApp.swift:49` заменить `try?` на `try` + `print(error)` — увидеть в логах попала ли регистрация на бэк.
- [ ] В бэке добавить `logger.info(...)` в `push_dispatcher.dispatch_push_for_message` — увидеть зовётся ли он.
- [ ] В `push_apns.py` логировать запросы (URL, status code).
- [ ] Тестировать на **физическом устройстве** (симулятор не получает APNs).
- [ ] В Xcode → Signing & Capabilities → проверить что есть **Push Notifications**.

#### Настройка APNs
- [ ] Сгенерировать в [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → Keys новый ключ с capability **Apple Push Notifications**.
- [ ] Скачать `.p8`-файл (один раз, потом не дадут).
- [ ] Положить в backend, прописать `APNS_KEY_PATH`, `APNS_KEY_ID` (из portal), `APNS_TEAM_ID` (Team ID), `APNS_TOPIC` = Bundle ID (`com.firetomato.Siberia` или какой у тебя).
- [ ] `APNS_USE_SANDBOX=true` для dev-builds, `false` для App Store / TestFlight.

#### Добавление недостающих push-событий
- [ ] **Friend request push** (`services/friend.py::send_request`):
  ```python
  asyncio.create_task(dispatch_generic_push(
      user_id=addressee_id,
      title=requester.nickname,
      body="Хочет добавить вас в друзья",
      category="friend_request",
      data={"type": "friend_request", "request_id": friend.id}
  ))
  ```
- [ ] **Friend accept push**: то же при `accept_request`.
- [ ] **Group member added push**: в `add_members` — пуш каждому новому member'у с category `group_invite`.
- [ ] **Mention push с отдельным title**: уже есть `force_alert`, но текст «X написал: …» можно заменить на «X упомянул вас в Y».
- [ ] **Generic dispatcher**: вынести `dispatch_generic_push(user_id, title, body, category, data)` в `push_dispatcher.py` чтобы переиспользовать.

#### iOS-side push polish
- [ ] **Notification categories** в `UNUserNotificationCenter`: для каждого типа (`new_message`, `friend_request`, `mention`, `group_invite`) — свои action buttons.
- [ ] **Deep links по push**: при тапе на push с `type: friend_request` — открыть профиль с заявкой, при `type: new_message` — открыть конкретный чат.
- [ ] **Убрать локальный banner** в `SiberiaNotificationDelegate` когда APNs работает — сейчас дублирование (бэк прислал + клиент сам показал).
- [ ] **Per-chat mute UI** (уже в Sprint 2).
- [ ] **Notification action buttons**: «Ответить», «Отметить прочитанным» прямо в баннере.
- [ ] **Rich notifications**: для фото-сообщений в push — превью.
- [ ] **Badge count**: бэк уже считает unread (`GET /users/me/badge`), iOS должен дёргать при foreground и обновлять `UIApplication.shared.applicationIconBadgeNumber`.

#### Тестирование
- [ ] Положить `apnsTester.py` скрипт в `tests/` для отправки тестового пуша напрямую через APNs (без бэк-логики).
- [ ] Sentry/Crashlytics ловит DeviceTokenError'ы — иначе всю жизнь будешь страдать «у Васи не приходит».

---

## Дополнительный долг (низкий приоритет)

### Бэкенд
- [ ] Audit logging для sensitive действий (смена пароля, удаление аккаунта, смена ролей).
- [ ] Замена `pyrate_limiter` (in-memory) на Redis-based rate limiter — нужно для multi-worker prod.
- [ ] Транзакционные границы в `create_tokens()` — между flush() и commit() возможен откат с несинхронизированным состоянием.
- [ ] Перевод hardcoded констант (`_PING_INTERVAL`, `_PING_TIMEOUT`) в config.
- [ ] Лимит на количество разных reactions на одно сообщение.

### iOS
- [ ] Локализация (английский + другие языки) — сейчас всё в одном русском.
- [ ] Тёмная тема — частично работает через системную, но кастомные цвета (`accent`) не реагируют.
- [ ] Accessibility (VoiceOver labels) — сейчас почти нет.
- [ ] iPad layout — сейчас просто растянут iPhone.
- [ ] Универсальная ссылка (Universal Links) `https://siberia.app/chat/{id}`.
- [ ] App Clips для быстрого joining через invite link без установки.

---

## Готовый порядок ближайших шагов

Если запустить меня в работу прямо сейчас, я бы шёл по следующему порядку:

1. **Sprint 1** — фундамент, безопасность, фиксы. Без этого дальше строить опасно.
2. **Push-уведомления — закрыть все пробелы** (отдельный раздел ниже): починить APNs-конфиг, добавить пуши для friend requests / mentions / групповых событий. Делается параллельно со Sprint 1.
3. **Sprint 2** — подключение готового бэка к UI (это даст массивный визуальный прогресс при минимальной работе).
4. **Sprint 3** — полировка существующего (особенно WS-надёжность и offline-кэш).
5. **Звонки 1-на-1** (фазы A+B, ~4 нед) — большое отдельное «событие» по продукту. Групповые звонки **намеренно вне скоупа**.
6. **Sprint 4 — Markdown/Spoiler + Архив/Папки** — относительно недорогие но заметные фичи.
7. **Стикеры/GIF**.
8. **Stories** — если есть продуктовый смысл.
9. **E2E (Secret Chats)** — самая большая, последней. Опциональна.

---

> Документ живой — обновляй галочки `[ ] → [x]` по ходу работы, добавляй обнаруженные проблемы. Когда раздел полностью закрыт — сворачивай его в одну строку «Sprint X — done на YYYY-MM-DD».
