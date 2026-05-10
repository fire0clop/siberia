import Foundation
import UIKit

// MARK: – Presence, typing, and WebSocket event handling

extension ChatDetailViewModel {

	// MARK: Presence

	func fetchPresence() async {
		guard let uid = partnerUserId else { return }
		do {
			let p = try await UserService.shared.presence(userId: uid)
			isPartnerOnline = p.online
		} catch {
			Log.chat.error("fetchPresence failed for user \(uid): \(String(describing: error))")
		}
	}

	func startPresencePolling() {
		presenceTask?.cancel()
		presenceTask = Task {
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: UIConstants.presencePollIntervalSec.seconds_ns)
				guard !Task.isCancelled else { break }
				await fetchPresence()
			}
		}
	}

	// MARK: Typing indicator

	func onDraftChange() {
		updateMentionSuggestions()
		guard !draft.isEmpty else { return }
		typingDebounceTask?.cancel()
		typingDebounceTask = Task {
			try? await Task.sleep(nanoseconds: UIConstants.typingDebounceMs.ms_ns)
			guard !Task.isCancelled else { return }
			try? await self.socket.send(json: ["type": "typing", "chat_id": chatId])
		}
	}

	// MARK: Mentions

	func updateMentionSuggestions() {
		let words = draft.components(separatedBy: CharacterSet.whitespaces)
		guard let last = words.last, last.hasPrefix("@"), last.count > 1 else {
			if !mentionSuggestions.isEmpty { mentionSuggestions = [] }
			return
		}
		let query = String(last.dropFirst()).lowercased()
		mentionSuggestions = chatMembers.filter {
			$0.user.nickname.lowercased().hasPrefix(query) && $0.userId != currentUserId
		}
	}

	func insertMention(_ member: ChatMember) {
		let nickname = member.user.nickname
		var words = draft.components(separatedBy: CharacterSet.whitespaces)
		if words.last?.hasPrefix("@") == true { words.removeLast() }
		words.append("@\(nickname) ")
		draft = words.joined(separator: " ")
		mentionSuggestions = []
	}

	// MARK: WebSocket

	func connectSocket() async {
		await self.socket.connect(
			path: "/ws/\(chatId)",
			onText: { [weak self] text in
				Task { @MainActor in await self?.handleSocketText(text) }
			},
			onReconnect: { [weak self] in
				Task { @MainActor [weak self] in
					guard let self else { return }
					try? await self.runSync()
					await self.loadMessages()
					await self.flushPendingQueue()
				}
			}
		)
	}

	func handleSocketText(_ text: String) async {
		guard let data = text.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return }

		let eventType = (obj["type"] as? String) ?? (obj["event"] as? String) ?? ""
		if let cid = obj["chat_id"] as? Int, cid != chatId { return }

		switch eventType {
		case "message_new":
			if let msg = decodeMessage(from: obj) {
				let resolved = msg.withResolvedChatId(chatId)

				if let cid = resolved.clientMessageId,
				   messages.contains(where: { $0.clientMessageId == cid && $0.id > 0 }) {
					updateSeq(from: obj)
					break
				}

				if let cid = resolved.clientMessageId {
					pendingClientIds.remove(cid)
					messages.removeAll { $0.clientMessageId == cid && $0.id < 0 }
				}

				if !messages.contains(where: { $0.id == resolved.id }) {
					upsert(resolved)
					if !isAtBottom && resolved.userId != currentUserId {
						newMessagesBelowCount += 1
					}
				}
			} else {
				await loadMessages()
			}
			updateSeq(from: obj)

		case "message_edit":
			if let msgId  = intVal(obj["message_id"]),
			   let payload = obj["payload"] as? [String: Any],
			   let idx    = messages.firstIndex(where: { $0.id == msgId }) {
				let old = messages[idx]
				messages[idx] = ChatMessage(
					id: old.id, chatId: old.chatId, userId: old.userId,
					text: payload["text"] as? String,
					createdAt: old.createdAt,
					editedAt: payload["edited_at"] as? String,
					deletedAt: old.deletedAt, deleted: old.deleted,
					replyToMessageId: old.replyToMessageId,
					clientMessageId: old.clientMessageId, status: old.status,
					mediaId: old.mediaId, mediaType: old.mediaType,
					forwardedFromMessageId: old.forwardedFromMessageId,
					forwardedFromUserId: old.forwardedFromUserId,
					forwardedFromChatId: old.forwardedFromChatId,
					mentionUserIds: old.mentionUserIds, reactions: old.reactions,
					type: old.type
				)
			}
			updateSeq(from: obj)

		case "message_delete":
			if let msgId = intVal(obj["message_id"]),
			   let idx = messages.firstIndex(where: { $0.id == msgId }) {
				messages[idx] = softDeleted(messages[idx])
			}
			updateSeq(from: obj)

		case "reaction_update":
			handleReactionUpdate(obj)
			updateSeq(from: obj)

		case "message_pinned":
			if let msgId = intVal(obj["message_id"]) {
				pinnedMessage = messages.first(where: { $0.id == msgId })
			}

		case "typing":
			handleTyping(obj)

		case "presence_change":
			let payload = (obj["payload"] as? [String: Any]) ?? obj
			if let uid = intVal(payload["user_id"]), uid == partnerUserId {
				let online = (payload["online"] as? Bool) ?? false
				isPartnerOnline = online
			}

		case "read_receipt":
			if let msgId = intVal(obj["message_id"]) {
				let readerId = intVal(obj["user_id"])
				if let rid = readerId, rid != currentUserId {
					readReceipts[rid] = max(readReceipts[rid] ?? 0, msgId)
					partnerReadUpToMessageId = max(partnerReadUpToMessageId, msgId)
				}
			}
			updateSeq(from: obj)

		default:
			break
		}
	}

	func handleReactionUpdate(_ obj: [String: Any]) {
		guard let msgId = intVal(obj["message_id"]),
		      let emoji = obj["emoji"] as? String,
		      let userId = intVal(obj["user_id"]),
		      let action = obj["action"] as? String,
		      let idx = messages.firstIndex(where: { $0.id == msgId })
		else { return }

		var reactions = messages[idx].reactions ?? []
		if action == "add" {
			if let rIdx = reactions.firstIndex(where: { $0.emoji == emoji }) {
				var ids = reactions[rIdx].userIds ?? []
				if !ids.contains(userId) { ids.append(userId) }
				reactions[rIdx] = MessageReaction(emoji: emoji, count: ids.count, userIds: ids)
			} else {
				reactions.append(MessageReaction(emoji: emoji, count: 1, userIds: [userId]))
			}
		} else {
			if let rIdx = reactions.firstIndex(where: { $0.emoji == emoji }) {
				let ids = (reactions[rIdx].userIds ?? []).filter { $0 != userId }
				if ids.isEmpty { reactions.remove(at: rIdx) }
				else { reactions[rIdx] = MessageReaction(emoji: emoji, count: ids.count, userIds: ids) }
			}
		}
		messages[idx].reactions = reactions
	}

	func handleTyping(_ obj: [String: Any]) {
		guard let uid = intVal(obj["user_id"]), uid != currentUserId else { return }
		let nickname = (obj["nickname"] as? String) ?? chatMembers.first(where: { $0.userId == uid })?.user.nickname ?? "User \(uid)"
		typingNicknameMap[uid] = nickname
		typingNicknames = Array(typingNicknameMap.values)
		typingTasks[uid]?.cancel()
		typingTasks[uid] = Task {
			try? await Task.sleep(nanoseconds: UIConstants.typingFadeOutSec.seconds_ns)
			guard !Task.isCancelled else { return }
			typingNicknameMap.removeValue(forKey: uid)
			typingNicknames = Array(typingNicknameMap.values)
		}
	}

	// MARK: Shared helpers (used by realtime handlers)

	func decodeMessage(from obj: [String: Any]) -> ChatMessage? {
		guard let msgId    = intVal(obj["message_id"]),
		      let payload  = obj["payload"] as? [String: Any]
		else { return nil }
		let userId = intVal(payload["user_id"])

		return ChatMessage(
			id:                        msgId,
			chatId:                    intVal(obj["chat_id"]),
			userId:                    userId,
			text:                      payload["text"] as? String,
			createdAt:                 payload["created_at"] as? String,
			editedAt:                  nil,
			deletedAt:                 nil,
			deleted:                   nil,
			replyToMessageId:          intVal(payload["reply_to_message_id"]),
			clientMessageId:           payload["client_message_id"] as? String,
			status:                    nil,
			mediaId:                   payload["media_id"] as? String,
			mediaType:                 payload["media_type"] as? String,
			forwardedFromMessageId:    intVal(payload["forwarded_from_message_id"]),
			forwardedFromUserId:       intVal(payload["forwarded_from_user_id"]),
			forwardedFromChatId:       intVal(payload["forwarded_from_chat_id"]),
			mentionUserIds:            payload["mention_user_ids"] as? [Int],
			reactions:                 nil,
			type:                      payload["type"] as? String
		)
	}

	func updateSeq(from obj: [String: Any]) {
		if let s = intVal(obj["seq"]) { latestSeq = max(latestSeq, s) }
	}

	func intVal(_ v: Any?) -> Int? {
		switch v {
		case let i as Int: return i
		case let n as NSNumber: return n.intValue
		default: return nil
		}
	}
}
