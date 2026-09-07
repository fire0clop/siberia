import Combine
import Foundation
import SwiftUI

@MainActor
final class ChatDetailViewModel: ObservableObject {
	let chatId: Int
	@Published var title: String

	// MARK: – Published — messages & loading

	@Published var messages: [ChatMessage] = []
	@Published var draft: String = ""
	@Published var error: String?
	@Published var isLoading = false
	@Published var isLoadingMore = false
	@Published var hasMoreMessages = true

	// MARK: – Published — compose

	@Published var replyingTo: ChatMessage?
	@Published var messageToForward: ChatMessage?
	@Published var mentionSuggestions: [ChatMember] = []

	// MARK: – Published — real-time indicators

	@Published var typingNicknames: [String] = []
	@Published var isPartnerOnline: Bool? = nil
	@Published var showScrollToBottom = false
	@Published var newMessagesBelowCount = 0
	@Published var partnerReadUpToMessageId: Int = 0
	/// Для групп: userId → max message_id прочитанный этим участником.
	/// В DM-чате дублирует `partnerReadUpToMessageId` ради единого источника правды.
	@Published var readReceipts: [Int: Int] = [:]

	// MARK: – Published — media & upload

	@Published var isUploadingMedia = false
	var activeUploads = 0 {
		didSet { isUploadingMedia = activeUploads > 0 }
	}
	func beginUpload() { activeUploads += 1 }
	func endUpload()   { activeUploads = max(0, activeUploads - 1) }
	@Published var mediaURLCache: [String: String] = [:]
	@Published var mediaThumbURLCache: [String: String] = [:]
	@Published var mediaOriginalNames: [String: String] = [:]
	@Published var mediaMimeTypes: [String: String] = [:]
	@Published var mediaDurations: [String: Int]    = [:]
	@Published var mediaWaveforms: [String: [Float]] = [:]
	@Published var videoThumbnailCache: [String: UIImage] = [:]
	/// Сообщения, где пользователь раскрыл спойлеры (tap-to-reveal)
	@Published var revealedSpoilerMessageIds: Set<Int> = []
	/// Бюджет ретраев битого медиа (см. retryMediaLoad) + метка «безнадёжно»
	var mediaRetryCounts: [String: Int] = [:]
	@Published var failedMediaIds: Set<String> = []
	/// Incremented after every outgoing message so the view can force-scroll to bottom
	@Published var scrollToBottomSignal: Int = 0
	/// Set to a message ID to trigger a scroll-to in ChatDetailView (reset to nil after consuming)
	@Published var jumpToMessageId: Int? = nil
	/// После подгрузки старых сообщений (loadMore) — id сообщения, к которому
	/// нужно вернуть вьюпорт, чтобы он не прыгнул на новую верхушку списка.
	@Published var restoreScrollToId: Int? = nil

	/// The other participant in a 1-on-1 chat
	var otherMember: ChatMember? {
		chatMembers.first { $0.userId != currentUserId }
	}

	/// mediaId → messageId lookup (for "go to message" from media gallery)
	var mediaToMessageId: [String: Int] {
		var dict: [String: Int] = [:]
		for msg in messages { if let mid = msg.mediaId { dict[mid] = msg.id } }
		return dict
	}

	/// All non-deleted image mediaIds in message order (for gallery)
	var allImageMediaIds: [String] {
		messages.compactMap { m in
			guard m.mediaType == "image", !m.isDeleted,
			      let mid = m.mediaId, mid != "pending" else { return nil }
			return mid
		}
	}

	/// All non-deleted image+video items in message order (for the full-screen gallery)
	var allMediaItems: [GalleryMediaItem] {
		messages.compactMap { m in
			guard let mid = m.mediaId, mid != "pending", !m.isDeleted,
			      let type = m.mediaType,
			      type == "image" || type == "video" || type == "video_note"
			else { return nil }
			return GalleryMediaItem(id: mid, type: type)
		}
	}

	// MARK: – Published — chat meta

