import Foundation

final class UserService {

	static let shared = UserService()
	private init() {}

	private let encoder: JSONEncoder = {
		let e = JSONEncoder()
		e.keyEncodingStrategy = .convertToSnakeCase
		return e
	}()

	func me() async throws -> User {
		let data = try await APIClient.shared.request(path: "/users/me")
		return try APIClient.shared.decode(User.self, from: data)
	}

	func searchUsers(query: String) async throws -> [User] {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&+=")
		let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
		let data = try await APIClient.shared.request(path: "/users/search?q=\(encoded)")
		return try APIClient.shared.decode([User].self, from: data)
	}

	func presence(userId: Int) async throws -> PresenceResponse {
		let data = try await APIClient.shared.request(path: "/users/\(userId)/presence")
		return try APIClient.shared.decode(PresenceResponse.self, from: data)
	}

	func setAvatar(mediaId: String) async throws -> User {
		let body = try encoder.encode(["media_id": mediaId])
		let data = try await APIClient.shared.request(path: "/users/me/avatar", method: "PATCH", body: body)
		return try APIClient.shared.decode(User.self, from: data)
	}

	func deleteAvatar() async throws -> User {
		let data = try await APIClient.shared.request(path: "/users/me/avatar", method: "DELETE")
		return try APIClient.shared.decode(User.self, from: data)
	}

	// MARK: – Profile patch (nickname / bio)

	func updateProfile(nickname: String?, bio: String?) async throws -> User {
		let body = try encoder.encode(ProfilePatchBody(nickname: nickname, bio: bio))
		let data = try await APIClient.shared.request(path: "/users/me", method: "PATCH", body: body)
		return try APIClient.shared.decode(User.self, from: data)
	}

	// MARK: – Privacy

	func getPrivacy() async throws -> PrivacySettings {
		let data = try await APIClient.shared.request(path: "/users/me/privacy")
		return try APIClient.shared.decode(PrivacySettings.self, from: data)
	}

	func updatePrivacy(
		lastSeen: String? = nil,
		avatar: String? = nil,
		messagesFrom: String? = nil,
		invisibleMode: Bool? = nil
	) async throws -> PrivacySettings {
		let body = try encoder.encode(PrivacyPatch(
			lastSeen: lastSeen, avatar: avatar,
			messagesFrom: messagesFrom, invisibleMode: invisibleMode
		))
		let data = try await APIClient.shared.request(path: "/users/me/privacy", method: "PATCH", body: body)
		return try APIClient.shared.decode(PrivacySettings.self, from: data)
	}

	// MARK: – Block list

	func block(userId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/users/\(userId)/block", method: "POST")
	}

	func unblock(userId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/users/\(userId)/block", method: "DELETE")
	}

	func listBlocked() async throws -> [User] {
		let data = try await APIClient.shared.request(path: "/users/me/blocked")
		return try APIClient.shared.decode([User].self, from: data)
	}

	// MARK: – Global search

	func globalSearch(query: String, limit: Int = 20) async throws -> GlobalSearchResponse {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&+=")
		let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
		let data = try await APIClient.shared.request(path: "/search?q=\(q)&limit=\(limit)")
		return try APIClient.shared.decode(GlobalSearchResponse.self, from: data)
	}
}
