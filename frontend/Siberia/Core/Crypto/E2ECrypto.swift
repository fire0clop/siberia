// Core/Crypto/E2ECrypto.swift
//
// E2E-шифрование секретных чатов (v1).
//
// Схема:
//   identity: X25519-ключ устройства (приватный — только в Keychain,
//             публичный публикуется на сервер PUT /e2e/keys)
//   handshake: создатель чата генерирует эфемерную X25519-пару и шлёт
//              eph_pub на сервер вместе с созданием чата
//   ключ чата: creator: X25519(eph_priv, peer_identity_pub)
//              peer:    X25519(identity_priv, eph_pub)
//              → HKDF-SHA256(salt="siberia-e2e-v1", info="siberia:chat:<id>") → 32B
//   сообщения: AES-GCM(chatKey); блоб = base64(nonce||ciphertext||tag) —
//              это ровно SealedBox.combined.
//
// Ограничения v1 (сознательные): нет per-message ratchet; одно устройство
// (новый identity-ключ = старые секретные чаты нечитаемы); ключ чата
// хранится в Keychain и выводится создателем ровно один раз.

import CryptoKit
import Foundation

// MARK: – Чистые функции (без Keychain — покрыты юнит-тестами)

enum E2ECore {

	static let hkdfSalt = Data("siberia-e2e-v1".utf8)

	static func chatKeyInfo(chatId: Int) -> Data {
		Data("siberia:chat:\(chatId)".utf8)
	}

	/// SharedSecret → 32-байтовый ключ чата
	static func deriveChatKey(sharedSecret: SharedSecret, chatId: Int) -> SymmetricKey {
		sharedSecret.hkdfDerivedSymmetricKey(
			using: SHA256.self,
			salt: hkdfSalt,
			sharedInfo: chatKeyInfo(chatId: chatId),
			outputByteCount: 32
		)
	}

	/// Путь создателя: eph_priv + identity_pub собеседника
	static func creatorChatKey(
		ephPriv: Curve25519.KeyAgreement.PrivateKey,
		peerIdentityPub: Curve25519.KeyAgreement.PublicKey,
		chatId: Int
	) throws -> SymmetricKey {
		let shared = try ephPriv.sharedSecretFromKeyAgreement(with: peerIdentityPub)
		return deriveChatKey(sharedSecret: shared, chatId: chatId)
	}

	/// Путь собеседника: свой identity_priv + eph_pub создателя
	static func peerChatKey(
		identityPriv: Curve25519.KeyAgreement.PrivateKey,
		ephPub: Curve25519.KeyAgreement.PublicKey,
		chatId: Int
	) throws -> SymmetricKey {
		let shared = try identityPriv.sharedSecretFromKeyAgreement(with: ephPub)
		return deriveChatKey(sharedSecret: shared, chatId: chatId)
	}

	/// Плейнтекст → base64(nonce||ct||tag). Внутри — JSON-конверт (запас на будущее).
	static func encrypt(text: String, key: SymmetricKey) throws -> String {
		let envelope: [String: Any] = ["v": 1, "text": text]
		let plaintext = try JSONSerialization.data(withJSONObject: envelope)
		let box = try AES.GCM.seal(plaintext, using: key)
		guard let combined = box.combined else {
			throw CocoaError(.coderInvalidValue)
		}
		return combined.base64EncodedString()
	}

	/// base64-блоб → текст; nil если ключ не тот или блоб повреждён.
	static func decrypt(blobB64: String, key: SymmetricKey) -> String? {
		guard let combined = Data(base64Encoded: blobB64),
		      let box = try? AES.GCM.SealedBox(combined: combined),
		      let plaintext = try? AES.GCM.open(box, using: key),
		      let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
		else { return nil }
		return obj["text"] as? String
	}

	static func publicKeyB64(_ priv: Curve25519.KeyAgreement.PrivateKey) -> String {
		priv.publicKey.rawRepresentation.base64EncodedString()
	}

	static func publicKey(fromB64 b64: String) -> Curve25519.KeyAgreement.PublicKey? {
		guard let raw = Data(base64Encoded: b64), raw.count == 32 else { return nil }
		return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
	}
}

// MARK: – Handshake-модель (зеркало chats.e2e_handshake)

struct E2EHandshake: Codable, Equatable, Hashable {
	let v: Int?
	let creatorId: Int
	let ephPub: String
	let creatorIdentityPub: String
	let peerIdentityPub: String
}

// MARK: – Сервис (Keychain + API)

@MainActor
final class E2ECrypto {
	static let shared = E2ECrypto()
	private init() {}

