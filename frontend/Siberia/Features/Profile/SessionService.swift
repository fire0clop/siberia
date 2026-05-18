import Foundation

final class SessionService {

	static let shared = SessionService()
	private init() {}

	func listSessions() async throws -> [DeviceSession] {
		let data = try await APIClient.shared.request(path: "/sessions")
		return try APIClient.shared.decode([DeviceSession].self, from: data)
	}

	func revokeSession(id: Int) async throws {
		_ = try await APIClient.shared.request(
			path: "/sessions/\(id)",
			method: "DELETE"
		)
	}

	func revokeAllOtherSessions() async throws {
		_ = try await APIClient.shared.request(
			path: "/sessions/revoke_all",
			method: "POST"
		)
	}
}