	@Published var pinnedMessage: ChatMessage?
	@Published var chatMembers: [ChatMember] = []
	@Published var isGroup: Bool = false
	/// Тип чата с бэка: "private" / "group" / "channel" / "saved". nil — ещё не загружен.
	@Published var chatType: String? = nil

	var isChannel: Bool { chatType == "channel" }
	/// true только когда тип уже загружен и это DM. Не путать с "!isGroup":
	/// канал тоже не группа, и раньше он рендерился как личный чат —
	/// с кнопками звонка и «Заблокировать» на случайного подписчика.
	var isPrivateChat: Bool { chatType == "private" }
	var myRole: String? {
		guard let me = currentUserId else { return nil }
		return chatMembers.first(where: { $0.userId == me })?.role
	}
	/// Подписчик канала не может писать (бэкенд отвечает 403) — прячем композер.
	var isReadOnlyChannel: Bool {
		isChannel && !(myRole == "owner" || myRole == "admin")
	}

	// MARK: – Private

	var latestSeq: Int
	let socket = RealtimeSocket()
	private(set) var currentUserId: Int?
	var partnerUserId: Int?
	var pendingClientIds: Set<String> = []
	var typingTasks: [Int: Task<Void, Never>] = [:]
	var typingNicknameMap: [Int: String] = [:]
	var presenceTask: Task<Void, Never>?
	private var presenceObserver: NSObjectProtocol?
	var typingDebounceTask: Task<Void, Never>?
	var isAtBottom = true
	var pendingIdCounter = -1

	// MARK: – Init

	init(chatId: Int, title: String, initialSyncSeq: Int) {
		self.chatId = chatId
		self.title = title
		self.latestSeq = initialSyncSeq
		subscribePresenceUpdates()
	}

	deinit {
		if let obs = presenceObserver {
			NotificationCenter.default.removeObserver(obs)
		}
	}

	private func subscribePresenceUpdates() {
		presenceObserver = NotificationCenter.default.addObserver(
			forName: .siberiaPresenceChange,
			object: nil,
			queue: .main
		) { [weak self] note in
			guard let self,
			      let info = note.userInfo,
			      let uid = info["user_id"] as? Int,
			      uid == self.partnerUserId
			else { return }
			let online = (info["online"] as? Bool) ?? false
			Task { @MainActor [weak self] in
				self?.isPartnerOnline = online
			}
		}
	}

	// MARK: – Public helpers

	func isMine(_ m: ChatMessage) -> Bool { m.userId == currentUserId }

	func isPending(_ m: ChatMessage) -> Bool {
		guard let cid = m.clientMessageId else { return false }
		return pendingClientIds.contains(cid)
	}

	func myReaction(on m: ChatMessage) -> String? {
		guard let uid = currentUserId else { return nil }
		return m.reactions?.first { $0.userIds?.contains(uid) == true }?.emoji
	}

	// MARK: – Lifecycle

	func onAppear() async {
		ActiveChatTracker.setActiveChat(chatId)
		isLoading = true
		error = nil
		// Покажем кэш мгновенно — даже без сети будет видно последние 100 сообщений
		let cached = ChatCacheService.shared.loadMessages(chatId: chatId)
		if !cached.isEmpty {
			messages = cached.sorted { $0.id < $1.id }
		}
		if currentUserId == nil, let me = try? await UserService.shared.me() {
			currentUserId = me.id
		}
		await loadMessages()
		// .task отменяется при уходе с экрана; без этих гардов ушедший
		// пользователь получал заново открытый сокет и вечный presence-polling
		// (onDisappear уже отработал) — утечка VM + живого WS на каждый чат.
		guard !Task.isCancelled else { return }
		await markRead()
		await loadChatMeta()
		guard !Task.isCancelled else { isLoading = false; return }
		try? await runSync()
		guard !Task.isCancelled else { isLoading = false; return }
		await connectSocket()
		// Если предыдущая сессия что-то не дослала — добиваем сейчас.
		await flushPendingQueue()
		isLoading = false
	}

