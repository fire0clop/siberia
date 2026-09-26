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

	// MARK: – Групповое E2E (sender keys, стадия 3b)

	static let skdmSalt = Data("siberia-skdm-v1".utf8)
	static let skdmInfo = Data("siberia:skdm".utf8)

	/// Заворачивает sender-key для устройства-получателя: X25519(мой_priv,
	/// его_pub) → HKDF → AES-GCM(32 байта ключа). Возвращает base64-блоб.
	static func wrapSenderKey(
		_ senderKey: SymmetricKey,
		myPriv: Curve25519.KeyAgreement.PrivateKey,
		recipientPub: Curve25519.KeyAgreement.PublicKey
	) throws -> String {
		let shared = try myPriv.sharedSecretFromKeyAgreement(with: recipientPub)
		let wrapKey = shared.hkdfDerivedSymmetricKey(
			using: SHA256.self, salt: skdmSalt, sharedInfo: skdmInfo, outputByteCount: 32
		)
		let raw = senderKey.withUnsafeBytes { Data($0) }
		let box = try AES.GCM.seal(raw, using: wrapKey)
		guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
		return combined.base64EncodedString()
	}

	/// Разворачивает sender-key: X25519(мой_priv, pub_отправителя) — симметрично
	/// wrap. nil при неверном ключе/повреждении.
	static func unwrapSenderKey(
		_ blobB64: String,
		myPriv: Curve25519.KeyAgreement.PrivateKey,
		senderPub: Curve25519.KeyAgreement.PublicKey
	) -> SymmetricKey? {
		guard let shared = try? myPriv.sharedSecretFromKeyAgreement(with: senderPub) else { return nil }
		let wrapKey = shared.hkdfDerivedSymmetricKey(
			using: SHA256.self, salt: skdmSalt, sharedInfo: skdmInfo, outputByteCount: 32
		)
		guard let combined = Data(base64Encoded: blobB64),
		      let box = try? AES.GCM.SealedBox(combined: combined),
		      let raw = try? AES.GCM.open(box, using: wrapKey),
		      raw.count == 32
		else { return nil }
		return SymmetricKey(data: raw)
	}

	/// Групповое сообщение: внутренний AES-GCM под sender-key + конверт с эпохой,
	/// чтобы получатель выбрал нужную версию ключа. base64({v,e,b}).
	static func encryptGroup(text: String, senderKey: SymmetricKey, epoch: Int) throws -> String {
		let inner = try encrypt(text: text, key: senderKey)
		let env: [String: Any] = ["v": 1, "e": epoch, "b": inner]
		return try JSONSerialization.data(withJSONObject: env).base64EncodedString()
	}

	/// Эпоха sender-key из группового конверта (для выбора ключа до расшифровки).
	static func groupEnvelopeEpoch(_ blobB64: String) -> Int? {
		guard let d = Data(base64Encoded: blobB64),
		      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
		else { return nil }
		return o["e"] as? Int
	}

	/// Расшифровка группового сообщения выбранным sender-key. nil при несовпадении.
	static func decryptGroup(_ blobB64: String, senderKey: SymmetricKey) -> String? {
		guard let d = Data(base64Encoded: blobB64),
		      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
		      let inner = o["b"] as? String
		else { return nil }
		return decrypt(blobB64: inner, key: senderKey)
	}

	static func publicKeyB64(_ priv: Curve25519.KeyAgreement.PrivateKey) -> String {
		priv.publicKey.rawRepresentation.base64EncodedString()
	}

	static func publicKey(fromB64 b64: String) -> Curve25519.KeyAgreement.PublicKey? {
		guard let raw = Data(base64Encoded: b64), raw.count == 32 else { return nil }
		return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
	}

	/// Отпечаток безопасности (safety number) из двух identity-ключей.
	///
	/// Порядко-независим: обе стороны при сравнении получают ОДНО число, если
	/// у них согласованные ключи. Если сервер подменил ключ одному из
	/// собеседников (active MITM), их числа разойдутся — и это видно при
	/// сверке вслух/по другому каналу. Крипта не ломается — ломается обман.
	///
	/// 60 десятичных цифр, 12 групп по 5 — как в Signal, читается голосом.
	static func safetyNumber(_ keyA_b64: String, _ keyB_b64: String) -> String? {
		guard let a = Data(base64Encoded: keyA_b64), a.count == 32,
		      let b = Data(base64Encoded: keyB_b64), b.count == 32 else { return nil }
		// Сортируем, чтобы порядок сторон не влиял на результат
		let (lo, hi) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
		var material = Data()
		material.append(lo); material.append(hi)
		let digest = Data(SHA256.hash(data: material))  // 32 байта

		// 12 групп по 5 цифр: каждая группа — 5-байтовое окно mod 100000
		var groups: [String] = []
		for i in 0..<12 {
			let start = (i * 5) % (digest.count - 4)
			var v: UInt64 = 0
			for j in 0..<5 { v = (v << 8) | UInt64(digest[start + j]) }
			groups.append(String(format: "%05d", v % 100_000))
		}
		return groups.joined(separator: " ")
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

// MARK: – Мультидевайс (стадия 3): устройства пользователя

struct E2EDeviceInfo: Codable, Equatable, Hashable {
	let deviceId: String
	let publicKey: String
}

struct E2EDeviceListResponse: Codable {
	let userId: Int
	let devices: [E2EDeviceInfo]
}

// MARK: – Групповое E2E: устройства участников и раздачи sender-key

struct E2EMemberDevice: Codable, Equatable, Hashable {
	let userId: Int
	let deviceId: String
	let publicKey: String
}

struct E2EMemberDevicesResponse: Codable {
	let devices: [E2EMemberDevice]
}

struct E2ESenderKeyDist: Codable {
	let fromUserId: Int
	let fromDeviceId: String
	let keyEpoch: Int
	let ciphertext: String
}

struct E2ESenderKeysResponse: Codable {
	let keys: [E2ESenderKeyDist]
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

	/// Base64 публичного identity-ключа этого устройства.
	func myIdentityPublicKeyB64() -> String {
		E2ECore.publicKeyB64(identityKey())
	}

	/// Отпечаток безопасности для секретного чата: МОЙ реальный ключ (из
	/// Keychain) + ключ собеседника из handshake. Свой ключ берём настоящий,
	/// а не его копию из handshake, — так подмена именно моего ключа сервером
	/// тоже вылезет при сверке.
	func safetyNumber(handshake: E2EHandshake, myUserId: Int?) -> String? {
		let mine = myIdentityPublicKeyB64()
		let peer = (handshake.creatorId == myUserId)
			? handshake.peerIdentityPub
			: handshake.creatorIdentityPub
		return E2ECore.safetyNumber(mine, peer)
	}

	/// Публикует публичный ключ на бэке (идемпотентно, best-effort).
	/// Стадия 3: помимо legacy-ключа (/e2e/keys, один на юзера) регистрирует
	/// ключ ЭТОГО устройства в реестре мультидевайса (/e2e/devices).
	func publishKeyIfNeeded() async {
		let pub = E2ECore.publicKeyB64(identityKey())
		do {
			let body = try JSONSerialization.data(withJSONObject: ["public_key": pub])
			_ = try await APIClient.shared.request(path: "/e2e/keys", method: "PUT", body: body)
		} catch {
			Log.auth.warning("E2E key publish failed: \(String(describing: error))")
		}
		do {
			let body = try JSONSerialization.data(withJSONObject: [
				"device_id": DeviceIDStorage.shared.deviceId,
				"public_key": pub,
			])
			_ = try await APIClient.shared.request(path: "/e2e/devices", method: "PUT", body: body)
		} catch {
			Log.auth.warning("E2E device publish failed: \(String(describing: error))")
		}
	}

	/// Устройства собеседника (мультидевайс): (device_id, публичный ключ).
	/// Пустой список — собеседник ещё не регистрировал ни одного устройства.
	func peerDevices(userId: Int) async -> [E2EDeviceInfo] {
		do {
			let data = try await APIClient.shared.request(path: "/e2e/devices/\(userId)", method: "GET")
			return (try APIClient.shared.decode(E2EDeviceListResponse.self, from: data)).devices
		} catch {
			Log.auth.warning("E2E devices fetch failed: \(String(describing: error))")
			return []
		}
	}

	/// device_id этого устройства (стабильный per-install).
	var myDeviceId: String { DeviceIDStorage.shared.deviceId }

	// MARK: – Double Ratchet сессии для DM (стадия 4c)

	private func drAccount(_ peerUserId: Int, _ peerDeviceId: String) -> String {
		"dr_\(peerUserId)_\(peerDeviceId)"
	}

	/// Симметричный ключ для расшифровки СВОИХ же DM-сообщений на этом
	/// устройстве (E2E не кеширует plaintext на диск). Создаётся один раз.
	private func dmSelfKey() -> SymmetricKey {
		if let raw = readData("dm_self_key") { return SymmetricKey(data: raw) }
		let key = SymmetricKey(size: .bits256)
		writeData(key.withUnsafeBytes { Data($0) }, "dm_self_key")
		return key
	}

	private func loadDRSession(_ peerUserId: Int, _ peerDeviceId: String) -> DoubleRatchetState? {
		guard let data = readData(drAccount(peerUserId, peerDeviceId)) else { return nil }
		return try? JSONDecoder().decode(DoubleRatchetState.self, from: data)
	}

	private func saveDRSession(_ state: DoubleRatchetState, _ peerUserId: Int, _ peerDeviceId: String) {
		guard let data = try? JSONEncoder().encode(state) else { return }
		writeData(data, drAccount(peerUserId, peerDeviceId))
	}

	/// Начальный общий секрет пары устройств (X3DH-lite): HKDF по DH наших
	/// identity-ключей. Симметричен — обе стороны получают один SK.
	private func drSharedSecret(peerIdentityPub: Curve25519.KeyAgreement.PublicKey) -> Data? {
		guard let ss = try? identityKey().sharedSecretFromKeyAgreement(with: peerIdentityPub) else { return nil }
		let dh = ss.withUnsafeBytes { Data($0) }
		let okm = HKDF<SHA256>.deriveKey(
			inputKeyMaterial: SymmetricKey(data: dh),
			salt: Data("siberia-dr-init-v1".utf8),
			info: Data(),
			outputByteCount: 32
		)
		return okm.withUnsafeBytes { Data($0) }
	}

	/// Шифрует plaintext для конкретного устройства собеседника через его
	/// DR-сессию (создаёт её как инициатор при первом обращении). Возвращает
	/// DR-конверт или nil.
	func drEncrypt(peerUserId: Int, peerDeviceId: String, peerIdentityPubB64: String,
	               plaintext: String, ad: Data) -> String? {
		guard let peerPub = E2ECore.publicKey(fromB64: peerIdentityPubB64) else { return nil }
		var state: DoubleRatchetState
		if let s = loadDRSession(peerUserId, peerDeviceId) {
			state = s
		} else {
			// Инициатор: SK + identity-pub получателя как стартовый ratchet-ключ.
			guard let sk = drSharedSecret(peerIdentityPub: peerPub),
			      let s = DoubleRatchet.initSender(sharedSecret: sk, peerRatchetPub: peerPub.rawRepresentation)
			else { return nil }
			state = s
		}
		guard let env = DoubleRatchet.encrypt(state: &state, plaintext: plaintext, ad: ad) else { return nil }
		saveDRSession(state, peerUserId, peerDeviceId)
		return env
	}

	/// Расшифровывает DR-конверт от устройства собеседника (создаёт сессию как
	/// получатель при первом обращении — своим identity-ключом как ratchet).
	func drDecrypt(peerUserId: Int, peerDeviceId: String, peerIdentityPubB64: String,
	               envelope: String, ad: Data) -> String? {
		var state: DoubleRatchetState
		if let s = loadDRSession(peerUserId, peerDeviceId) {
			state = s
		} else {
			guard let peerPub = E2ECore.publicKey(fromB64: peerIdentityPubB64),
			      let sk = drSharedSecret(peerIdentityPub: peerPub) else { return nil }
			let me = identityKey()
			state = DoubleRatchet.initReceiver(
				sharedSecret: sk,
				ownRatchetPriv: me.rawRepresentation,
				ownRatchetPub: me.publicKey.rawRepresentation
			)
		}
		guard let pt = DoubleRatchet.decrypt(state: &state, envelopeB64: envelope, ad: ad) else { return nil }
		saveDRSession(state, peerUserId, peerDeviceId)
		return pt
	}

	/// Готовит DM-сообщение (Double Ratchet, мультидевайс): шифрует plaintext
	/// ОТДЕЛЬНО для каждого устройства обеих сторон (кроме своего текущего) и
	/// упаковывает в конверт {"v":4,"dr":{deviceId: env}}. Возвращает payload
	/// и мой device_id (sender_device_id).
	func sendableDMPayload(plaintext: String, chatId: Int) async -> (payload: String, senderDeviceId: String)? {
		let devices: [E2EMemberDevice]
		do {
			let data = try await APIClient.shared.request(path: "/chats/\(chatId)/member-devices", method: "GET")
			devices = (try APIClient.shared.decode(E2EMemberDevicesResponse.self, from: data)).devices
		} catch { return nil }
		let ad = Data("chat:\(chatId)".utf8)
		var map: [String: String] = [:]
		for d in devices where d.deviceId != myDeviceId {
			if let env = drEncrypt(peerUserId: d.userId, peerDeviceId: d.deviceId,
			                       peerIdentityPubB64: d.publicKey, plaintext: plaintext, ad: ad) {
				map[d.deviceId] = env
			}
		}
		// Своя доля: E2E не кеширует plaintext на диск, поэтому кладём копию под
		// self-ключом (Keychain) — иначе своё же сообщение не прочесть после
		// перезапуска. Помечаем префиксом "self:" (не DR-конверт).
		if let selfBlob = try? E2ECore.encrypt(text: plaintext, key: dmSelfKey()) {
			map[myDeviceId] = "self:" + selfBlob
		}
		guard !map.isEmpty else { return nil }
		guard let payload = try? JSONSerialization.data(withJSONObject: ["v": 4, "dr": map]).base64EncodedString()
		else { return nil }
		return (payload, myDeviceId)
	}

	/// Расшифровывает DM-конверт Double Ratchet: берёт свою долю из "dr" и
	/// прогоняет через DR-сессию с устройством отправителя. nil — не для меня
	/// или ключ не сходится.
	func decryptDMPayload(payloadB64: String, chatId: Int, fromUserId: Int, fromDeviceId: String) async -> String? {
		guard let data = Data(base64Encoded: payloadB64),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let map = obj["dr"] as? [String: String],
		      let myEnv = map[myDeviceId] else { return nil }
		// Своё сообщение: доля под self-ключом, не DR.
		if myEnv.hasPrefix("self:") {
			return E2ECore.decrypt(blobB64: String(myEnv.dropFirst(5)), key: dmSelfKey())
		}
		// identity-pub отправителя — из member-devices
		var senderPub: String?
		if let md = try? await APIClient.shared.request(path: "/chats/\(chatId)/member-devices", method: "GET"),
		   let list = try? APIClient.shared.decode(E2EMemberDevicesResponse.self, from: md) {
			senderPub = list.devices.first { $0.userId == fromUserId && $0.deviceId == fromDeviceId }?.publicKey
		}
		guard let senderPub else { return nil }
		let ad = Data("chat:\(chatId)".utf8)
		return drDecrypt(peerUserId: fromUserId, peerDeviceId: fromDeviceId,
		                 peerIdentityPubB64: senderPub, envelope: myEnv, ad: ad)
	}

	/// true, если payload — DM-конверт Double Ratchet (стадия 4c).
	static func isDRPayload(_ payloadB64: String) -> Bool {
		guard let data = Data(base64Encoded: payloadB64),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return false }
		return obj["dr"] is [String: String]
	}

	// MARK: – Бэкап/восстановление identity-ключа (стадия 4b)

	/// Кладёт на сервер зашифрованный под пассфразу бэкап identity-ключа.
	@discardableResult
	func backupIdentityKey(passphrase: String) async -> Bool {
		let secret = identityKey().rawRepresentation
		guard let wrapped = KeyBackupCrypto.wrap(secret: secret, passphrase: passphrase) else { return false }
		do {
			let body = try JSONSerialization.data(withJSONObject: [
				"ciphertext": wrapped.ciphertext,
				"salt": wrapped.salt,
				"iterations": wrapped.iterations,
			])
			_ = try await APIClient.shared.request(path: "/e2e/backup", method: "PUT", body: body)
			return true
		} catch {
			Log.auth.warning("E2E backup upload failed: \(String(describing: error))")
			return false
		}
	}

	/// Восстанавливает identity-ключ из бэкапа по пассфразе. Перезаписывает
	/// ключ устройства в Keychain и публикует его как ключ этого устройства.
	/// false — бэкапа нет или пассфраза неверна.
	func restoreIdentityKey(passphrase: String) async -> Bool {
		struct BackupOut: Codable { let ciphertext: String; let salt: String; let iterations: Int }
		let out: BackupOut
		do {
			let data = try await APIClient.shared.request(path: "/e2e/backup", method: "GET")
			out = try APIClient.shared.decode(BackupOut.self, from: data)
		} catch {
			return false
		}
		guard let secret = KeyBackupCrypto.unwrap(
			ciphertextB64: out.ciphertext, saltB64: out.salt,
			iterations: out.iterations, passphrase: passphrase
		), (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)) != nil else {
			return false  // неверная пассфраза или мусор
		}
		writeData(secret, identityAccount)
		await publishKeyIfNeeded()  // зарегистрировать восстановленный ключ как ключ этого устройства
		return true
	}

	// MARK: – Групповые sender keys (стадия 3b)

	// Свой sender-key по эпохам (нужно хранить старые, чтобы читать свою же
	// историю после ротации) + указатель на текущую эпоху.
	private func mySenderKeyAccount(_ chatId: Int, _ epoch: Int) -> String { "grp_send_\(chatId)_\(epoch)" }
	private func myCurrentEpochKey(_ chatId: Int) -> String { "siberia_grp_epoch_\(chatId)" }
	private func distSetKey(_ chatId: Int) -> String { "siberia_grp_distset_\(chatId)" }
	// Полученный sender-key другого устройства по (chat, fromUser, fromDevice, epoch)
	private func recvSenderKeyAccount(_ chatId: Int, _ fromUser: Int, _ fromDevice: String, _ epoch: Int) -> String {
		"grp_recv_\(chatId)_\(fromUser)_\(fromDevice)_\(epoch)"
	}

	private func myCurrentEpoch(_ chatId: Int) -> Int? {
		let v = UserDefaults.standard.object(forKey: myCurrentEpochKey(chatId)) as? Int
		return v
	}

	private func mySenderKey(_ chatId: Int, epoch: Int) -> SymmetricKey? {
		readData(mySenderKeyAccount(chatId, epoch)).map { SymmetricKey(data: $0) }
	}

	private func setMySenderKey(_ key: SymmetricKey, chatId: Int, epoch: Int) {
		writeData(key.withUnsafeBytes { Data($0) }, mySenderKeyAccount(chatId, epoch))
		UserDefaults.standard.set(epoch, forKey: myCurrentEpochKey(chatId))
	}

	/// Гарантирует, что у меня есть sender-key для группы и он роздан всем
	/// текущим устройствам-участникам. Ротирует эпоху при смене набора устройств
	/// (новый участник получит ключ; вышедший — перестанет читать новые эпохи).
	/// Возвращает (ключ, эпоха) для шифрования, либо nil при ошибке.
	@discardableResult
	func ensureGroupSenderKey(chatId: Int) async -> (key: SymmetricKey, epoch: Int)? {
		// Устройства всех участников (кроме моего текущего — себе слать не нужно)
		let devices: [E2EMemberDevice]
		do {
			let data = try await APIClient.shared.request(path: "/chats/\(chatId)/member-devices", method: "GET")
			devices = (try APIClient.shared.decode(E2EMemberDevicesResponse.self, from: data)).devices
		} catch {
			Log.auth.warning("member-devices fetch failed: \(String(describing: error))")
			return nil
		}
		let recipients = devices.filter { $0.deviceId != myDeviceId }
		let currentSet = Set(recipients.map { "\($0.userId):\($0.deviceId)" }).sorted().joined(separator: ",")
		let lastSet = UserDefaults.standard.string(forKey: distSetKey(chatId))

		var epoch = myCurrentEpoch(chatId) ?? 0
		var key = mySenderKey(chatId, epoch: epoch)
		let rosterChanged = (lastSet != nil && lastSet != currentSet)

		if key == nil {
			// первый ключ для чата
			key = SymmetricKey(size: .bits256)
			setMySenderKey(key!, chatId: chatId, epoch: epoch)
		} else if rosterChanged {
			// ротация: новая эпоха + новый ключ
			epoch += 1
			key = SymmetricKey(size: .bits256)
			setMySenderKey(key!, chatId: chatId, epoch: epoch)
		} else if lastSet == currentSet {
			// набор не менялся и уже роздан — ничего не делаем
			return (key!, epoch)
		}

		// Раздаём текущий ключ всем получателям
		let myPriv = identityKey()
		var dists: [[String: Any]] = []
		for d in recipients {
			guard let pub = E2ECore.publicKey(fromB64: d.publicKey),
			      let wrapped = try? E2ECore.wrapSenderKey(key!, myPriv: myPriv, recipientPub: pub)
			else { continue }
			dists.append(["to_user_id": d.userId, "to_device_id": d.deviceId, "ciphertext": wrapped])
		}
		if !dists.isEmpty {
			do {
				let body = try JSONSerialization.data(withJSONObject: [
					"from_device_id": myDeviceId,
					"key_epoch": epoch,
					"distributions": dists,
				])
				_ = try await APIClient.shared.request(path: "/chats/\(chatId)/sender-keys", method: "POST", body: body)
			} catch {
				Log.auth.warning("sender-key distribute failed: \(String(describing: error))")
			}
		}
		UserDefaults.standard.set(currentSet, forKey: distSetKey(chatId))
		return (key!, epoch)
	}

	/// sender-key для входящего группового сообщения от (fromUser, fromDevice)
	/// на конкретную эпоху. Своё сообщение — из своего хранилища; чужое — из
	/// полученных SKDM (при отсутствии дотягивает раздачи с сервера).
	func groupSenderKey(chatId: Int, fromUserId: Int, fromDeviceId: String, epoch: Int, myUserId: Int?) async -> SymmetricKey? {
		if fromUserId == myUserId && fromDeviceId == myDeviceId {
			return mySenderKey(chatId, epoch: epoch)
		}
		if let stored = readData(recvSenderKeyAccount(chatId, fromUserId, fromDeviceId, epoch)) {
			return SymmetricKey(data: stored)
		}
		// Дотягиваем SKDM, адресованные моему устройству, и разворачиваем.
		await fetchAndStoreSenderKeys(chatId: chatId)
		return readData(recvSenderKeyAccount(chatId, fromUserId, fromDeviceId, epoch)).map { SymmetricKey(data: $0) }
	}

	/// Забирает адресованные мне SKDM и разворачивает их своим приватным
	/// ключом + pub отправителя (берём из member-devices).
	private func fetchAndStoreSenderKeys(chatId: Int) async {
		let skdms: [E2ESenderKeyDist]
		var devicesByKey: [String: String] = [:]  // "user:device" → pub
		do {
			let mdData = try await APIClient.shared.request(path: "/chats/\(chatId)/member-devices", method: "GET")
			for d in (try APIClient.shared.decode(E2EMemberDevicesResponse.self, from: mdData)).devices {
				devicesByKey["\(d.userId):\(d.deviceId)"] = d.publicKey
			}
			let data = try await APIClient.shared.request(
				path: "/chats/\(chatId)/sender-keys?device_id=\(myDeviceId)", method: "GET"
			)
			skdms = (try APIClient.shared.decode(E2ESenderKeysResponse.self, from: data)).keys
		} catch {
			Log.auth.warning("sender-keys fetch failed: \(String(describing: error))")
			return
		}
		let myPriv = identityKey()
		for s in skdms {
			guard let pubB64 = devicesByKey["\(s.fromUserId):\(s.fromDeviceId)"],
			      let senderPub = E2ECore.publicKey(fromB64: pubB64),
			      let key = E2ECore.unwrapSenderKey(s.ciphertext, myPriv: myPriv, senderPub: senderPub)
			else { continue }
			writeData(key.withUnsafeBytes { Data($0) },
			          recvSenderKeyAccount(chatId, s.fromUserId, s.fromDeviceId, s.keyEpoch))
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

	/// Создаёт (или до-обновляет legacy-plaintext до E2E) личный чат с peer.
	///
	/// Стадия 2: обычные DM шифруются по умолчанию. Логика:
	///   1. Тянем identity-ключ собеседника. Нет ключа → создаём обычный
	///      plaintext-DM (обратная совместимость: собеседник ещё не заходил).
	///   2. Есть ключ → шлём свой eph_pub; сервер собирает handshake на
	///      новом ИЛИ существующем (legacy) чате.
	///   3. Если вернувшийся handshake — МОЙ (eph_pub совпал), я создатель:
	///      вывожу ключ своим эфемерным приватным и сохраняю (единственный
	///      момент, когда это возможно). Иначе ключ выведет сторона-получатель
	///      лениво при открытии (E2ECrypto.chatKey, peer-путь).
	func createChat(peerId: Int) async throws -> ChatSummary {
		// Наш публичный ключ должен лежать на сервере, иначе handshake не собрать
		await publishKeyIfNeeded()

		// Ключ собеседника (может отсутствовать)
		var peerPub: Curve25519.KeyAgreement.PublicKey? = nil
		if let keyData = try? await APIClient.shared.request(path: "/e2e/keys/\(peerId)", method: "GET") {
			struct KeyOut: Codable { let publicKey: String }
			if let out = try? APIClient.shared.decode(KeyOut.self, from: keyData) {
				peerPub = E2ECore.publicKey(fromB64: out.publicKey)
			}
		}

		var payload: [String: Any] = ["user_id": peerId]
		let eph = Curve25519.KeyAgreement.PrivateKey()
		let ephPubB64 = E2ECore.publicKeyB64(eph)
		if peerPub != nil {
			payload["eph_pub"] = ephPubB64
		}
		let body = try JSONSerialization.data(withJSONObject: payload)
		let data = try await APIClient.shared.request(path: "/chats", method: "POST", body: body)
		let summary = try APIClient.shared.decode(ChatSummary.self, from: data)

		// Я — создатель этого handshake (совпал мой eph): сохраняю ключ сейчас.
		if let hs = summary.e2eHandshake, hs.ephPub == ephPubB64,
		   let peerPub, storedChatKey(summary.id) == nil,
		   let key = try? E2ECore.creatorChatKey(ephPriv: eph, peerIdentityPub: peerPub, chatId: summary.id) {
			storeChatKey(key, chatId: summary.id)
		}
		return summary
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
