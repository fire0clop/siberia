// Features/Calls/CallSignaling.swift
//
// Прослойка между WebSocket /ws/me и CallManager. Знает как:
//  - отправить наш SDP/ICE сквозь сокет
//  - роутить входящие call_signal-фреймы в активный CallManager
//
// Один экземпляр на приложение, живёт внутри AppState.

import Foundation

@MainActor
final class CallSignaling {

	// Слабая ссылка на менеджер активного звонка — выставляется при attach.
	private weak var manager: CallManager?
	private var currentCallId: Int?

	/// Буфер фреймов, которые пришли по WS ДО того как ответная сторона нажала
	/// "Принять" (или ДО того как caller-у пришёл call_accepted и его CallManager
	/// был создан). При attach() выливаем буфер в менеджер по порядку.
	private var pendingInbound: [(callId: Int, frame: [String: Any])] = []

	/// Sender: замыкание, которое умеет послать JSON через /ws/me сокет.
	var sender: (@MainActor ([String: Any]) async -> Void)?

	// MARK: – Attach / detach (вызывает AppState/CallManager)

	func attach(_ manager: CallManager, callId: Int) async {
		self.manager = manager
		self.currentCallId = callId

		// Сливаем буфер в текущий менеджер
		let toReplay = pendingInbound.filter { $0.callId == callId }
		pendingInbound.removeAll { $0.callId == callId }
		print("📞 CallSignaling.attach: replaying \(toReplay.count) buffered frames")
		for item in toReplay {
			await deliverToManager(item.frame)
		}
	}

	func detach(callId: Int) {
		if currentCallId == callId {
			self.manager = nil
			self.currentCallId = nil
		}
		pendingInbound.removeAll { $0.callId == callId }
	}

	// MARK: – Outgoing

	/// Отправить SDP/ICE пиру через /ws/me. На сервере relay_signal делает
	/// валидацию участия + публикует в user:{peer_id} канал.
	func send(callId: Int, kind: String, payload: [String: Any]) async {
		guard let sender else {
			print("📞 CallSignaling.send: no sender! call=\(callId) kind=\(kind)")
			return
		}
		print("📞 OUT: \(kind) call=\(callId)")
		let frame: [String: Any] = [
			"type": "call_signal",
			"call_id": callId,
			"kind": kind,
			"payload": payload,
		]
		await sender(frame)
	}

	// MARK: – Incoming (вызывается из AppState при получении call_signal)

	func handleIncomingSignal(_ obj: [String: Any]) async {
		guard
			let callId = (obj["call_id"] as? Int) ?? (obj["call_id"] as? NSNumber)?.intValue,
			let _ = obj["kind"] as? String
		else { return }

		// Если менеджер уже привязан к этому callId — отдаём сразу
		if callId == currentCallId, manager != nil {
			await deliverToManager(obj)
			return
		}

		// Иначе буферизуем — менеджер появится позже (после attach при accept)
		print("📞 BUFFERING inbound: kind=\(obj["kind"] ?? "?") call=\(callId)")
		pendingInbound.append((callId: callId, frame: obj))
	}

	private func deliverToManager(_ obj: [String: Any]) async {
		guard let manager, let kind = obj["kind"] as? String else { return }
		let payload = (obj["payload"] as? [String: Any]) ?? [:]
		switch kind {
		case "offer", "answer":
			let sdp = (payload["sdp"] as? String) ?? ""
			await manager.handleRemoteSDP(kind: kind, sdpString: sdp)
		case "ice":
			await manager.handleRemoteIce(payload: payload)
		default:
			break
		}
	}
}
