import Foundation

/// Стабильный идентификатор инсталляции; должен совпадать для register (заголовок), login и refresh (тело).
final class DeviceIDStorage {
	static let shared = DeviceIDStorage()

	private let key = "siberia_device_id"

	private init() {}

	var deviceId: String {
		if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
			return existing
		}
		let id = UUID().uuidString
		UserDefaults.standard.set(id, forKey: key)
		return id
	}
}