	private let service = "com.siberia.e2e"
	private let identityAccount = "identity_key"

	// MARK: Keychain (raw Data)

	private func keychainQuery(_ account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
	}

	private func readData(_ account: String) -> Data? {
		var q = keychainQuery(account)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	private func writeData(_ data: Data, _ account: String) {
		let attrs: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
		]
		let status = SecItemUpdate(keychainQuery(account) as CFDictionary, attrs as CFDictionary)
		if status == errSecItemNotFound {
			var add = keychainQuery(account)
			add.merge(attrs) { _, new in new }
			let addStatus = SecItemAdd(add as CFDictionary, nil)
			if addStatus != errSecSuccess {
				Log.auth.error("E2E keychain add failed: \(addStatus)")
			}
		} else if status != errSecSuccess {
			Log.auth.error("E2E keychain update failed: \(status)")
		}
	}

	// MARK: Identity key

	/// Возвращает identity-ключ устройства, создавая при первом обращении.
	func identityKey() -> Curve25519.KeyAgreement.PrivateKey {
		if let raw = readData(identityAccount),
		   let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
			return key
		}
		let key = Curve25519.KeyAgreement.PrivateKey()
		writeData(key.rawRepresentation, identityAccount)
		return key
	}

	/// Публикует публичный ключ на бэке (идемпотентно, best-effort).
	func publishKeyIfNeeded() async {
		let pub = E2ECore.publicKeyB64(identityKey())
		do {
			let body = try JSONSerialization.data(withJSONObject: ["public_key": pub])
			_ = try await APIClient.shared.request(path: "/e2e/keys", method: "PUT", body: body)
		} catch {
			Log.auth.warning("E2E key publish failed: \(String(describing: error))")
		}
	}

	// MARK: Chat keys

	private func chatKeyAccount(_ chatId: Int) -> String { "chat_key_\(chatId)" }

	private func storedChatKey(_ chatId: Int) -> SymmetricKey? {
		readData(chatKeyAccount(chatId)).map { SymmetricKey(data: $0) }
	}

	private func storeChatKey(_ key: SymmetricKey, chatId: Int) {
		let raw = key.withUnsafeBytes { Data($0) }
		writeData(raw, chatKeyAccount(chatId))
	}

	/// Создание секретного чата: эфемерная пара → POST /chats/secret →
	/// деривация и сохранение ключа. Возвращает id чата.
	func createSecretChat(peerId: Int) async throws -> Int {
		// Публичный ключ собеседника
		let keyData = try await APIClient.shared.request(path: "/e2e/keys/\(peerId)", method: "GET")
		struct KeyOut: Codable { let publicKey: String }
		let peerKey = try APIClient.shared.decode(KeyOut.self, from: keyData)
		guard let peerPub = E2ECore.publicKey(fromB64: peerKey.publicKey) else {
			throw APIClientError.httpStatus(400, message: "Некорректный ключ собеседника")
		}

		let eph = Curve25519.KeyAgreement.PrivateKey()
		let body = try JSONSerialization.data(withJSONObject: [
			"user_id": peerId,
			"eph_pub": E2ECore.publicKeyB64(eph),
		])
		let data = try await APIClient.shared.request(path: "/chats/secret", method: "POST", body: body)
		struct ChatIdOnly: Codable { let id: Int }
		let chatId = try APIClient.shared.decode(ChatIdOnly.self, from: data).id

		// Единственный момент, когда создатель может вывести ключ, — сохраняем сразу
		let key = try E2ECore.creatorChatKey(ephPriv: eph, peerIdentityPub: peerPub, chatId: chatId)
		storeChatKey(key, chatId: chatId)
		return chatId
	}

	/// Ключ чата: из Keychain, либо деривация по handshake (путь собеседника).
	func chatKey(chatId: Int, handshake: E2EHandshake?, myUserId: Int?) -> SymmetricKey? {
		if let stored = storedChatKey(chatId) { return stored }
		guard let hs = handshake, let me = myUserId else { return nil }
		if hs.creatorId == me {
			// Создатель без сохранённого ключа (переустановка) — восстановить нельзя:
			// эфемерный приватный ключ существовал только в момент создания.
			return nil
		}
		guard let ephPub = E2ECore.publicKey(fromB64: hs.ephPub) else { return nil }
		guard let key = try? E2ECore.peerChatKey(
			identityPriv: identityKey(), ephPub: ephPub, chatId: chatId
		) else { return nil }
		storeChatKey(key, chatId: chatId)
		return key
	}
}
