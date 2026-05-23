# Siberia — iOS Frontend

Swift/SwiftUI мессенджер. Реализует чаты, друзей, каналы и real-time уведомления поверх FastAPI-бэкенда.

---

## Содержание

1. [Обзор архитектуры](#1-обзор-архитектуры)
2. [Экраны и навигация](#2-экраны-и-навигация)
3. [Слои приложения](#3-слои-приложения)
4. [Сетевой слой и токены](#4-сетевой-слой-и-токены)
5. [Real-time: WebSocket](#5-real-time-websocket)
6. [Push-уведомления](#6-push-уведомления)
7. [Маппинг экранов на эндпоинты](#7-маппинг-экранов-на-эндпоинты)
8. [Модели данных](#8-модели-данных)
9. [Запуск и конфигурация](#9-запуск-и-конфигурация)

---

## 1. Обзор архитектуры

**Паттерн: MVVM + Singleton Services**

```
SiberiaApp (точка входа)
    │
    ├── AppState (@StateObject, глобальное состояние)
    │       ├── isAuthenticated → AuthView или MainView
    │       ├── currentUser
    │       └── /ws/me WebSocket (глобальные события)
    │
    ├── AuthView  (показывается при isAuthenticated == false)
    │
    └── MainView  (показывается при isAuthenticated == true)
            ├── Tab 1: ChatsView → ChatDetailView
            ├── Tab 2: AddFriendView
            └── Tab 3: ProfileView
```

**Стек технологий:**

| Область         | Решение                                      |
|-----------------|----------------------------------------------|
| UI              | SwiftUI                                      |
| Многопоточность | async/await, Actor                           |
| HTTP            | URLSession + кастомный `APIClient`           |
| WebSocket       | URLSessionWebSocketTask (`RealtimeClient`)   |
| Токены          | UserDefaults (`TokenStorage`)                |
| Device ID       | UUID, сохранённый в UserDefaults             |
| Уведомления     | UserNotifications framework                  |

---

## 2. Экраны и навигация

### 2.1 Auth Flow

```
Запуск приложения
    │
    ├─ Есть accessToken → checkAuth() → isAuthenticated = true → MainView
    └─ Нет токена / токен протух → AuthView
```

**AuthView** — единый экран с переключением Login / Register.

| Режим    | Поля                            | Действие                    |
|----------|---------------------------------|-----------------------------|
| Login    | Email, Password                 | `POST /auth/login`          |
| Register | Nickname, Email, Password       | `POST /auth/register`       |

После успешной аутентификации:
1. Токены сохраняются в `TokenStorage`
2. `AppState.setAuthenticatedAndBootstrap()` — подключает `/ws/me`, запрашивает профиль, запрашивает разрешение на уведомления
3. Показывается `MainView`

---

### 2.2 Main Flow (TabView)

После логина пользователь попадает в `MainView` с тремя вкладками:

```
MainView (TabView)
├── Вкладка 1: Чаты (ChatsView)
├── Вкладка 2: Друзья (AddFriendView)
└── Вкладка 3: Профиль (ProfileView)
```

---

### 2.3 ChatsView — Список чатов

- Загружает список чатов: `GET /chats`
- Показывает: название чата, последнее сообщение, время
- При тапе на чат — переход в `ChatDetailView` через NavigationLink с `ChatRoute(chatId, title, syncSeq)`
- Обновляется по `NotificationCenter` событию `.siberiaChatsShouldReload` (срабатывает при получении нового сообщения через `/ws/me`)
- Кнопка создания чата → `POST /chats`

---

### 2.4 ChatDetailView — Чат

Основной экран приложения.

**Функции:**
- Список сообщений (прокрутка снизу вверх)
- Отправка текстового сообщения с `client_message_id` (идемпотентность)
- Редактирование своего сообщения (`PATCH /chats/{id}/messages/{msgId}`)
- Удаление своего сообщения (`DELETE /chats/{id}/messages/{msgId}`)
- Ответ на сообщение (`reply_to_message_id`)
- Live-обновления через WebSocket `/ws/{chatId}`
- Синхронизация истории через `GET /chats/{id}/sync?after_seq={syncSeq}`

**Жизненный цикл:**
```
onAppear
    → connect RealtimeClient to /ws/{chatId}
    → load initial messages: GET /chats/{id}/messages
    → set ActiveChatTracker.shared.activeChatId = chatId

onDisappear
    → disconnect RealtimeClient
    → ActiveChatTracker.shared.activeChatId = nil
```

---

### 2.5 AddFriendView — Друзья и поиск

- Поиск пользователей: `GET /users/search?q={query}`
- Отправка запроса в друзья: `POST /friends`
- Список входящих запросов: `GET /friends/requests`
- Принять запрос: `POST /friends/{id}/accept`
- Список друзей: `GET /friends`
- Тап на друга → создать приватный чат: `POST /chats`

---

### 2.6 ProfileView — Профиль и настройки

- Профиль текущего пользователя: `GET /users/me`
- Список активных сессий: `GET /sessions`
- Завершить сессию: `DELETE /sessions/{id}`
- Завершить все остальные сессии: `DELETE /sessions/all-other`
- Выход: `POST /auth/logout` → очистка токенов → `AppState.logout()` → AuthView

---

## 3. Слои приложения

### 3.1 Core/Config

**`APIConfig.swift`** — единственное место, где задаётся адрес бэкенда.

```swift
static let baseURL = "http://192.168.1.134:8000"

// WebSocket URL (автоматически ws:// или wss://)
static var wsBaseURL: String {
    baseURL
        .replacingOccurrences(of: "https://", with: "wss://")
        .replacingOccurrences(of: "http://", with: "ws://")
}
```

> При смене адреса бэкенда меняйте только `baseURL` в этом файле.

---

### 3.2 Core/Network

**`APIClient.swift`** — HTTP клиент (Singleton).

Ключевые возможности:
- Автоматически добавляет `Authorization: Bearer {accessToken}`
- При получении `HTTP 401` запускает рефреш через `RefreshGate` (actor, предотвращает параллельные рефреши)
- После рефреша повторяет исходный запрос
- Если рефреш тоже вернул 401 — бросает `.refreshFailed`, `AppState.logout()` вызывается из VM
- Автоматически кодирует тело запроса в JSON с `snake_case` ключами (Swift camelCase → Python snake_case)
- Декодирует ответ через `JSONDecoder` с `convertFromSnakeCase`

**`APIError.swift`** — типы ошибок:

```swift
enum APIClientError: Error {
    case httpStatus(Int, message: String?)   // например 400, 404, 409
    case decoding(Error)
    case noData
    case refreshFailed                       // "Сессия истекла"
}
```

---

### 3.3 Core/Storage

**`TokenStorage.swift`** — хранит access и refresh токены.

```swift
TokenStorage.shared.accessToken  // get/set
TokenStorage.shared.refreshToken // get/set
TokenStorage.shared.clear()      // logout
```

> Хранение в UserDefaults. Для production следует перенести в Keychain.

**`DeviceIDStorage.swift`** — стабильный UUID устройства.

```swift
DeviceIDStorage.shared.deviceId  // UUID, генерируется один раз и сохраняется
```

Используется в:
- `POST /auth/register` — поле `device_id`
- `POST /auth/login` — поле `device_id`
- `POST /auth/refresh` — заголовок `X-Device-ID`

---

### 3.4 AppState

`AppState` — главный оркестратор приложения (`@MainActor ObservableObject`).

```swift
@Published var isAuthenticated: Bool
@Published var currentUser: User?
```

**Методы:**

| Метод                         | Когда вызывается                        | Что делает                                         |
|-------------------------------|-----------------------------------------|----------------------------------------------------|
| `checkAuth()`                 | Старт приложения                        | Проверяет наличие токена, устанавливает состояние  |
| `bootstrapAfterAuth()`        | После логина/регистрации                | Подключает `/ws/me`, загружает профиль, запрашивает разрешение на push |
| `setAuthenticatedAndBootstrap()` | AuthViewModel после успешного входа | Устанавливает `isAuthenticated = true` + bootstrap |
| `logout()`                    | ProfileView, рефреш провалился          | Очищает токены, отключает сокет, сбрасывает состояние |

**WebSocket `/ws/me`:**

AppState держит постоянное соединение с `/ws/me` пока пользователь авторизован. Слушает события:
- `message_new` — показывает локальное уведомление + постит `.siberiaChatsShouldReload`

---

### 3.5 Services

Сервисы — singleton-классы, каждый отвечает за один домен.

| Сервис           | Файл                  | Ответственность                                   |
|------------------|-----------------------|---------------------------------------------------|
| `AuthService`    | Auth/AuthService.swift | login, register, logout + сохранение токенов     |
| `ChatService`    | Chats/ChatService.swift | CRUD чатов, сообщений, поиск, sync               |
| `UserService`    | Friends/UserService.swift | me(), searchUsers()                            |
| `FriendService`  | Friends/FriendService.swift | getFriends, addFriend, accept, requests      |
| `SessionService` | Profile/SessionService.swift | listSessions, revokeSession, revokeAll      |

---

### 3.6 ViewModels

| ViewModel             | Файл                          | Экран                |
|-----------------------|-------------------------------|----------------------|
| `AuthViewModel`       | Auth/AuthViewModel.swift      | AuthView             |
| `ChatDetailViewModel` | Chats/ChatDetailViewModel.swift | ChatDetailView     |

`ChatsView`, `AddFriendView`, `ProfileView` — используют сервисы напрямую или имеют встроенный `@State`.

---

## 4. Сетевой слой и токены

### 4.1 Заголовки

Каждый авторизованный запрос содержит:

```
Authorization: Bearer {accessToken}
```

При регистрации и логине дополнительно:
```
X-Device-ID: {deviceId}
```

### 4.2 Жизненный цикл токенов

```
Запрос → 401 → POST /auth/refresh (refreshToken + X-Device-ID)
                    ├── 200 → сохранить новые токены → повторить запрос
                    └── 401 → refreshFailed → AppState.logout() → AuthView
```

Endpoint рефреша:
```
POST /auth/refresh
Body: { "refresh_token": "...", "device_id": "..." }
Response: { "access_token": "...", "refresh_token": "...", "token_type": "bearer" }
```

### 4.3 Client Message ID (идемпотентность)

При отправке сообщения генерируется `UUID` и передаётся как `client_message_id`. Если запрос дублируется (retry), бэкенд вернёт уже существующее сообщение вместо создания дубликата.

---

## 5. Real-time: WebSocket

### 5.1 Два WebSocket соединения

| Соединение         | URL              | Кто держит              | Назначение                                        |
|--------------------|------------------|-------------------------|---------------------------------------------------|
| Глобальное         | `/ws/me`         | `AppState`              | Новые сообщения во всех чатах, список чатов       |
| Чат-специфичное    | `/ws/{chatId}`   | `ChatDetailViewModel`   | Live-обновления внутри открытого чата             |

### 5.2 Аутентификация WebSocket

Токен передаётся через query-параметр:

```
ws://192.168.1.134:8000/ws/me?token={accessToken}
ws://192.168.1.134:8000/ws/{chatId}?token={accessToken}
```

### 5.3 Ping/Pong

Сервер шлёт `ping` каждые 25 секунд. Клиент (`RealtimeClient`) отвечает `pong`. При потере соединения — переподключение.

### 5.4 Формат событий от сервера

Все события — JSON с полем `type`:

#### message_new
```json
{
  "type": "message_new",
  "chat_id": 42,
  "message": {
    "id": 1001,
    "chat_id": 42,
    "user_id": 7,
    "text": "Привет!",
    "created_at": "2026-04-19T12:00:00Z",
    "client_message_id": "uuid",
    "reply_to_message_id": null,
    "edited_at": null,
    "deleted_at": null
  }
}
```

#### message_edit
```json
{
  "type": "message_edit",
  "chat_id": 42,
  "message": { ...обновлённое сообщение... }
}
```

#### message_delete
```json
{
  "type": "message_delete",
  "chat_id": 42,
  "message_id": 1001
}
```

#### read_receipt
```json
{
  "type": "read_receipt",
  "chat_id": 42,
  "user_id": 7,
  "message_id": 1001
}
```

#### reaction_update
```json
{
  "type": "reaction_update",
  "chat_id": 42,
  "message_id": 1001,
  "emoji": "👍",
  "user_id": 7,
  "action": "add"
}
```

#### Системные события группового чата
```json
{ "type": "member_added",   "chat_id": 42, "user_id": 15 }
{ "type": "member_removed", "chat_id": 42, "user_id": 15 }
{ "type": "member_left",    "chat_id": 42, "user_id": 15 }
{ "type": "chat_updated",   "chat_id": 42, "title": "Новое название" }
{ "type": "role_changed",   "chat_id": 42, "user_id": 15, "role": "admin" }
{ "type": "message_pinned", "chat_id": 42, "message_id": 1001 }
```

### 5.5 Сообщения от клиента (send)

`RealtimeClient.send()` — отправка произвольного JSON через WebSocket (например, typing indicator, если будет добавлен).

### 5.6 Sync API (резервный механизм)

Если WebSocket был разорван, при переподключении `ChatDetailViewModel` вызывает:

```
GET /chats/{chatId}/sync?after_seq={lastKnownSyncSeq}
```

Возвращает пропущенные события в порядке `seq`. Клиент применяет их к локальному массиву сообщений.

---

## 6. Push-уведомления

### 6.1 Разрешение и регистрация

При `bootstrapAfterAuth()`:
1. `MessageNotifications.requestAuthorizationIfNeeded()` — запрашивает `.alert + .sound + .badge`
2. Если разрешено — `UIApplication.shared.registerForRemoteNotifications()`
3. В `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken` — отправить APNs-токен на бэкенд:

```
POST /devices/push-token
Authorization: Bearer {accessToken}
Body: {
  "token": "{apnsHexToken}",
  "platform": "apns"
}
```

### 6.2 Локальные уведомления

`MessageNotifications.notifyNewMessageIfNeeded(message:chatTitle:)` показывает локальное уведомление, если:
- Сообщение не от текущего пользователя
- Открыт другой чат (`ActiveChatTracker.shared.activeChatId != message.chatId`)

Уведомление группируется по `threadIdentifier: "chat-{chatId}"`.

### 6.3 SiberiaNotificationDelegate

Настроен на показ баннера даже когда приложение в foreground (`willPresent` → `.banner + .list + .sound`).

---

## 7. Маппинг экранов на эндпоинты

### Auth

| Действие               | Метод | Эндпоинт           |
|------------------------|-------|--------------------|
| Регистрация            | POST  | `/auth/register`   |
| Вход                   | POST  | `/auth/login`      |
| Рефреш токена          | POST  | `/auth/refresh`    |
| Выход                  | POST  | `/auth/logout`     |

### Профиль и сессии

| Действие                    | Метод  | Эндпоинт                    |
|-----------------------------|--------|-----------------------------|
| Мой профиль                 | GET    | `/users/me`                 |
| Список сессий               | GET    | `/sessions`                 |
| Завершить сессию            | DELETE | `/sessions/{id}`            |
| Завершить все другие        | DELETE | `/sessions/all-other`       |

### Друзья

| Действие                    | Метод | Эндпоинт                    |
|-----------------------------|-------|-----------------------------|
| Поиск пользователей         | GET   | `/users/search?q={query}`   |
| Список друзей               | GET   | `/friends`                  |
| Входящие запросы            | GET   | `/friends/requests`         |
| Отправить запрос            | POST  | `/friends`                  |
| Принять запрос              | POST  | `/friends/{id}/accept`      |

### Чаты

| Действие                    | Метод  | Эндпоинт                            |
|-----------------------------|--------|-------------------------------------|
| Список чатов                | GET    | `/chats`                            |
| Создать чат                 | POST   | `/chats`                            |
| Детали чата                 | GET    | `/chats/{id}`                       |
| Обновить чат                | PATCH  | `/chats/{id}`                       |
| Удалить чат                 | DELETE | `/chats/{id}`                       |
| Участники чата              | GET    | `/chats/{id}/members`               |
| Добавить участника          | POST   | `/chats/{id}/members`               |
| Удалить участника           | DELETE | `/chats/{id}/members/{userId}`      |
| Выйти из чата               | POST   | `/chats/{id}/leave`                 |
| Синхронизация событий       | GET    | `/chats/{id}/sync?after_seq={seq}`  |

### Сообщения

| Действие                    | Метод  | Эндпоинт                                    |
|-----------------------------|--------|---------------------------------------------|
| История сообщений           | GET    | `/chats/{id}/messages`                      |
| Отправить сообщение         | POST   | `/chats/{id}/messages`                      |
| Редактировать сообщение     | PATCH  | `/chats/{id}/messages/{msgId}`              |
| Удалить сообщение           | DELETE | `/chats/{id}/messages/{msgId}`              |
| Поиск сообщений             | GET    | `/chats/{id}/messages/search?q={query}`     |

### Push-устройства

| Действие                    | Метод  | Эндпоинт                  |
|-----------------------------|--------|---------------------------|
| Зарегистрировать APNs токен | POST   | `/devices/push-token`     |

### WebSocket

| Соединение           | URL                              |
|----------------------|----------------------------------|
| Глобальный фид       | `ws://.../ws/me?token={token}`   |
| Чат-специфичный      | `ws://.../ws/{chatId}?token={token}` |

---

## 8. Модели данных

Модели объявлены в `Features/Auth/AuthModels.swift` (используются по всему приложению).

### User
```swift
struct User: Codable {
    let id: Int
    let publicId: String?
    let email: String
    let nickname: String
    let createdAt: String
}
```

### AuthResponse
```swift
struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let user: User
}
```

### ChatSummary
```swift
struct ChatSummary: Codable {
    let id: Int
    let title: String?
    let syncSeq: Int
    let lastMessage: ChatMessage?
    let createdAt: String
}
```

### ChatMessage
```swift
struct ChatMessage: Codable {
    let id: Int
    let chatId: Int
    let userId: Int
    let text: String?
    let clientMessageId: String?
    let replyToMessageId: Int?
    let createdAt: String
    let editedAt: String?
    let deletedAt: String?
}
```

### MessageSendBody
```swift
struct MessageSendBody: Codable {
    let text: String
    let clientMessageId: String      // UUID
    let replyToMessageId: Int?
}
```

### CreateChatBody
```swift
struct CreateChatBody: Codable {
    let title: String?
    let memberIds: [Int]             // ID участников
    let type: String                 // "private" | "group"
}
```

### FriendRequestItem
```swift
struct FriendRequestItem: Codable {
    let id: Int
    let requesterId: Int
    let addresseeId: Int
    let status: String               // "pending" | "accepted" | "rejected"
}
```

---

## 9. Запуск и конфигурация

### 9.1 Требования

- Xcode 15+
- iOS 17+ (deployment target)
- Запущенный бэкенд (см. Backend/README.md)

### 9.2 Конфигурация адреса бэкенда

Откройте `Core/Config/APIConfig.swift` и укажите адрес бэкенда:

```swift
static let baseURL = "http://192.168.1.134:8000"
```

**Варианты:**
- Локально (симулятор): `http://127.0.0.1:8000`
- На реальном устройстве: IP-адрес компьютера в локальной сети (`192.168.x.x:8000`)
- Продакшн: HTTPS URL (`https://api.siberia.app`)

> При использовании HTTP на реальном устройстве убедитесь, что в `Info.plist` прописан `NSAppTransportSecurity` с `NSAllowsArbitraryLoads: true` (для разработки).

### 9.3 Запуск бэкенда (Docker)

```bash
cd Backend/Siberia
docker compose up -d
# API доступно на http://localhost:8000
# Swagger UI: http://localhost:8000/docs
```

### 9.4 Сборка iOS-приложения

1. Откройте `Siberia 2/Siberia.xcodeproj` в Xcode
2. Выберите таргет `Siberia` и симулятор или устройство
3. `Cmd+R` — сборка и запуск

### 9.5 Структура проекта

```
Siberia/
├── SiberiaApp.swift              # @main, AppState, NotificationDelegate
├── App/
│   └── AppState.swift            # Глобальное состояние, /ws/me
├── Core/
│   ├── Config/APIConfig.swift    # ← baseURL здесь
│   ├── Network/
│   │   ├── APIClient.swift       # HTTP + auto-refresh
│   │   └── APIError.swift        # Типы ошибок
│   ├── Storage/
│   │   ├── TokenStorage.swift    # access/refresh токены
│   │   └── DeviceIDStorage.swift # UUID устройства
│   └── Notifications/
│       ├── SiberiaNotifications.swift
│       ├── MessageNotifications.swift
│       └── ActiveChatTracker.swift
└── Features/
    ├── Auth/
    │   ├── AuthModels.swift      # Все Codable модели
    │   ├── AuthService.swift
    │   ├── AuthViewModel.swift
    │   └── AuthView.swift
    ├── Chats/
    │   ├── ChatService.swift
    │   ├── RealtimeClient.swift  # WebSocket actor
    │   ├── ChatDetailViewModel.swift
    │   ├── ChatDetailView.swift
    │   ├── ChatsView.swift
    │   └── ChatRoute.swift
    ├── Friends/
    │   ├── UserService.swift
    │   ├── FriendService.swift
    │   └── AddFriendView.swift
    ├── Main/
    │   └── MainView.swift        # TabView
    └── Profile/
        ├── SessionService.swift
        └── ProfileView.swift
```
