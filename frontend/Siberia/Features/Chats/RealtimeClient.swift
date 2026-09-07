import Foundation

/// Один клиент WebSocket: комната `/ws/me` или `/ws/{chatId}`.
///
/// Возможности:
/// - Авторизация через заголовок `Authorization: Bearer …` (не оставляет токен в URL-логах).
/// - Auto-reconnect с exponential backoff (2, 4, 8, 16, 32 → cap 30 секунд);
///   backoff сбрасывается после первого живого кадра, а не только при connect().
/// - Перед повторными попытками дёргает дешёвый authed-запрос через APIClient,
///   чтобы 401 → refresh-флоу обновил протухший access-токен (иначе сокет
///   вечно ретраил рукопожатие с мёртвым токеном).
/// - `ensureConnected()` — для возврата из фона: живой сокет проверяется ping'ом,
///   мёртвый переоткрывается сразу, без ожидания хвоста backoff'а.
/// - Callback `onReconnect` — вызывается при переустановлении соединения,
///   используется для sync-gap-recovery (`/chats/{id}/sync?after_seq=N`).
/// - Корректная обработка JSON-ping от сервера `{"type":"ping"}` → `{"type":"pong"}`.
actor RealtimeSocket {
	private var task: URLSessionWebSocketTask?
	private var receiveLoop: Task<Void, Never>?
	private var reconnectTask: Task<Void, Never>?

	private var currentPath: String?
	private var currentOnText: (@Sendable (String) -> Void)?
	private var currentOnReconnect: (@Sendable () -> Void)?

	private var attempt: Int = 0
	private var manualDisconnect: Bool = false
	/// Поколение соединения: каждый openSocket/disconnect его инкрементирует.
	/// Старый receive-loop, доживающий после отмены, сверяет поколение и не
	/// трогает reconnect — раньше он вызывал scheduleReconnect() безусловно
	/// и через 2 секунды сносил свежеоткрытый сокет.
	private var generation: Int = 0

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
		guard let task else {
			// Сокета нет — молчаливая потеря кадра недопустима для звонков
			throw URLError(.networkConnectionLost)
		}
		try await task.send(.string(s))
	}

	func disconnect() async {
		manualDisconnect = true
		generation += 1
		reconnectTask?.cancel(); reconnectTask = nil
		receiveLoop?.cancel(); receiveLoop = nil
		task?.cancel(with: .goingAway, reason: nil); task = nil
		currentPath = nil
		currentOnText = nil
		currentOnReconnect = nil
		attempt = 0
	}

	/// Возврат из фона / пинок извне: живой сокет подтверждаем ping'ом,
	/// мёртвый — переоткрываем немедленно (сбросив backoff).
	func ensureConnected() async {
		guard !manualDisconnect, currentPath != nil else { return }
		guard let t = task else {
			attempt = 0
			reconnectTask?.cancel(); reconnectTask = nil
			await openSocket(isReconnect: true)
			return
		}
		let alive = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
			t.sendPing { error in cont.resume(returning: error == nil) }
		}
		if !alive {
			attempt = 0
			reconnectTask?.cancel(); reconnectTask = nil
			await openSocket(isReconnect: true)
		}
	}

	// MARK: – Connection management

	private func openSocket(isReconnect: Bool) async {
		guard let path = currentPath else { return }

		// Close existing without resetting manualDisconnect flag
		generation += 1
		let myGeneration = generation
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
					// Живой кадр — соединение реально работает, сбрасываем backoff
					await self?.noteFrameReceived(generation: myGeneration)
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
			// Отменённый (устаревший) loop не должен планировать reconnect:
			// это roulette сносила свежий сокет через 2 секунды после reconnectMeSocket()
			if Task.isCancelled { return }
			await self?.scheduleReconnect(fromGeneration: myGeneration)
		}
	}

	private func noteFrameReceived(generation gen: Int) {
		guard gen == generation else { return }
		attempt = 0
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

	private func scheduleReconnect(fromGeneration gen: Int) async {
		guard gen == generation else { return }  // устаревший loop — игнор
		guard !manualDisconnect, currentPath != nil else { return }
		attempt += 1
		// 2, 4, 8, 16, 32 sec — cap 30, плюс jitter чтобы клиенты не били сервер синхронно
		let exp = min(attempt, 5)
		let delaySec = min(30.0, pow(2.0, Double(exp))) * Double.random(in: 0.8...1.2)
		let needTokenNudge = attempt >= 2

		reconnectTask?.cancel()
		reconnectTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
			if Task.isCancelled { return }
			if needTokenNudge {
				// Рукопожатие могло падать из-за протухшего access-токена: WS сам
				// не рефрешит. Дешёвый authed-запрос прогоняет 401 → refresh-флоу
				// APIClient, и следующая попытка идёт уже со свежим токеном.
				await Task { @MainActor in
					_ = try? await APIClient.shared.request(path: "/users/me/badge", method: "GET")
				}.value
				if Task.isCancelled { return }
			}
			await self?.openSocket(isReconnect: true)
		}
	}
}
