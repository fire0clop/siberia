import Foundation

/// Базовая конфигурация API.
///
/// Значение `baseURL` читается из Info.plist по ключу `SiberiaAPIBaseURL`.
/// Если ключ не задан — используется fallback ниже (для разработки в локальной сети).
///
/// Как переопределить через Xcode (без правки кода):
/// 1. Project → Target → Build Settings → "+" → Add User-Defined Setting
///    → имя `SIBERIA_API_BASE_URL`, значение per-configuration:
///      Debug   = http://192.168.50.63:8000
///      Release = https://api.siberia.app
/// 2. Project → Target → Build Settings → найти `Info.plist Values` →
///    добавить INFOPLIST_KEY_SiberiaAPIBaseURL = $(SIBERIA_API_BASE_URL)
/// 3. Xcode подставит значение при сборке.
enum APIConfig {

	private static let fallbackBaseURL = "http://192.168.1.134:8000"

	nonisolated(unsafe) static var baseURL: String = {
		if let configured = Bundle.main.object(forInfoDictionaryKey: "SiberiaAPIBaseURL") as? String,
		   !configured.trimmingCharacters(in: .whitespaces).isEmpty {
			return configured
		}
		return fallbackBaseURL
	}()

	nonisolated static var wsBaseURL: String {
		if baseURL.hasPrefix("https://") {
			return "wss://" + baseURL.dropFirst("https://".count)
		}
		if baseURL.hasPrefix("http://") {
			return "ws://" + baseURL.dropFirst("http://".count)
		}
		return baseURL
	}
}
