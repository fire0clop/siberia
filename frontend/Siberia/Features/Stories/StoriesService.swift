// Features/Stories/StoriesService.swift
//
// Stories: эфемерные медиа-посты (24 часа), видны друзьям.

import Foundation

// MARK: – Модели

struct StoryItem: Codable, Identifiable, Equatable {
	let id: Int
	let userId: Int
	let mediaId: String
	let mediaType: String
	let mediaUrl: String?
	let caption: String?
	let createdAt: String
	let expiresAt: String
	let viewed: Bool
	let viewsCount: Int?
}

struct StoryFeedGroup: Codable, Identifiable, Equatable {
	let user: User
	let stories: [StoryItem]
	let allViewed: Bool

	var id: Int { user.id }
}

// MARK: – Сервис

final class StoriesService {
	static let shared = StoriesService()
	private init() {}

	func feed() async throws -> [StoryFeedGroup] {
		let data = try await APIClient.shared.request(path: "/stories/feed", method: "GET")
		return try APIClient.shared.decode([StoryFeedGroup].self, from: data)
	}

	func create(mediaId: String, caption: String?) async throws -> StoryItem {
		var body: [String: Any] = ["media_id": mediaId]
		if let caption, !caption.isEmpty { body["caption"] = caption }
		let data = try await APIClient.shared.request(
			path: "/stories", method: "POST",
			body: try JSONSerialization.data(withJSONObject: body)
		)
		return try APIClient.shared.decode(StoryItem.self, from: data)
	}

	func markViewed(storyId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/stories/\(storyId)/view", method: "POST")
	}

	func viewers(storyId: Int) async throws -> [User] {
		let data = try await APIClient.shared.request(path: "/stories/\(storyId)/views", method: "GET")
		return try APIClient.shared.decode([User].self, from: data)
	}

	func delete(storyId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/stories/\(storyId)", method: "DELETE")
	}
}