	/// Возврат из фона: чат-сокет мог умереть в suspend — проверяем ping'ом.
	func ensureSocketAlive() async {
		await socket.ensureConnected()
	}

	func onDisappear() async {
		await saveDraftIfNeeded()
		ActiveChatTracker.setActiveChat(nil)
		await socket.disconnect()
		presenceTask?.cancel()
		typingDebounceTask?.cancel()
		typingTasks.values.forEach { $0.cancel() }
		typingTasks.removeAll()
	}

	func setAtBottom(_ atBottom: Bool) {
		isAtBottom = atBottom
		if atBottom {
			newMessagesBelowCount = 0
			showScrollToBottom = false
			Task { await markRead() }
		} else {
			showScrollToBottom = true
		}
	}

	// MARK: – Load messages

	func loadMessages() async {
		do {
			let batch = try await ChatService.shared.messages(chatId: chatId, limit: 50)
			hasMoreMessages = batch.count >= 50
			let pending = messages.filter { isPending($0) }
			var sorted = batch.sorted { $0.id < $1.id }
			for p in pending where !sorted.contains(where: { $0.id == p.id }) { sorted.append(p) }
			messages = sorted
			// Сохраняем на диск для offline-старта (последние 100 финальных сообщений)
			ChatCacheService.shared.saveMessages(chatId: chatId, messages: messages)
		} catch {
			self.error = error.localizedDescription
		}
	}

	func loadMore() async {
		guard hasMoreMessages, !isLoadingMore,
		      let firstId = messages.first(where: { $0.id > 0 })?.id
		else { return }
		isLoadingMore = true
		defer { isLoadingMore = false }
		do {
			let batch = try await ChatService.shared.messages(chatId: chatId, limit: 50, beforeId: firstId)
			hasMoreMessages = batch.count >= 50
			let existingIds = Set(messages.map(\.id))
			let fresh = batch.sorted { $0.id < $1.id }.filter { !existingIds.contains($0.id) }
			guard !fresh.isEmpty else { return }
			messages = fresh + messages
			// Возвращаем вьюпорт на бывшую верхнюю границу, иначе после prepend
			// список прыгает наверх и снова триггерит loadMore (каскад).
			restoreScrollToId = firstId
		} catch {
			self.error = error.localizedDescription
		}
	}

	/// После реконнекта: подтягиваем свежие сообщения и правки, НЕ выбрасывая
	/// уже загруженную вверх историю. Раньше здесь звался loadMessages(), он
	/// заменял всё последними 50 и терял пролистанное + сбрасывал hasMoreMessages.
	func reconcileAfterReconnect() async {
		do {
			let batch = try await ChatService.shared.messages(chatId: chatId, limit: 50)
			// upsert по id: свежие правки/удаления в пределах окна применяются,
			// новые сообщения добавляются, старая история сохраняется.
			var byId: [Int: ChatMessage] = [:]
			for m in messages where !isPending(m) { byId[m.id] = m }
			for m in batch { byId[m.id] = m }
			var merged = Array(byId.values).sorted { $0.id < $1.id }
			// Сохраняем неотправленные (pending) сообщения в хвосте
			let pending = messages.filter { isPending($0) }
			for p in pending where !merged.contains(where: { $0.id == p.id }) { merged.append(p) }
			messages = merged
			ChatCacheService.shared.saveMessages(chatId: chatId, messages: messages)
		} catch {
			Log.chat.error("reconcileAfterReconnect failed: \(String(describing: error))")
		}
	}

	// MARK: – Chat meta (members, pinned, draft)

