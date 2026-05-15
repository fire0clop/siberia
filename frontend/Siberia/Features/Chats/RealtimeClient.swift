import Foundation

/// Один клиент WebSocket: комната `/ws/me` или `/ws/{chatId}`.
///
/// Возможности:
/// - Авторизация через заголовок `Authorization: Bearer …` (не оставляет токен в URL-логах).
/// - Auto-reconnect с exponential backoff (2, 4, 8, 16, 32 → cap 30 секунд).
/// - Callback `onReconnect` — вызывается при успешном переустановлении соединения,
///   используется для запроса sync-gap-recovery (`/chats/{id}/sync?after_seq=N`).
/// - Корректная обработка JSON-ping от сервера `{"type":"ping"}` → отвечает `{"type":"pong"}`.
actor RealtimeSocket {
	private var task: URLSessionWebSocketTask?
	private var receiveLoop: Task<Void, Never>?
	private var reconnectTask: Task<Void, Never>?

	private var currentPath: String?
	private var currentOnText: (@Sendable (String) -> Void)?
	private var currentOnReconnect: (@Sendable () -> Void)?

	private var attempt: Int = 0
	private var manualDisconnect: Bool = false

	// MARK: – Public API

	func connect(
		path: String,
		onText: @escaping @Sendable (String) -> Void,
		onReconnect: (@Sendable () -> Void)? = nil
	) async {
		manualDisconnect = false
		currentPath = path
		currentOnText = onText
		currentOnReconnect = onReconnect
		attempt = 0
		await openSocket(isReconnect: false)
	}

	func send(json: [String: Any]) async throws {
		let data = try JSONSerialization.data(withJSONObject: json)
		guard let s = String(data: data, encoding: .utf8) else { return }
		try await task?.send(.string(s))
	}

	func disconnect() async {
		manualDisconnect = true
		reconnectTask?.cancel(); reconnectTask = nil
		receiveLoop?.cancel(); receiveLoop = nil
		task?.cancel(with: .goingAway, reason: nil); task = nil
		currentPath = nil
		currentOnText = nil
		currentOnReconnect = nil
		attempt = 0
	}

	// MARK: – Connection management

	private func openSocket(isReconnect: Bool) async {
		guard let path = currentPath else { return }

		// Close existing without resetting manualDisconnect flag
		receiveLoop?.cancel(); receiveLoop = nil
		task?.cancel(with: .goingAway, reason: nil); task = nil

		guard let token = TokenStorage.shared.accessToken, !token.isEmpty else { return }

		let full = APIConfig.wsBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
		guard let url = URL(string: full) else { return }

		var req = URLRequest(url: url)
		// Header-based auth — токен не попадает в URL-логи прокси
		req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

		let t = URLSession.shared.webSocketTask(with: req)
		task = t
		t.resume()

		if isReconnect, let cb = currentOnReconnect {
			cb()
		}

		let current = t
		receiveLoop = Task { [weak self] in
			while !Task.isCancelled {
				do {
					let msg = try await current.receive()
					if Task.isCancelled { break }
					switch msg {
					case .string(let s):
						await self?.handleFrame(s)
					case .data(let d):
						if let s = String(data: d, encoding: .utf8) {
							await self?.handleFrame(s)
						}
					@unknown default: break
					}
				} catch {
					break
				}
			}
			await self?.scheduleReconnect()
		}
	}

	private func handleFrame(_ s: String) async {
		// Server ping: {"type":"ping"} → нужно ответить {"type":"pong"}
		if let data = s.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   obj["type"] as? String == "ping" {
			try? await task?.send(.string(#"{"type":"pong"}"#))
			return
		}
		currentOnText?(s)
	}

	private func scheduleReconnect() async {
		guard !manualDisconnect, currentPath != nil else { return }
		attempt += 1
		// 2, 4, 8, 16, 32 sec — cap 30
		let exp = min(attempt, 5)
		let delaySec = min(30.0, pow(2.0, Double(exp)))

		reconnectTask?.cancel()
		reconnectTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
			if Task.isCancelled { return }
			await self?.openSocket(isReconnect: true)
		}
	}
}
