import Foundation

final class CallService {
	static let shared = CallService()
	private init() {}

	func initiate(calleeId: Int, type: CallType) async throws -> Call {
		let body = try JSONSerialization.data(withJSONObject: [
			"callee_id": calleeId,
			"type": type.rawValue,
		])
		let data = try await APIClient.shared.request(path: "/calls", method: "POST", body: body)
		return try APIClient.shared.decode(Call.self, from: data)
	}

	func accept(callId: Int) async throws -> Call {
		let data = try await APIClient.shared.request(path: "/calls/\(callId)/accept", method: "POST")
		return try APIClient.shared.decode(Call.self, from: data)
	}

	func decline(callId: Int) async throws -> Call {
		let data = try await APIClient.shared.request(path: "/calls/\(callId)/decline", method: "POST")
		return try APIClient.shared.decode(Call.self, from: data)
	}

	func cancel(callId: Int) async throws -> Call {
		let data = try await APIClient.shared.request(path: "/calls/\(callId)/cancel", method: "POST")
		return try APIClient.shared.decode(Call.self, from: data)
	}

	func end(callId: Int) async throws -> Call {
		let data = try await APIClient.shared.request(path: "/calls/\(callId)/end", method: "POST")
		return try APIClient.shared.decode(Call.self, from: data)
	}
}