	private func loadChatMeta() async {
		async let membersTask = ChatService.shared.members(chatId: chatId)
		async let detailTask = ChatService.shared.chatDetail(chatId: chatId)

		// Если currentUserId всё ещё nil (например /users/me упал) — повторяем
		// перед тем как искать партнёра, иначе .first(where: !=nil) вернёт нас самих.
		if currentUserId == nil {
			do {
				let me = try await UserService.shared.me()
				currentUserId = me.id
			} catch {
				Log.chat.error("me() failed in loadChatMeta: \(String(describing: error))")
			}
		}

		// Сначала тип чата: до него нельзя решать, «личный» ли это чат.
		// Раньше title/presence/partner выставлялись по первому «не-я» участнику
		// БЕЗ проверки типа — группа и канал рендерились как DM (кнопки звонка
		// и «Заблокировать» доставались случайному участнику).
		do {
			let detail = try await detailTask
			chatType = detail.type
			isGroup = (detail.type == "group")
			// Restore draft if nothing typed yet
			if draft.isEmpty, let draftText = detail.draftText, !draftText.isEmpty {
				draft = draftText
			}
			// Pin
			if let pid = detail.pinnedMessageId {
				pinnedMessage = messages.first(where: { $0.id == pid })
			}
		} catch {
			Log.chat.error("chatDetail fetch failed: \(String(describing: error))")
		}

		do {
			let members = try await membersTask
			chatMembers = members
			// Инициализируем галочки прочтения с бэка — раньше readReceipts
			// заполнялись только live-событиями, и до первого read_receipt
			// все свои сообщения показывали одну галку.
			for m in members {
				guard m.userId != currentUserId, let lr = m.lastReadMessageId else { continue }
				readReceipts[m.userId] = max(readReceipts[m.userId] ?? 0, lr)
				partnerReadUpToMessageId = max(partnerReadUpToMessageId, lr)
			}
			// Resolve title from partner nickname — ТОЛЬКО для DM
			// (backend may return nil/generic title)
			if isPrivateChat,
			   let myId = currentUserId,
			   let nick = members.first(where: { $0.userId != myId })?.user.nickname {
				title = nick
			}
			// Presence — только для DM (и только если экран ещё жив:
			// после отмены .task запускать вечный polling — утечка)
			if isPrivateChat,
			   let myId = currentUserId,
			   let other = members.first(where: { $0.userId != myId }),
			   !Task.isCancelled {
				partnerUserId = other.userId
				await fetchPresence()
				if !Task.isCancelled { startPresencePolling() }
			}
		} catch {
			Log.chat.error("members fetch failed: \(String(describing: error))")
		}
	}

	// MARK: – Sync

	func runSync() async throws {
		let r = try await ChatService.shared.sync(chatId: chatId, afterSeq: latestSeq)
		// Применяем удаления к уже загруженным сообщениям — для этого достаточно
		// messageId из sync, без запроса деталей. Раньше updates просто
		// выбрасывались (хранился только latestSeq). Правки/реакции вне окна
		// подхватывает reconcileAfterReconnect (merge последних 50).
		for u in r.updates where u.event == "message_delete" {
			guard let mid = u.messageId,
			      let idx = messages.firstIndex(where: { $0.id == mid }),
			      !messages[idx].isDeleted else { continue }
			messages[idx] = softDeleted(messages[idx])
		}
		latestSeq = r.latestSeq
	}

	// MARK: – Mark read

	func markRead() async {
		guard let lastId = messages.last(where: { !isPending($0) })?.id else { return }
		try? await ChatService.shared.markRead(chatId: chatId, messageId: lastId)
	}

	// MARK: – Drafts

	private func saveDraftIfNeeded() async {
		let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty {
			try? await ChatService.shared.deleteDraft(chatId: chatId)
		} else {
			try? await ChatService.shared.saveDraft(chatId: chatId, text: t)
		}
	}

	// MARK: – Send text

