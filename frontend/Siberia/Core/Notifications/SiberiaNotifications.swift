import Foundation

extension Notification.Name {
	static let siberiaChatsShouldReload = Notification.Name("SiberiaChatsShouldReload")
	/// Прилетает когда у кого-то изменился presence (онлайн/офлайн).
	/// `userInfo`: ["user_id": Int, "online": Bool, "last_seen_at": String?].
	static let siberiaPresenceChange = Notification.Name("SiberiaPresenceChange")
	/// Запрос открыть конкретный чат (из тапа по push-уведомлению).
	/// `userInfo`: ["chatId": Int].
	static let siberiaOpenChat = Notification.Name("SiberiaOpenChat")
}
