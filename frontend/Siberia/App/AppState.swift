import Foundation
import Combine
import CallKit

@MainActor
final class AppState: ObservableObject {

	/// Глобальный singleton — нужен PushKit/CallKit обработчикам, которые
	/// существуют вне SwiftUI-графа и не могут получить @EnvironmentObject.
	static private(set) weak var shared: AppState?

	@Published var isAuthenticated: Bool = false
	@Published var currentUser: User?

	/// Глобальный набор user_id, которые сейчас онлайн.
	@Published var onlineUserIds: Set<Int> = []

	// MARK: – Звонки (глобально, поверх любого экрана)
	@Published var incomingCall: IncomingCallInfo?
	@Published var activeCall: ActiveCall?
	@Published var callManager: CallManager?
	@Published var callError: String?   // показывается алертом — диагностика

	/// Информация о входящем звонке, полученная из VoIP-пуша ДО того как
	/// прилетит детализированный call_incoming через WS. Нужно потому что VoIP
	/// push приходит на убитое/фоновое приложение раньше чем WS успеет коннектиться.
	struct PendingIncoming {
		let callId: Int
		let callerId: Int
		let callerName: String
		let callerAvatar: String?
		let type: CallType
	}
	var pendingIncoming: PendingIncoming?

	let callSignaling = CallSignaling()

	private let meSocket = RealtimeSocket()

	init() {
		Self.shared = self
		// Сигналинг отдаёт фреймы наружу через AppState'овский сокет
		callSignaling.sender = { [weak self] frame in
			await self?.sendOverMe(json: frame)
		}
		checkAuth()
	}

	// MARK: – Auth bootstrap

	func checkAuth() {
		if TokenStorage.shared.accessToken != nil {
			isAuthenticated = true
			Task { await bootstrapAfterAuth() }
		}
	}

	func bootstrapAfterAuth() async {
		await reconnectMeSocket()
		do {
			currentUser = try await UserService.shared.me()
		} catch {
			currentUser = nil
		}
		await MessageNotifications.requestAuthorizationIfNeeded()
	}

	func reconnectMeSocket() async {
		await meSocket.disconnect()
		guard isAuthenticated else { return }
		await meSocket.connect(
			path: "/ws/me",
			onText: { [weak self] text in
				Task { @MainActor [weak self] in
					self?.handleMeWebSocketText(text)
				}
			},
			onReconnect: {
				Task { @MainActor in
					NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
				}
			}
		)
	}

	/// Отправить произвольный JSON через /ws/me (используется сигналингом звонков).
	func sendOverMe(json: [String: Any]) async {
		do {
			try await meSocket.send(json: json)
		} catch {
			Log.calls.error("WS send failed: \(String(describing: error))")
		}
	}

	// MARK: – WS frame router

	private func handleMeWebSocketText(_ text: String) {
		guard
			let data = text.data(using: .utf8),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return }

		let eventType = (obj["type"] as? String) ?? (obj["event"] as? String) ?? ""

