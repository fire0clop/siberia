import Foundation

final class ChatCacheService {
    static let shared = ChatCacheService()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private init() {}

    // MARK: – Chats

    func saveChats(_ chats: [ChatSummary]) {
        write(chats, to: "sib_chats.json")
    }

    func loadChats() -> [ChatSummary] {
        read([ChatSummary].self, from: "sib_chats.json") ?? []
    }

    // MARK: – Last messages

    func saveLastMessages(_ msgs: [Int: ChatMessage]) {
        let arr = msgs.map { CachedMsg(chatId: $0.key, message: $0.value) }
        write(arr, to: "sib_last_msgs.json")
    }

    func loadLastMessages() -> [Int: ChatMessage] {
        guard let arr = read([CachedMsg].self, from: "sib_last_msgs.json") else { return [:] }
        return Dictionary(uniqueKeysWithValues: arr.map { ($0.chatId, $0.message) })
    }

    // MARK: – Member names / avatars

    func saveMemberInfo(names: [Int: String], avatars: [Int: String]) {
        let payload = CachedMemberInfo(
            names:   names.map   { CachedPair(chatId: $0.key, value: $0.value) },
            avatars: avatars.map { CachedPair(chatId: $0.key, value: $0.value) }
        )
        write(payload, to: "sib_members.json")
    }

    func loadMemberInfo() -> (names: [Int: String], avatars: [Int: String]) {
        guard let p = read(CachedMemberInfo.self, from: "sib_members.json") else { return ([:], [:]) }
        let names   = Dictionary(uniqueKeysWithValues: p.names.map   { ($0.chatId, $0.value) })
        let avatars = Dictionary(uniqueKeysWithValues: p.avatars.map { ($0.chatId, $0.value) })
        return (names, avatars)
    }

    // MARK: – Per-chat message history
    //
    // Храним до 100 последних сообщений каждого чата в отдельных JSON-файлах
    // (sib_chat_{id}.json). При offline / медленной сети — сразу показываем
    // кэш, потом догружаем актуальные сообщения с сервера.

    private static let maxCachedPerChat = 100

    func saveMessages(chatId: Int, messages: [ChatMessage]) {
        // оставляем только финальные (id > 0) и обрезаем сверху до 100 последних
        let final = messages.filter { $0.id > 0 }
        let tail = final.suffix(Self.maxCachedPerChat)
        write(Array(tail), to: "sib_chat_\(chatId).json")
    }

    func loadMessages(chatId: Int) -> [ChatMessage] {
        read([ChatMessage].self, from: "sib_chat_\(chatId).json") ?? []
    }

    func dropMessages(chatId: Int) {
        let url = dir.appendingPathComponent("sib_chat_\(chatId).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Полностью очищаем кэш (например при logout).
    func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasPrefix("sib_") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: – Pending outgoing messages (persisted across launches)
    //
    // Когда пользователь шлёт сообщение в offline — кладём его сюда. При следующем
    // подключении ChatDetailViewModel дочитывает очередь и шлёт на сервер.
    // Каждое сообщение жёстко привязано к чату + clientMessageId (UUID), чтобы
    // сервер игнорировал дубль если оно всё-таки доставилось ранее.

    struct PendingOutgoing: Codable, Equatable {
        let chatId: Int
        let clientMessageId: String
        let text: String?
        let replyToMessageId: Int?
        let mediaId: String?
        let createdAt: TimeInterval
    }

    func saveOutgoingQueue(_ items: [PendingOutgoing]) {
        write(items, to: "sib_pending_out.json")
    }

    func loadOutgoingQueue() -> [PendingOutgoing] {
        read([PendingOutgoing].self, from: "sib_pending_out.json") ?? []
    }

    func enqueueOutgoing(_ item: PendingOutgoing) {
        var q = loadOutgoingQueue()
        // Защита от дублей по clientMessageId
        q.removeAll { $0.clientMessageId == item.clientMessageId }
        q.append(item)
        saveOutgoingQueue(q)
    }

    func dequeueOutgoing(clientMessageId: String) {
        var q = loadOutgoingQueue()
        q.removeAll { $0.clientMessageId == clientMessageId }
        saveOutgoingQueue(q)
    }

    func pendingOutgoing(chatId: Int) -> [PendingOutgoing] {
        loadOutgoingQueue().filter { $0.chatId == chatId }
    }

    // MARK: – Helpers

    private func write<T: Encodable>(_ value: T, to filename: String) {
        let url = dir.appendingPathComponent(filename)
        try? encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

private struct CachedMsg: Codable {
    let chatId: Int
    let message: ChatMessage
}

private struct CachedPair: Codable {
    let chatId: Int
    let value: String
}

private struct CachedMemberInfo: Codable {
    let names:   [CachedPair]
    let avatars: [CachedPair]
}
