# Siberia — план работ (июль 2026)

Текущий план закрытия багов, долгов и фич. Работаем блоками: один блок → коммиты → пуш.
Статусы: `[ ]` не начат · `[~]` в работе · `[x]` готов.

Контекст: Sprint 1–3 из ROADMAP.md закрыты (май 2026). Бэкенд функционально готов,
iOS покрывает большую часть фич. Дальше — блоки ниже.

---

## [x] Блок 0 — Git-фундамент (закрыт 2026-07-04)

- [x] Рабочая копия: клон `fire0clop/siberia`, вся работа и коммиты здесь
- [x] Секреты (`.env`, `secrets/*.p8`) перенесены локально, в git не попадают
- [x] CI перенесён из `backend/Siberia/.github/` в корень репо (иначе GitHub Actions его не видит)
- [x] Деплой-джоба переведена на ручной запуск до настройки secrets
- [x] Зелёный CI: ruff чист, e2e 48/48 (попутно: запинены зависимости —
      fastapi 0.139 ломал fastapi-limiter; исправлен 500 на DELETE /messages —
      tz-naive колонка deleted_at, миграция 017)

## [x] Блок 1 — Безопасность и надёжность бэкенда (закрыт 2026-07-04)

- [x] Сильный `SECRET_KEY` в локальном `.env` + startup-guard: production не стартует
      со слабым/дефолтным ключом (по аналогии с CORS-guard)
- [x] `services/push_apns.py`: ложная тревога — чтение ключа уже обёрнуто try/except
      на обоих вызовах, worker не падает. Бонус: `send_voip()` уже реализован
- [x] `verify_email_code()`: ложная тревога — обе error-ветки заканчиваются raise,
      до `ev.used` с `ev=None` не дойти
- [x] WS-токен через `?token=` отключён в production (только Authorization header)

## [x] Блок 2 — Мелкие баги iOS (закрыт 2026-07-04)

- [x] `APIConfig.swift`: LAN-fallback оставлен только в Debug; в Release — прод-домен
- [x] Force unwrap: `ChatCacheService.swift` (`.first!`), `AuthViewModel.swift` (email `.last!`,
      крэшился на "@"), `MessageNotifications.swift` (`as!`), `APIClient.swift` (`Data(string.utf8)`)
- [x] `print()` → `Log.*` в TokenStorage, CallManager, CallSignaling (15 вызовов);
      Logger помечен `nonisolated` — логирование из WebRTC-делегатов без прыжка на MainActor
- [x] Сборка проверена: xcodebuild build зелёный, 0 новых warnings

## [ ] Блок 3 — Push-уведомления (по чек-листу из ROADMAP)

- [ ] Диагностика: `APNS_KEY_PATH` в `.env`, sandbox vs production, тест на реальном устройстве
- [ ] Пуш на friend request (сейчас нет)
- [ ] Пуш на добавление в группу (сейчас нет)
- [ ] VoIP push для звонков — блокер для Блока 6
- [ ] (опц.) пуш на реакции

## [ ] Блок 4 — Тесты бэкенда + рабочий CI

- [ ] pytest-инфраструктура (conftest, фикстуры БД/Redis) — сейчас юнит-тестов ноль
- [ ] Auth-флоу: регистрация, логин, 2FA, refresh, logout, session revocation
- [ ] Сообщения: дедупликация по `client_message_id`, редактирование, scheduled
- [ ] Sync: инкремент `sync_seq`, конкурентная отправка
- [ ] CI гоняет pytest на каждый пуш

## [ ] Блок 5 — Тесты iOS

- [ ] ⚠️ Таргета SiberiaTests в Xcode-проекте НЕТ: ChatCacheServiceTests.swift (12 тестов)
      лежит на диске, но не подключён и никогда не запускался. Создать test target,
      подключить файл, настроить схему на test action
- [ ] APIClient: refresh-флоу, обработка ошибок, multipart
- [ ] RealtimeSocket: reconnect/backoff, дедупликация
- [ ] AuthViewModel: валидация, 2FA-флоу

## [ ] Блок 6 — Звонки 1-на-1 (текущий фокус ROADMAP)

- [ ] Развернуть coturn (конфиг готов в `backend/deploy/coturn/`), открыть UDP 3478 + relay range
- [ ] Подключить TURN в `CallManager` (сейчас только Google STUN — за NAT звонки не соединятся)
- [ ] Убрать `stubCall` из `AppState` (костыль для VoIP push до WS)
- [ ] Довести фазу A (голос): CallKit end-to-end на реальных устройствах
- [ ] Фаза B (видео): video-track, UI с PiP

## [ ] Блок 7 — Sprint 4: фичи (по одной, в этом порядке)

- [ ] Markdown / text entities (bold, italic, code, spoiler)
- [ ] Архив и папки чатов
- [ ] Стикеры и GIF
- [ ] Link preview (OG-теги через ARQ worker)
- [ ] Stories (если будет продуктовый смысл)
- [ ] E2E-шифрование Secret Chats (самая большая, последней)

## [ ] Блок 8 — Полировка и долг

- [ ] Локализация (сейчас всё по-русски)
- [ ] Тёмная тема (частично работает)
- [ ] Accessibility / VoiceOver
- [ ] iPad layout
- [ ] Audit logging на бэке, Redis-based rate limiter (для multi-worker)
