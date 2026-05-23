import XCTest
@testable import Siberia

final class ChatCacheServiceTests: XCTestCase {

	// Use a throw-away cache instance backed by the real Caches dir — cleared in setUp.
	private let sut = ChatCacheService.shared

	override func setUp() {
		super.setUp()
		sut.clearAll()
	}

	override func tearDown() {
		sut.clearAll()
		super.tearDown()
	}

	// MARK: – Messages

	func testSaveAndLoadMessages() {
		let msgs = [
			makeMessage(id: 1, chatId: 42, text: "Hello"),
			makeMessage(id: 2, chatId: 42, text: "World"),
		]
		sut.saveMessages(chatId: 42, messages: msgs)
		let loaded = sut.loadMessages(chatId: 42)
		XCTAssertEqual(loaded.map(\.id), [1, 2])
	}

	func testLoadMessagesReturnsEmptyWhenNothingCached() {
		let loaded = sut.loadMessages(chatId: 999)
		XCTAssertTrue(loaded.isEmpty)
	}

	func testSaveMessagesTruncatesTo100() {
		let msgs = (1...150).map { makeMessage(id: $0, chatId: 10, text: "msg \($0)") }
		sut.saveMessages(chatId: 10, messages: msgs)
		let loaded = sut.loadMessages(chatId: 10)
		XCTAssertEqual(loaded.count, 100)
		// Should keep the last 100 (ids 51–150)
		XCTAssertEqual(loaded.first?.id, 51)
		XCTAssertEqual(loaded.last?.id, 150)
	}

	func testSaveMessagesIgnoresPendingMessages() {
		// Pending messages have id < 0
		let msgs = [
			makeMessage(id: -1, chatId: 5, text: "pending"),
			makeMessage(id: 1,  chatId: 5, text: "real"),
		]
		sut.saveMessages(chatId: 5, messages: msgs)
		let loaded = sut.loadMessages(chatId: 5)
		XCTAssertEqual(loaded.count, 1)
		XCTAssertEqual(loaded.first?.id, 1)
	}

	func testDropMessagesRemovesCache() {
		let msgs = [makeMessage(id: 1, chatId: 7, text: "hi")]
		sut.saveMessages(chatId: 7, messages: msgs)
		sut.dropMessages(chatId: 7)
		XCTAssertTrue(sut.loadMessages(chatId: 7).isEmpty)
	}

	// MARK: – Pending outgoing queue

	func testEnqueueAndDequeue() {
		let item = makePending(chatId: 1, clientId: "aaa", text: "hello")
		sut.enqueueOutgoing(item)
		let pending = sut.pendingOutgoing(chatId: 1)
		XCTAssertEqual(pending.count, 1)
		XCTAssertEqual(pending.first?.clientMessageId, "aaa")

		sut.dequeueOutgoing(clientMessageId: "aaa")
		XCTAssertTrue(sut.pendingOutgoing(chatId: 1).isEmpty)
	}

	func testEnqueueDeduplicatesByClientId() {
		let item = makePending(chatId: 1, clientId: "dup", text: "first")
		let dup  = makePending(chatId: 1, clientId: "dup", text: "second")
		sut.enqueueOutgoing(item)
		sut.enqueueOutgoing(dup)
		let pending = sut.pendingOutgoing(chatId: 1)
		XCTAssertEqual(pending.count, 1)
		XCTAssertEqual(pending.first?.text, "second")
	}

	func testPendingOutgoingFiltersPerChat() {
		sut.enqueueOutgoing(makePending(chatId: 1, clientId: "x1", text: "chat1"))
		sut.enqueueOutgoing(makePending(chatId: 2, clientId: "x2", text: "chat2"))
		XCTAssertEqual(sut.pendingOutgoing(chatId: 1).count, 1)
		XCTAssertEqual(sut.pendingOutgoing(chatId: 2).count, 1)
		XCTAssertTrue(sut.pendingOutgoing(chatId: 3).isEmpty)
	}

	// MARK: – Chats

	func testSaveAndLoadChats() {
		let chats = [makeChatSummary(id: 1, title: "Alpha"), makeChatSummary(id: 2, title: "Beta")]
		sut.saveChats(chats)
		let loaded = sut.loadChats()
		XCTAssertEqual(loaded.map(\.id), [1, 2])
	}

	func testLoadChatsReturnsEmptyWhenNothingCached() {
		XCTAssertTrue(sut.loadChats().isEmpty)
	}

	// MARK: – clearAll

	func testClearAllRemovesEverything() {
		sut.saveMessages(chatId: 1, messages: [makeMessage(id: 1, chatId: 1, text: "x")])
		sut.saveChats([makeChatSummary(id: 1, title: "X")])
		sut.enqueueOutgoing(makePending(chatId: 1, clientId: "z", text: "z"))
		sut.clearAll()
		XCTAssertTrue(sut.loadMessages(chatId: 1).isEmpty)
		XCTAssertTrue(sut.loadChats().isEmpty)
		XCTAssertTrue(sut.pendingOutgoing(chatId: 1).isEmpty)
	}

	// MARK: – Factories

	private func makeMessage(id: Int, chatId: Int, text: String) -> ChatMessage {
		ChatMessage(
			id: id, chatId: chatId, userId: 1,
			text: text,
			createdAt: "2025-01-01T00:00:00Z",
			editedAt: nil, deletedAt: nil, deleted: nil,
			replyToMessageId: nil, clientMessageId: nil, status: nil,
			mediaId: nil, mediaType: nil,
			forwardedFromMessageId: nil, forwardedFromUserId: nil, forwardedFromChatId: nil,
			mentionUserIds: nil, reactions: nil,
			type: "text"
		)
	}

	private func makePending(chatId: Int, clientId: String, text: String) -> ChatCacheService.PendingOutgoing {
		ChatCacheService.PendingOutgoing(
			chatId: chatId,
			clientMessageId: clientId,
			text: text,
			replyToMessageId: nil,
			mediaId: nil,
			createdAt: Date().timeIntervalSince1970
		)
	}

	private func makeChatSummary(id: Int, title: String) -> ChatSummary {
		ChatSummary(
			id: id, type: "dm", title: title,
			lastMessage: nil, unreadCount: 0,
			avatarMediaId: nil, draftText: nil,
			pinnedMessageId: nil, syncSeq: 0
		)
	}
}
