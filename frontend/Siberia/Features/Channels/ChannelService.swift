import Foundation

final class ChannelService {

	static let shared = ChannelService()
	private init() {}

	private func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.keyEncodingStrategy = .convertToSnakeCase
		return e
	}

	// MARK: – Create / get / update

	func create(title: String, description: String?, isPublic: Bool) async throws -> ChatSummary {
		let body = try encoder().encode(ChannelCreateBody(
			title: title, description: description, isPublic: isPublic
		))
		let data = try await APIClient.shared.request(path: "/channels", method: "POST", body: body)
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	func get(channelId: Int) async throws -> ChatSummary {
		let data = try await APIClient.shared.request(path: "/channels/\(channelId)")
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	// MARK: – Subscribe / unsubscribe

	func subscribe(channelId: Int) async throws -> ChatSummary {
		let data = try await APIClient.shared.request(path: "/channels/\(channelId)/subscribe", method: "POST")
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	func unsubscribe(channelId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/channels/\(channelId)/subscribe", method: "DELETE")
	}

	func subscribeByInvite(slug: String) async throws -> ChatSummary {
		let data = try await APIClient.shared.request(path: "/channels/join/\(slug)")
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	// MARK: – Search (public)

	func searchPublic(query: String, limit: Int = 30) async throws -> [ChannelSearchResult] {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&+=")
		let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
		let data = try await APIClient.shared.request(path: "/search/channels?q=\(q)&limit=\(limit)")
		return try APIClient.shared.decode([ChannelSearchResult].self, from: data)
	}
}
