import Foundation
import UIKit
import UserNotifications

// MARK: – Notification category / action identifiers

enum NotificationCategory {
	static let message = "SIBERIA_MESSAGE"
}

enum NotificationAction {
	static let reply  = "REPLY"
	static let read   = "MARK_READ"
}

// MARK: – Local notifications for new messages

enum MessageNotifications {

	// Register push authorization + notification categories (Reply / Mark as Read).
	@MainActor
	static func requestAuthorizationIfNeeded() async {
		let center = UNUserNotificationCenter.current()
		registerCategories(center)

		let settings = await center.notificationSettings()
		switch settings.authorizationStatus {
		case .notDetermined:
			let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
			if granted {
				UIApplication.shared.registerForRemoteNotifications()
			}
		case .authorized, .provisional, .ephemeral:
			UIApplication.shared.registerForRemoteNotifications()
		default:
			break
		}
	}

	// Build and show a local notification for an incoming message.
	@MainActor
	static func notifyNewMessageIfNeeded(
		chatId: Int,
		messageId: Int,
		senderUserId: Int,
		senderName: String? = nil,
		text: String?,
		mediaType: String? = nil,
		thumbnailURL: String? = nil,
		currentUserId: Int?
	) {
		guard senderUserId != currentUserId else { return }
		if chatId == ActiveChatTracker.currentChatId { return }
		if ChatNotificationSettingsStore.shared.isDnDActive(for: chatId) { return }

		let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let bodyText: String = {
			if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
			switch mediaType {
			case "image":      return "📷 Фото"
			case "video":      return "🎬 Видео"
			case "voice":      return "🎤 Голосовое"
			case "audio":      return "🎵 Аудио"
			case "document":   return "📎 Файл"
			default:           return "Новое сообщение"
			}
		}()

		let content = UNMutableNotificationContent()
		content.title = senderName ?? "Siberia"
		content.body = bodyText
		content.sound = .default
		content.threadIdentifier = "chat-\(chatId)"
		content.categoryIdentifier = NotificationCategory.message
		content.userInfo = ["chatId": chatId, "messageId": messageId]

		// Attach local thumbnail if we have a URL cached locally
		if let thumbStr = thumbnailURL, let thumbURL = URL(string: thumbStr) {
			Task {
				if let attachment = await downloadAttachment(from: thumbURL, messageId: messageId),
				   let richContent = content.mutableCopy() as? UNMutableNotificationContent {
					richContent.attachments = [attachment]
					schedule(content: richContent, messageId: messageId)
				} else {
					schedule(content: content, messageId: messageId)
				}
			}
		} else {
			schedule(content: content, messageId: messageId)
		}
	}

	// MARK: – Private helpers

	private static func schedule(content: UNNotificationContent, messageId: Int) {
		let request = UNNotificationRequest(
			identifier: "siberia-msg-\(messageId)",
			content: content,
			trigger: nil
		)
		UNUserNotificationCenter.current().add(request) { err in
			if let err { Log.push.error("schedule notification failed: \(err)") }
		}
	}

	private static func downloadAttachment(from url: URL, messageId: Int) async -> UNNotificationAttachment? {
		guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("notif_thumb_\(messageId).jpg")
		try? data.write(to: tmp)
		return try? UNNotificationAttachment(identifier: "thumb", url: tmp, options: nil)
	}

	private static func registerCategories(_ center: UNUserNotificationCenter) {
		let replyAction = UNTextInputNotificationAction(
			identifier: NotificationAction.reply,
			title: "Ответить",
			options: [],
			textInputButtonTitle: "Отправить",
			textInputPlaceholder: "Сообщение…"
		)
		let readAction = UNNotificationAction(
			identifier: NotificationAction.read,
			title: "Прочитано",
			options: [.authenticationRequired]
		)
		let category = UNNotificationCategory(
			identifier: NotificationCategory.message,
			actions: [replyAction, readAction],
			intentIdentifiers: [],
			options: [.customDismissAction]
		)
		center.setNotificationCategories([category])
	}
}

// MARK: – Delegate (foreground presentation + action handling)

final class SiberiaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

	static let shared = SiberiaNotificationDelegate()

	// Foreground presentation: no banner (WS already shows it), only sound + list
	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		let appState = UIApplication.shared.applicationState
		completionHandler(appState == .active ? [.list, .sound] : [.banner, .list, .sound])
	}

	// Handle taps and action buttons
	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		defer { completionHandler() }

		let userInfo = response.notification.request.content.userInfo
		guard let chatId = userInfo["chatId"] as? Int,
		      let messageId = userInfo["messageId"] as? Int else { return }

		switch response.actionIdentifier {

		case NotificationAction.reply:
			guard let textResponse = response as? UNTextInputNotificationResponse else { return }
			let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { return }
			Task {
				do {
					_ = try await ChatService.shared.sendMessage(chatId: chatId, text: text)
					Log.push.info("Quick reply sent to chat \(chatId)")
				} catch {
					Log.push.error("Quick reply failed: \(error)")
				}
			}

		case NotificationAction.read:
			Task {
				do {
					try await ChatService.shared.markRead(chatId: chatId, messageId: messageId)
					Log.push.info("Marked read up to \(messageId) in chat \(chatId)")
				} catch {
					Log.push.error("Mark read failed: \(error)")
				}
			}

		default:
			// Default tap — deep-link into the chat
			NotificationCenter.default.post(
				name: .siberiaOpenChat,
				object: nil,
				userInfo: ["chatId": chatId]
			)
		}
	}
}