	func send() async {
		let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !raw.isEmpty else { return }
		// Markdown → чистый текст + entities (Telegram-модель: сервер и другие
		// клиенты видят уже разобранную разметку)
		let parsed = MarkdownParser.parse(raw)
		let t = parsed.text
		let entities = parsed.entities.isEmpty ? nil : parsed.entities
		let replyId = replyingTo?.id
		let mentionIds = extractMentionIds(from: t)
		draft = ""
		replyingTo = nil
		mentionSuggestions = []

		let clientId = UUID()
		var pending = makePendingMessage(text: t, clientId: clientId, replyTo: replyId)
		pending.entities = entities
		pendingClientIds.insert(clientId.uuidString)
		upsert(pending)
		scrollToBottomSignal += 1

		// Кладём в персистентную очередь — если приложение упадёт или нет сети,
		// сообщение всё равно дошлётся при следующем reconnect.
		ChatCacheService.shared.enqueueOutgoing(.init(
			chatId: chatId,
			clientMessageId: clientId.uuidString,
			text: t,
			replyToMessageId: replyId,
			mediaId: nil,
			createdAt: Date().timeIntervalSince1970,
			entities: entities
		))

		do {
			let r = try await ChatService.shared.sendMessage(
				chatId: chatId, text: t,
				clientMessageId: clientId, replyTo: replyId,
				mentionUserIds: mentionIds.isEmpty ? nil : mentionIds,
				entities: entities
			)
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString && $0.id < 0 }
			upsert(r.message.withResolvedChatId(chatId))
			ChatCacheService.shared.dequeueOutgoing(clientMessageId: clientId.uuidString)
			try? await ChatService.shared.deleteDraft(chatId: chatId)
		} catch {
			// Не удаляем из persistent-очереди — переотправим при reconnect.
			// В UI оставляем pending bubble.
			Log.chat.warning("send failed, will retry on reconnect: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	/// Дочитывает persistent-очередь после reconnect и пытается отправить.
	func flushPendingQueue() async {
		let queue = ChatCacheService.shared.pendingOutgoing(chatId: chatId)
		for item in queue {
			// Если в текущей session уже отправили (id > 0 с тем же clientMessageId),
			// просто удаляем из очереди — серверу повторно не нужно.
			if messages.contains(where: { $0.clientMessageId == item.clientMessageId && $0.id > 0 }) {
				ChatCacheService.shared.dequeueOutgoing(clientMessageId: item.clientMessageId)
				continue
			}
			guard let cid = UUID(uuidString: item.clientMessageId) else {
				ChatCacheService.shared.dequeueOutgoing(clientMessageId: item.clientMessageId)
				continue
			}
			do {
				let r = try await ChatService.shared.sendMessage(
					chatId: chatId, text: item.text,
					clientMessageId: cid,
					replyTo: item.replyToMessageId,
					mediaId: item.mediaId,
					entities: item.entities
				)
				pendingClientIds.remove(item.clientMessageId)
				messages.removeAll { $0.clientMessageId == item.clientMessageId && $0.id < 0 }
				upsert(r.message.withResolvedChatId(chatId))
				ChatCacheService.shared.dequeueOutgoing(clientMessageId: item.clientMessageId)
				Log.chat.info("Flushed pending message \(item.clientMessageId)")
			} catch {
				Log.chat.warning("Pending flush failed for \(item.clientMessageId): \(String(describing: error))")
				// Оставляем в очереди до следующего reconnect
				break
			}
		}
	}

	// MARK: – Forward

	func forwardMessage(_ m: ChatMessage, to targetChatId: Int) async {
		do {
			let r = try await ChatService.shared.sendMessage(
				chatId: targetChatId, text: nil,
				forwardMessageId: m.id
			)
			if targetChatId == chatId {
				upsert(r.message.withResolvedChatId(chatId))
			}
		} catch {
			self.error = error.localizedDescription
		}
		messageToForward = nil
	}

	// MARK: – Reactions

	func toggleReaction(_ emoji: String, on m: ChatMessage) async {
		let alreadyMine = m.reactions?.first(where: { $0.emoji == emoji })?.userIds?.contains(currentUserId ?? -1) ?? false
		do {
			if alreadyMine {
				try await ChatService.shared.removeReaction(messageId: m.id, emoji: emoji)
			} else {
				try await ChatService.shared.addReaction(messageId: m.id, emoji: emoji)
			}
		} catch {
			self.error = error.localizedDescription
		}
	}

	// MARK: – Edit / Delete

	/// Может ли текущий пользователь удалить сообщение «у всех»:
	/// своё — всегда; чужое — если он owner/admin группы или канала.
	func canDeleteForEveryone(_ m: ChatMessage) -> Bool {
		guard !isPending(m) else { return false }
		if isMine(m) { return true }
		return (isGroup || isChannel) && (myRole == "owner" || myRole == "admin")
	}

	func deleteMessage(_ m: ChatMessage) async {
		guard canDeleteForEveryone(m) else { return }
		do {
			try await ChatService.shared.deleteMessage(messageId: m.id)
			if let idx = messages.firstIndex(where: { $0.id == m.id }) {
				messages[idx] = softDeleted(m)
			}
		} catch {
			self.error = error.localizedDescription
		}
	}

	/// Remove message only from the local messages array and cache (no server call).
	func deleteMessageLocally(_ m: ChatMessage) {
		messages.removeAll { $0.id == m.id }
		debouncedSaveCache()
	}

	func editMessage(_ m: ChatMessage, newText: String) async {
		guard m.userId == currentUserId else { return }
		do {
			let parsed = MarkdownParser.parse(newText)
			let updated = try await ChatService.shared.editMessage(
				messageId: m.id, newText: parsed.text,
				entities: parsed.entities.isEmpty ? nil : parsed.entities
			)
			upsert(updated.withResolvedChatId(chatId))
		} catch {
			self.error = error.localizedDescription
		}
	}

	// MARK: – Helpers

	func upsert(_ m: ChatMessage) {
		if let idx = messages.firstIndex(where: { $0.id == m.id }) {
			messages[idx] = m
		} else {
			messages.append(m)
			messages.sort { $0.id < $1.id }
		}
		// Сохраняем cache «лениво» — не на каждый upsert (слишком часто),
		// а только если прошло > 2 секунд с последнего сохранения.
		debouncedSaveCache()
	}

	var lastCacheSaveTime: Date = .distantPast
	var cacheSaveTask: Task<Void, Never>?

	private func debouncedSaveCache() {
		cacheSaveTask?.cancel()
		cacheSaveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			guard !Task.isCancelled, let self else { return }
			ChatCacheService.shared.saveMessages(chatId: self.chatId, messages: self.messages)
		}
	}

	func softDeleted(_ m: ChatMessage) -> ChatMessage {
		ChatMessage(
			id: m.id, chatId: m.chatId, userId: m.userId,
			text: nil, createdAt: m.createdAt, editedAt: nil,
			deletedAt: ISO8601DateFormatter().string(from: Date()),
			deleted: true, replyToMessageId: nil, clientMessageId: nil, status: nil,
			mediaId: nil, mediaType: nil,
			forwardedFromMessageId: nil, forwardedFromUserId: nil, forwardedFromChatId: nil,
			mentionUserIds: nil, reactions: nil,
			type: m.type
		)
	}

	func makePendingMessage(
		text: String?, clientId: UUID, replyTo: Int?,
		mediaId: String? = nil, mediaType: String? = nil
	) -> ChatMessage {
		pendingIdCounter -= 1
		return ChatMessage(
			id: pendingIdCounter, chatId: chatId,
			userId: currentUserId ?? 0, text: text,
			createdAt: ISO8601DateFormatter().string(from: Date()),
			editedAt: nil, deletedAt: nil, deleted: nil,
			replyToMessageId: replyTo,
			clientMessageId: clientId.uuidString, status: "pending",
			mediaId: mediaId, mediaType: mediaType,
			forwardedFromMessageId: nil, forwardedFromUserId: nil, forwardedFromChatId: nil,
			mentionUserIds: nil, reactions: nil,
			type: "text"
		)
	}

	private func extractMentionIds(from text: String) -> [Int] {
		text.components(separatedBy: CharacterSet.whitespaces)
			.filter { $0.hasPrefix("@") }
			.compactMap { word in
				let nick = String(word.dropFirst()).trimmingCharacters(in: .punctuationCharacters)
				return chatMembers.first { $0.user.nickname == nick }?.userId
			}
	}
}
