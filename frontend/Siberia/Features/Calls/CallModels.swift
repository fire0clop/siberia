import Foundation
import Combine

// MARK: – Enums

enum CallType: String, Codable {
	case audio
	case video
}

enum CallStatus: String, Codable {
	case ringing, active, ended, declined, missed, cancelled
}

// MARK: – Call (история / DTO с бэка)

struct Call: Codable, Identifiable, Equatable {
	let id: Int
	let callerId: Int
	let calleeId: Int
	let chatId: Int?
	let type: CallType
	let status: CallStatus
	let startedAt: String
	let acceptedAt: String?
	let endedAt: String?
	let durationSeconds: Int?
}

// MARK: – Входящий звонок (WS-событие call_incoming)

struct IncomingCallInfo: Identifiable, Equatable {
	let call: Call
	let caller: User
	var id: Int { call.id }
}

// MARK: – Состояние активного звонка (UI)

enum ActiveCallPhase: Equatable {
	case dialing      // мы caller, callee пока не принял
	case ringing      // мы callee, ещё не нажали Accept
	case connecting   // принят, ICE / DTLS handshake
	case active       // медиа течёт
	case ended        // показываем финальный экран ~0.5s перед закрытием
}

final class ActiveCall: ObservableObject, Identifiable {
	let id: Int            // call.id
	let peer: User         // вторая сторона
	let type: CallType
	let iAmCaller: Bool

	@Published var phase: ActiveCallPhase
	@Published var micMuted: Bool = false
	@Published var cameraOn: Bool
	@Published var speakerOn: Bool = false
	@Published var usingFrontCamera: Bool = true
	@Published var connectedAt: Date?     // когда вошли в .active — для таймера
	@Published var remoteHasVideo: Bool = false

	init(id: Int, peer: User, type: CallType, iAmCaller: Bool, phase: ActiveCallPhase) {
		self.id = id
		self.peer = peer
		self.type = type
		self.iAmCaller = iAmCaller
		self.phase = phase
		self.cameraOn = (type == .video)
	}
}
