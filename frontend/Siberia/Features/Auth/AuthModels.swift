import Foundation

// MARK: – Auth

/// Бэкенд возвращает один из двух вариантов:
/// 1. Обычный ответ — accessToken/refreshToken/user заполнены, requiresTwoFa=false/nil.
/// 2. 2FA pending — requiresTwoFa=true + tempToken, остальное nil.
struct AuthResponse: Codable {
	let accessToken: String?
	let refreshToken: String?
	let tokenType: String?
	let user: User?

	// 2FA flow
	let requiresTwoFa: Bool?
	let tempToken: String?

	var isTwoFactorPending: Bool { requiresTwoFa == true }
}

struct TokenResponse: Codable {
	let accessToken: String
	let refreshToken: String
	let tokenType: String
}

struct User: Codable, Equatable, Hashable, Identifiable {
	let id: Int
	let publicId: String?
	let email: String?
	let nickname: String
	let avatarUrl: String?
	let bio: String?
	let username: String?
	let emailVerified: Bool?
	let lastSeenAt: String?
}

// MARK: – Privacy

enum PrivacyVisibility: String, Codable, CaseIterable, Identifiable {
	case everyone, friends, nobody
	var id: String { rawValue }
	var displayName: String {
		switch self {
		case .everyone: return "Все"
		case .friends:  return "Только друзья"
		case .nobody:   return "Никто"
		}
	}
}

struct PrivacySettings: Codable, Equatable {
	var lastSeen: String
	var avatar: String
	var messagesFrom: String
	var invisibleMode: Bool

	static var defaults: PrivacySettings {
		PrivacySettings(lastSeen: "everyone", avatar: "everyone", messagesFrom: "everyone", invisibleMode: false)
	}
}

struct PrivacyPatch: Encodable {
	let lastSeen: String?
	let avatar: String?
	let messagesFrom: String?
	let invisibleMode: Bool?
}

// MARK: – Mute / Search

struct MuteBody: Encodable {
	let mutedUntil: String?   // ISO8601 либо nil = навсегда
}

struct GlobalSearchResponse: Codable {
	struct UserHit: Codable, Identifiable {
		let id: Int
		let nickname: String
		let username: String?
		let avatarMediaId: String?
	}
	struct MessageHit: Codable, Identifiable {
		let id: Int
		let chatId: Int
		let userId: Int?
		let text: String?
		let createdAt: String?
	}
	struct ChatHit: Codable, Identifiable {
		let id: Int
		let type: String
		let title: String?
		let avatarMediaId: String?
	}
	let users: [UserHit]
	let messages: [MessageHit]
	let chats: [ChatHit]
}

// MARK: – Profile patch

struct ProfilePatchBody: Encodable {
	let nickname: String?
	let bio: String?
}

// MARK: – Scheduled message scheduling

// MARK: – Edit history

struct MessageHistoryResponse: Codable {
	struct Version: Codable, Identifiable {
		let text: String?
		let editedAt: String?
		var id: String { (editedAt ?? "") + (text ?? "") }
	}
	let messageId: Int
	let versions: [Version]
}

struct MessageScheduleBody: Encodable {
	let content: String?
	let sendAt: String       // ISO8601
	let replyToMessageId: Int?
	let mediaId: String?
}

// MARK: – Group / Channel create

struct GroupCreateBody: Encodable {
	let title: String
	let userIds: [Int]
	let description: String?
}

struct AddMembersBody: Encodable {
	let userIds: [Int]
}

struct RoleChangeBody: Encodable {
	let role: String   // "owner" | "admin" | "member"
}

struct ChannelCreateBody: Encodable {
	let title: String
	let description: String?
	let isPublic: Bool
}

struct InviteLinkResponse: Codable {
	let inviteLink: String?
	let slug: String?
}

struct ChannelSearchResult: Codable, Identifiable {
	let id: Int
	let title: String?
	let description: String?
	let avatarMediaId: String?
	let subscribersCount: Int
	let isPublic: Bool
}

// MARK: – 2FA

struct TotpSetupResponse: Codable {
	let secret: String
	let qrUrl: String
}

struct TotpConfirmBody: Encodable {
	let totpCode: String
}

struct TotpVerifyBody: Encodable {
	let tempToken: String
	let totpCode: String
}

// MARK: – Email verification

struct EmailVerifyBody: Encodable {
	let code: String
}

// MARK: – Friends

struct FriendRequestItem: Codable, Identifiable {
	var id: Int { requestId }
	let requestId: Int
	let user: User
}

// MARK: – Chat list

struct ChatSummary: Codable, Identifiable, Equatable {
	let id: Int
	let title: String?
	let type: String?
	let lastMessageId: Int?
	// Flat field variants – covers many possible API naming conventions
	let lastMessageText:    String?
	let lastMessageContent: String?
	let lastMessagePreview: String?
	let messagePreview:     String?
	let preview:            String?
	let lastMessageAt:      String?
	let lastActivityAt:     String?
	let updatedAt:          String?
	let syncSeq:   Int
	let createdAt: String
	let unreadCount: Int?
	// Nested object: { "last_message": { "text": "...", "created_at": "..." } }
	let lastMessage: NestedMessage?

	struct NestedMessage: Codable, Equatable {
		let id:        Int?
		let text:      String?
		let content:   String?
		let body:      String?
		let preview:   String?
		let message:   String?
		let createdAt: String?
		let sentAt:    String?
		let updatedAt: String?
		let mediaId:   String?
		let mediaType: String?
	}

