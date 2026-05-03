import Foundation

/// Какой чат сейчас открыт на экране (чтобы не дублировать локальное уведомление).
@MainActor
enum ActiveChatTracker {
	static var currentChatId: Int?

	static func setActiveChat(_ id: Int?) {
		currentChatId = id
	}
}
