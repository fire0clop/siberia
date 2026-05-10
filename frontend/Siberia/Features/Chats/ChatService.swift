import Foundation

final class ChatService {

	static let shared = ChatService()
	private init() {}

	private func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.keyEncodingStrategy = .convertToSnakeCase
		return e
	}

	// MARK: – Chats

	func listChats() async throws -> [ChatSummary] {
		let data = try await APIClient.shared.request(path: "/chats")
		return try APIClient.shared.decode([ChatSummary].self, from: data)
	}

	func createChat(withUserId userId: Int) async throws -> ChatSummary {
		let body = try encoder().encode(CreateChatBody(userId: userId))
		let data = try await APIClient.shared.request(path: "/chats", method: "POST", body: body)
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	// MARK: – Groups

	func createGroup(title: String, userIds: [Int], description: String?) async throws -> ChatSummary {
		let body = try encoder().encode(GroupCreateBody(title: title, userIds: userIds, description: description))
		let data = try await APIClient.shared.request(path: "/chats/group", method: "POST", body: body)
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	func addMembers(chatId: Int, userIds: [Int]) async throws {
		let body = try encoder().encode(AddMembersBody(userIds: userIds))
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/members", method: "POST", body: body)
	}

	func removeMember(chatId: Int, userId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/members/\(userId)", method: "DELETE")
	}

	func leaveChat(chatId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/leave", method: "POST")
	}

	func changeMemberRole(chatId: Int, userId: Int, role: String) async throws {
		let body = try encoder().encode(RoleChangeBody(role: role))
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/members/\(userId)/role", method: "PATCH", body: body)
	}

	func updateChatMeta(chatId: Int, title: String?, description: String?) async throws -> ChatSummary {
		var dict: [String: Any] = [:]
		if let t = title { dict["title"] = t }
		if let d = description { dict["description"] = d }
		let body = try JSONSerialization.data(withJSONObject: dict)
		let data = try await APIClient.shared.request(path: "/chats/\(chatId)", method: "PATCH", body: body)
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	// MARK: – Invite links

	func createInviteLink(chatId: Int) async throws -> InviteLinkResponse {
		let data = try await APIClient.shared.request(path: "/chats/\(chatId)/invite-link", method: "POST")
		return try APIClient.shared.decode(InviteLinkResponse.self, from: data)
	}

	func revokeInviteLink(chatId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/invite-link", method: "DELETE")
	}

	func joinByInvite(slug: String) async throws -> ChatSummary {
		let data = try await APIClient.shared.request(path: "/chats/join/\(slug)")
		return try APIClient.shared.decode(ChatSummary.self, from: data)
	}

	// MARK: – Mute / Pin

	func mute(chatId: Int, until: Date? = nil) async throws {
		let formatter = ISO8601DateFormatter()
		let untilStr = until.map { formatter.string(from: $0) }
		let body = try encoder().encode(MuteBody(mutedUntil: untilStr))
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/mute", method: "POST", body: body)
	}

	func unmute(chatId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/mute", method: "DELETE")
	}

	func pin(chatId: Int, messageId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/pin/\(messageId)", method: "POST")
	}

	func unpin(chatId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/pin", method: "DELETE")
	}

	// MARK: – Scheduled messages

	func scheduleMessage(
		chatId: Int,
		text: String?,
		sendAt: Date,
		replyTo: Int? = nil,
		mediaId: String? = nil
	) async throws -> MessageSendResult {
		let formatter = ISO8601DateFormatter()
		let body = try encoder().encode(MessageScheduleBody(
			content: text,
			sendAt: formatter.string(from: sendAt),
			replyToMessageId: replyTo,
			mediaId: mediaId
		))
		let data = try await APIClient.shared.request(
			path: "/chats/\(chatId)/messages", method: "POST", body: body
		)
		return try APIClient.shared.decode(MessageSendResult.self, from: data)
	}

	func listScheduledMessages(chatId: Int) async throws -> [ChatMessage] {
		let data = try await APIClient.shared.request(path: "/chats/\(chatId)/messages/scheduled")
		return try APIClient.shared.decode([ChatMessage].self, from: data)
	}

	func cancelScheduled(messageId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/messages/\(messageId)/scheduled", method: "DELETE")
	}

	func chatDetail(chatId: Int) async throws -> ChatDetail {
		let data = try await APIClient.shared.request(path: "/chats/\(chatId)")
		return try APIClient.shared.decode(ChatDetail.self, from: data)
	}

	func members(chatId: Int) async throws -> [ChatMember] {
		let data = try await APIClient.shared.request(path: "/chats/\(chatId)/members")
		return try APIClient.shared.decode([ChatMember].self, from: data)
	}

	// MARK: – Messages

	func messages(chatId: Int, limit: Int = 50, beforeId: Int? = nil) async throws -> [ChatMessage] {
		var path = "/chats/\(chatId)/messages?limit=\(limit)"
		if let bid = beforeId { path += "&before_id=\(bid)" }
		let data = try await APIClient.shared.request(path: path)
		return try APIClient.shared.decode([ChatMessage].self, from: data)
	}

	func sendMessage(
		chatId: Int,
		text: String?,
		clientMessageId: UUID? = nil,
		replyTo: Int? = nil,
		forwardMessageId: Int? = nil,
		mediaId: String? = nil,
		mentionUserIds: [Int]? = nil
	) async throws -> MessageSendResult {
		let body = try encoder().encode(MessageSendBody(
			content: text,
			clientMessageId: clientMessageId?.uuidString,
			replyToMessageId: replyTo,
			forwardMessageId: forwardMessageId,
			mediaId: mediaId,
			mentionUserIds: mentionUserIds
		))
		let data = try await APIClient.shared.request(
			path: "/chats/\(chatId)/messages", method: "POST", body: body
		)
		return try APIClient.shared.decode(MessageSendResult.self, from: data)
	}

	func editMessage(messageId: Int, newText: String) async throws -> ChatMessage {
		let body = try encoder().encode(MessagePatchBody(content: newText))
		let data = try await APIClient.shared.request(
			path: "/messages/\(messageId)", method: "PATCH", body: body
		)
		return try APIClient.shared.decode(ChatMessage.self, from: data)
	}

	func deleteMessage(messageId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/messages/\(messageId)", method: "DELETE")
	}

	func messageHistory(messageId: Int) async throws -> MessageHistoryResponse {
		let data = try await APIClient.shared.request(path: "/messages/\(messageId)/history")
		return try APIClient.shared.decode(MessageHistoryResponse.self, from: data)
	}

	func markRead(chatId: Int, messageId: Int) async throws {
		let body = try encoder().encode(MarkReadBody(upToMessageId: messageId))
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/read", method: "POST", body: body)
	}

	// MARK: – Reactions

	func addReaction(messageId: Int, emoji: String) async throws {
		let body = try encoder().encode(ReactionBody(emoji: emoji))
		_ = try await APIClient.shared.request(
			path: "/messages/\(messageId)/reactions", method: "POST", body: body
		)
	}

	func removeReaction(messageId: Int, emoji: String) async throws {
		let body = try encoder().encode(ReactionBody(emoji: emoji))
		_ = try await APIClient.shared.request(
			path: "/messages/\(messageId)/reactions", method: "DELETE", body: body
		)
	}

	// MARK: – Drafts

	func saveDraft(chatId: Int, text: String) async throws {
		let body = try encoder().encode(ChatDraftBody(text: text))
		_ = try await APIClient.shared.request(
			path: "/chats/\(chatId)/draft", method: "PUT", body: body
		)
	}

	func deleteDraft(chatId: Int) async throws {
		_ = try await APIClient.shared.request(path: "/chats/\(chatId)/draft", method: "DELETE")
	}

	// MARK: – Sync & search

	func sync(chatId: Int, afterSeq: Int, limit: Int = 100) async throws -> ChatSyncResponse {
		let data = try await APIClient.shared.request(
			path: "/chats/\(chatId)/sync?after_seq=\(afterSeq)&limit=\(limit)"
		)
		return try APIClient.shared.decode(ChatSyncResponse.self, from: data)
	}

	func searchMessages(query: String, chatId: Int? = nil, limit: Int = 30) async throws -> SearchMessagesResponse {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&+=")
		let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
		var path = "/search/messages?q=\(q)&limit=\(limit)"
		if let cid = chatId { path += "&chat_id=\(cid)" }
		let data = try await APIClient.shared.request(path: path)
		return try APIClient.shared.decode(SearchMessagesResponse.self, from: data)
	}
}
