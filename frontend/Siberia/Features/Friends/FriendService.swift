import Foundation

final class FriendService {

	static let shared = FriendService()
	private init() {}

	func getFriends() async throws -> [User] {
		let data = try await APIClient.shared.request(path: "/friends")
		return try APIClient.shared.decode([User].self, from: data)
	}

	func addFriend(userId: Int) async throws {
		_ = try await APIClient.shared.request(
			path: "/friends/add/\(userId)",
			method: "POST"
		)
	}

	func getRequests() async throws -> [FriendRequestItem] {
		let data = try await APIClient.shared.request(path: "/friends/requests")
		return try APIClient.shared.decode([FriendRequestItem].self, from: data)
	}

	func accept(requestId: Int) async throws {
		_ = try await APIClient.shared.request(
			path: "/friends/accept/\(requestId)",
			method: "POST"
		)
	}

	func reject(requestId: Int) async throws {
		_ = try await APIClient.shared.request(
			path: "/friends/reject/\(requestId)",
			method: "POST"
		)
	}

	func remove(userId: Int) async throws {
		_ = try await APIClient.shared.request(
			path: "/friends/\(userId)",
			method: "DELETE"
		)
	}

	func getSentRequests() async throws -> [FriendRequestItem] {
		let data = try await APIClient.shared.request(path: "/friends/requests/sent")
		return try APIClient.shared.decode([FriendRequestItem].self, from: data)
	}
}