		switch eventType {
		case "presence_change":
			handlePresenceChange(obj)
			return
		case "call_incoming":
			handleIncomingCall(obj)
			return
		case "call_accepted":
			handleCallAccepted(obj)
			return
		case "call_declined", "call_cancelled", "call_ended":
			handleCallTerminated(obj)
			return
		case "call_signal":
			Task { await callSignaling.handleIncomingSignal(obj) }
			return
		case "message_new":
			handleMessageNew(obj)
			return
		default:
			NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
		}
	}

	// MARK: – Presence

	private func handlePresenceChange(_ obj: [String: Any]) {
		let payload = (obj["payload"] as? [String: Any]) ?? obj
		guard let uid = intFromJSON(payload["user_id"]) else { return }
		let online = (payload["online"] as? Bool) ?? false
		if online { onlineUserIds.insert(uid) } else { onlineUserIds.remove(uid) }

		var info: [AnyHashable: Any] = ["user_id": uid, "online": online]
		if let ls = payload["last_seen_at"] as? String { info["last_seen_at"] = ls }
		NotificationCenter.default.post(name: .siberiaPresenceChange, object: nil, userInfo: info)
	}

	// MARK: – Message_new

	private func handleMessageNew(_ obj: [String: Any]) {
		let msgObj = (obj["message"] as? [String: Any]) ?? obj
		let payloadObj = (obj["payload"] as? [String: Any]) ?? msgObj
		guard
			let chatId = intFromJSON(obj["chat_id"]),
			let messageId = intFromJSON(msgObj["id"]) ?? intFromJSON(obj["message_id"]),
			let fromUid = intFromJSON(payloadObj["user_id"]) ?? intFromJSON(msgObj["user_id"])
		else {
			NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
			return
		}
		let preview = (payloadObj["text"] as? String) ?? (msgObj["text"] as? String)
		MessageNotifications.notifyNewMessageIfNeeded(
			chatId: chatId,
			messageId: messageId,
			senderUserId: fromUid,
			text: preview,
			currentUserId: currentUser?.id
		)
		NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
	}

	// MARK: – Calls — incoming / accepted / terminated

	private func handleIncomingCall(_ obj: [String: Any]) {
		guard
			let callObj   = obj["call"]   as? [String: Any],
			let callerObj = obj["caller"] as? [String: Any]
		else { return }
		guard
			let callData = try? JSONSerialization.data(withJSONObject: callObj),
			let call = try? decoder.decode(Call.self, from: callData),
			let callerData = try? JSONSerialization.data(withJSONObject: callerObj),
			let caller = try? decoder.decode(User.self, from: callerData)
		else { return }

		// Если уже в активном звонке — отклоняем автоматически (busy)
		if activeCall != nil {
			Task { try? await CallService.shared.decline(callId: call.id) }
			return
		}

		// Запоминаем что это за звонок (на случай если CallKit screen уже показан VoIP-пушем)
		incomingCall = IncomingCallInfo(call: call, caller: caller)
		pendingIncoming = PendingIncoming(
			callId: call.id, callerId: caller.id,
			callerName: caller.nickname, callerAvatar: caller.avatarUrl,
			type: call.type
		)

		// Если CallKit ещё не показывал экран (например VoIP push не дошёл) — попросим его
		CallKitManager.shared.reportIncoming(
			callId: call.id,
			callerName: caller.nickname,
			hasVideo: call.type == .video
		)
	}

	// MARK: – Calls — VoIP push integration

	/// Вызывается из VoIPPushManager после того как push залетел И мы сразу
	/// зарепортили в CallKit. Сохраняем контекст — он понадобится когда юзер
	/// нажмёт Accept на системном экране звонка.
	func prepareIncomingFromVoIPPush(
		callId: Int, callerId: Int, callerName: String,
		callerAvatar: String?, type: CallType
	) {
		pendingIncoming = PendingIncoming(
			callId: callId, callerId: callerId,
			callerName: callerName, callerAvatar: callerAvatar,
			type: type
		)
		// Если пользователь авторизован но WS ещё не подключён (например приложение
		// было убито) — пинаем реконнект, иначе мы не сможем обмениваться SDP/ICE.
		if isAuthenticated {
			Task { await reconnectMeSocket() }
		}
	}

	// MARK: – Calls — CallKit callbacks

	/// Пользователь нажал Accept на системном экране звонка.
	func callKitDidAccept(callId: Int) async {
		// Если детали уже есть (incomingCall заполнен из WS) — accept обычным путём
		if let incoming = incomingCall, incoming.call.id == callId {
			await acceptIncomingCallInternal(incoming: incoming)
			return
		}

		// Иначе строим User из pendingIncoming (контекст из VoIP push)
		if let p = pendingIncoming, p.callId == callId {
			let fakeUser = User(
				id: p.callerId, publicId: nil, email: nil,
				nickname: p.callerName, avatarUrl: p.callerAvatar,
				bio: nil, username: nil, emailVerified: nil, lastSeenAt: nil
			)
			let stubCall = Call(
				id: p.callId, callerId: p.callerId, calleeId: currentUser?.id ?? 0,
				chatId: nil, type: p.type, status: .ringing,
				startedAt: "", acceptedAt: nil, endedAt: nil, durationSeconds: nil
			)
			let incoming = IncomingCallInfo(call: stubCall, caller: fakeUser)
			self.incomingCall = incoming
			await acceptIncomingCallInternal(incoming: incoming)
			return
		}

		Log.calls.error("callKitDidAccept: no context for callId=\(callId)")
	}

	/// Пользователь нажал End на системном экране звонка — это либо decline
	/// входящего, либо нормальное завершение активного.
	func callKitDidEnd(callId: Int) async {
		if let incoming = incomingCall, incoming.call.id == callId {
			incomingCall = nil
			pendingIncoming = nil
			try? await CallService.shared.decline(callId: callId)
			return
		}
		if let active = activeCall, active.id == callId {
			let wasRinging = (active.phase == .dialing)
			let iAmCaller = active.iAmCaller
			callManager?.stop()
			callManager = nil
			active.phase = .ended
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 400_000_000)
				if self.activeCall?.id == callId { self.activeCall = nil }
			}
			if wasRinging && iAmCaller {
				try? await CallService.shared.cancel(callId: callId)
			} else {
				try? await CallService.shared.end(callId: callId)
			}
		}
		pendingIncoming = nil
	}

	/// Жёсткое завершение всех звонков (например при CallKit reset).
	func forceTeardownAllCalls() async {
		callManager?.stop()
		callManager = nil
		activeCall = nil
		incomingCall = nil
		pendingIncoming = nil
	}

	private func handleCallAccepted(_ obj: [String: Any]) {
		guard let callId = intFromJSON(obj["call_id"]),
		      let active = activeCall, active.id == callId else { return }
		if active.phase == .dialing { active.phase = .connecting }
		// CallKit: показываем «connected» в системном UI и в recent calls
		CallKitManager.shared.reportConnected(callId: callId)
		Task { await callManager?.beginNegotiation() }
	}

	private func handleCallTerminated(_ obj: [String: Any]) {
		guard let callId = intFromJSON(obj["call_id"]) else { return }
		let eventType = (obj["type"] as? String) ?? ""
		let reason: CXCallEndedReason = (eventType == "call_declined")
			? .declinedElsewhere
			: (eventType == "call_cancelled" ? .unanswered : .remoteEnded)

		// Закрываем входящий, если касается его
		if let incoming = incomingCall, incoming.call.id == callId {
			incomingCall = nil
			pendingIncoming = nil
			CallKitManager.shared.reportRemoteEnd(callId: callId, reason: reason)
		}
		// Закрываем активный, если касается его
		if let active = activeCall, active.id == callId {
			active.phase = .ended
			callManager?.stop()
			callManager = nil
			CallKitManager.shared.reportRemoteEnd(callId: callId, reason: reason)
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 500_000_000)
				if self.activeCall?.id == callId { self.activeCall = nil }
			}
		}
		// На всякий случай — если pendingIncoming застрял (push был, accept не нажат)
		if pendingIncoming?.callId == callId {
			pendingIncoming = nil
			CallKitManager.shared.reportRemoteEnd(callId: callId, reason: reason)
		}
	}

	// MARK: – Calls — initiation / control (вызывается из UI)

	func startOutgoingCall(peer: User, type: CallType) async {
		print("📞 startOutgoingCall: peer=\(peer.id) (\(peer.nickname)) type=\(type.rawValue)")
		guard activeCall == nil, incomingCall == nil else {
			print("📞 GUARD failed: activeCall=\(activeCall?.id ?? -1) incomingCall=\(incomingCall?.call.id ?? -1)")
			return
		}
		do {
			let call = try await CallService.shared.initiate(calleeId: peer.id, type: type)
			let active = ActiveCall(id: call.id, peer: peer, type: type, iAmCaller: true, phase: .dialing)
			let manager = CallManager(activeCall: active, peerId: peer.id, signaling: callSignaling)
			self.activeCall = active
			self.callManager = manager
			await callSignaling.attach(manager, callId: call.id)
			// Репортим CallKit'у исходящий звонок — для аудиосессии + recent calls
			CallKitManager.shared.reportOutgoing(callId: call.id, peerName: peer.nickname,
												 hasVideo: type == .video)
			await manager.start()
		} catch {
			let msg = "Не удалось начать звонок: \(error.localizedDescription)"
			Log.calls.error("startOutgoingCall failed: \(String(describing: error))")
			self.callError = msg
		}
	}

	/// Старый публичный метод — оставлен для совместимости с custom IncomingCallView,
	/// который мог где-то вызываться. Делегирует тому же internal-помощнику.
	func acceptIncomingCall() async {
		guard let incoming = incomingCall else { return }
		await acceptIncomingCallInternal(incoming: incoming)
	}

	fileprivate func acceptIncomingCallInternal(incoming: IncomingCallInfo) async {
		do {
			_ = try await CallService.shared.accept(callId: incoming.call.id)
		} catch {
			Log.calls.error("accept failed: \(String(describing: error))")
			self.incomingCall = nil
			self.pendingIncoming = nil
			return
		}
		let active = ActiveCall(id: incoming.call.id, peer: incoming.caller, type: incoming.call.type,
								iAmCaller: false, phase: .connecting)
		let manager = CallManager(activeCall: active, peerId: incoming.caller.id, signaling: callSignaling)
		self.activeCall = active
		self.callManager = manager
		self.incomingCall = nil
		self.pendingIncoming = nil
		await callSignaling.attach(manager, callId: incoming.call.id)
		await manager.start()
	}

	func declineIncomingCall() async {
		guard let incoming = incomingCall else { return }
		incomingCall = nil
		pendingIncoming = nil
		// Корректно закрываем CallKit-screen (он либо уже показан VoIP-пушем, либо
		// был вызван handleIncomingCall'ом)
		CallKitManager.shared.endCall(callId: incoming.call.id)
		try? await CallService.shared.decline(callId: incoming.call.id)
	}

	func endActiveCall() async {
		guard let active = activeCall else { return }
		// Просим CallKit закрыть call → он в ответ вызовет callKitDidEnd, где
		// мы и сделаем всю реальную работу. Это единственный путь чтобы и
		// система и наше состояние оставались в синхроне.
		CallKitManager.shared.endCall(callId: active.id)
	}

	// MARK: – Helpers

	private func intFromJSON(_ value: Any?) -> Int? {
		switch value {
		case let i as Int: return i
		case let n as NSNumber: return n.intValue
		default: return nil
		}
	}

	private let decoder: JSONDecoder = {
		let d = JSONDecoder()
		d.keyDecodingStrategy = .convertFromSnakeCase
		return d
	}()

	// MARK: – Public bootstrap helpers (auth flow)

	func setAuthenticatedAndBootstrap() {
		isAuthenticated = true
		Task { await bootstrapAfterAuth() }
	}

	func logout() async {
		await endActiveCall()
		await meSocket.disconnect()
		try? await AuthService.shared.logout()
		TokenStorage.shared.clear()
		ChatCacheService.shared.clearAll()
		currentUser = nil
		isAuthenticated = false
		onlineUserIds.removeAll()
		ActiveChatTracker.setActiveChat(nil)
	}
}
