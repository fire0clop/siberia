//Core/Storage/TokenStorage.swift
//
// Токены хранятся в Keychain (kSecClassGenericPassword), не в UserDefaults.
// Keychain зашифрован системой, не утекает в iTunes-бэкап.
//
// Accessible: kSecAttrAccessibleAfterFirstUnlock — токен доступен после первой разблокировки
// устройства (нужно чтобы push-уведомления могли подтянуть состояние когда телефон ещё заблокирован
// после reboot, но защищены до первого ввода пасскода).
import Foundation
import Security

final class TokenStorage: @unchecked Sendable {
	static let shared = TokenStorage()

	private let service = "app.siberia.tokens"
	private let accessAccount  = "access_token"
	private let refreshAccount = "refresh_token"

	private init() {
		migrateLegacyIfNeeded()
	}

	var accessToken: String? {
		get { read(accessAccount) }
		set { write(newValue, for: accessAccount) }
	}

	var refreshToken: String? {
		get { read(refreshAccount) }
		set { write(newValue, for: refreshAccount) }
	}

	func clear() {
		delete(accessAccount)
		delete(refreshAccount)
	}

	// MARK: – Migration from UserDefaults (one-time)

	private func migrateLegacyIfNeeded() {
		let ud = UserDefaults.standard
		if let oldAccess = ud.string(forKey: "access_token"), !oldAccess.isEmpty,
		   read(accessAccount) == nil {
			write(oldAccess, for: accessAccount)
			ud.removeObject(forKey: "access_token")
		}
		if let oldRefresh = ud.string(forKey: "refresh_token"), !oldRefresh.isEmpty,
		   read(refreshAccount) == nil {
			write(oldRefresh, for: refreshAccount)
			ud.removeObject(forKey: "refresh_token")
		}
	}

	// MARK: – Keychain primitives

	private func baseQuery(for account: String) -> [String: Any] {
		[
			kSecClass as String:       kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
	}

	private func read(_ account: String) -> String? {
		var query = baseQuery(for: account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	private func write(_ value: String?, for account: String) {
		guard let value, let data = value.data(using: .utf8) else {
			delete(account)
			return
		}

		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
		]

		let updateStatus = SecItemUpdate(
			baseQuery(for: account) as CFDictionary,
			attributes as CFDictionary
		)

		if updateStatus == errSecItemNotFound {
			var addQuery = baseQuery(for: account)
			addQuery.merge(attributes) { _, new in new }
			let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
			if addStatus != errSecSuccess {
				print("TokenStorage: SecItemAdd status=\(addStatus) for \(account)")
			}
		} else if updateStatus != errSecSuccess {
			print("TokenStorage: SecItemUpdate status=\(updateStatus) for \(account)")
		}
	}

	private func delete(_ account: String) {
		let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
		if status != errSecSuccess && status != errSecItemNotFound {
			print("TokenStorage: SecItemDelete status=\(status) for \(account)")
		}
	}
}