	var displayText: String? {
		let flat: [String?] = [
			lastMessageText, lastMessageContent, lastMessagePreview,
			messagePreview, preview,
		]
		let nested: [String?] = [
			lastMessage?.text, lastMessage?.content, lastMessage?.body,
			lastMessage?.preview, lastMessage?.message,
		]
		return (flat + nested).compactMap { $0 }.first { !$0.isEmpty }
	}

	var displayAt: String? {
		lastMessageAt
			?? lastMessage?.createdAt
			?? lastMessage?.sentAt
			?? lastMessage?.updatedAt
			?? lastActivityAt
			?? updatedAt
	}

	var hasAnyMessage: Bool {
		lastMessageId != nil || lastMessage?.id != nil || displayText != nil
	}
}

struct ChatDetail: Codable {
	let id: Int
	let title: String?
	let type: String?
	let pinnedMessageId: Int?
	let syncSeq: Int
	let draftText: String?
}

// MARK: – Messages

struct MessageReaction: Codable, Equatable {
	let emoji: String
	let count: Int
	let userIds: [Int]?
}

struct ChatMessage: Codable, Identifiable, Equatable {
	let id: Int
	let chatId: Int?
	let userId: Int?      // nil для системных сообщений
	let text: String?
	let createdAt: String?
	let editedAt: String?
	let deletedAt: String?
	let deleted: Bool?
	let replyToMessageId: Int?
	let clientMessageId: String?
	let status: String?
	// Phase 2
	let mediaId: String?
	let mediaType: String?
	let forwardedFromMessageId: Int?
	let forwardedFromUserId: Int?
	let forwardedFromChatId: Int?
	let mentionUserIds: [Int]?
	var reactions: [MessageReaction]?
	/// "text" | "system" | nil (старый бэк без поля)
	let type: String?

	var isDeleted: Bool { deleted ?? (deletedAt != nil) }
	var hasMedia: Bool { mediaId != nil }
	var isForwarded: Bool { forwardedFromMessageId != nil }
	var isSystem: Bool { type == "system" }

	func withResolvedChatId(_ fallback: Int) -> ChatMessage {
		ChatMessage(
			id: id, chatId: chatId ?? fallback, userId: userId,
			text: text, createdAt: createdAt, editedAt: editedAt,
			deletedAt: deletedAt, deleted: deleted,
			replyToMessageId: replyToMessageId,
			clientMessageId: clientMessageId, status: status,
			mediaId: mediaId, mediaType: mediaType,
			forwardedFromMessageId: forwardedFromMessageId,
			forwardedFromUserId: forwardedFromUserId,
			forwardedFromChatId: forwardedFromChatId,
			mentionUserIds: mentionUserIds, reactions: reactions,
			type: type
		)
	}
}

struct MessageSendBody: Encodable {
	let content: String?
	let clientMessageId: String?
	let replyToMessageId: Int?
	let forwardMessageId: Int?
	let mediaId: String?
	let mentionUserIds: [Int]?
}

struct MessagePatchBody: Encodable {
	let content: String
}

struct MessageSendResult: Codable {
	let message: ChatMessage
	let idempotent: Bool?
	var wasIdempotent: Bool { idempotent ?? false }
}

struct MarkReadBody: Encodable {
	let upToMessageId: Int
}

// MARK: – Reactions

struct ReactionBody: Encodable {
	let emoji: String
}

// MARK: – Drafts

struct ChatDraftBody: Encodable {
	let text: String
}

// MARK: – Media

struct MediaUploadResponse: Codable {
	let id: String
	let type: String
	let url: String?
	let originalName: String?
	let mimeType: String?
	let sizeBytes: Int?
	let durationSec: Int?
	let width: Int?
	let height: Int?
	let waveform: [Float]?
}

struct MediaURLResponse: Codable {
	let url: String
	let thumbnailUrl: String?
	let originalName: String?
	let mimeType: String?
	let sizeBytes: Int?
	let durationSec: Int?
	let width: Int?
	let height: Int?
	let waveform: [Float]?
}


// MARK: – Sync

struct ChatSyncResponse: Codable {
	let updates: [ChatSyncUpdate]
	let latestSeq: Int
}

struct ChatSyncUpdate: Codable {
	let seq: Int
	let event: String
	let messageId: Int?
	let createdAt: String?
}

// MARK: – Search

struct SearchMessagesResponse: Codable {
	struct Hit: Codable, Identifiable {
		let id: Int
		let chatId: Int
		let userId: Int
		let text: String?
		let createdAt: String
		let editedAt: String?
	}
	let results: [Hit]
}

// MARK: – Chat members & presence

struct ChatMember: Codable, Identifiable {
	let role: String?
	let joinedAt: String?
	let user: User

	var id: Int { user.id }
	var userId: Int { user.id }
}

struct PresenceResponse: Codable {
	let userId: Int
	/// Бэкенд шлёт поле `online`, а не `is_online` — поэтому именуем так же.
	let online: Bool
	let lastSeenAt: String?

	/// Обратно-совместимый alias, чтобы старые места кода не сломались.
	var isOnline: Bool { online }
}

// MARK: – Sessions

struct CreateChatBody: Encodable {
	let userId: Int
}

struct DeviceSession: Codable, Identifiable {
	let id: Int
	let deviceId: String?
	let userAgent: String?
	let createdAt: String
	let lastActive: String
}

// MARK: – Gallery

struct GalleryMediaItem: Identifiable, Equatable {
	let id: String   // mediaId
	let type: String // "image" | "video" | "video_note"
	var isVideo: Bool { type == "video" || type == "video_note" }
}
