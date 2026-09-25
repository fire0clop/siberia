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

	/// Fallback применяется только когда SiberiaAPIBaseURL не задан в Info.plist.
	/// В Debug — адрес машины разработчика в локальной сети; в Release LAN-адрес
	/// недопустим, поэтому подставляется продовый домен.
	private static let fallbackBaseURL: String = {
		#if DEBUG
		return "http://192.168.50.49:8000"
		#else
		return "https://api.siberia.app"
		#endif
	}()

	nonisolated(unsafe) static var baseURL: String = {
		let resolved: String = {
			if let configured = Bundle.main.object(forInfoDictionaryKey: "SiberiaAPIBaseURL") as? String,
			   !configured.trimmingCharacters(in: .whitespaces).isEmpty {
				return configured
			}
			return fallbackBaseURL
		}()
		#if !DEBUG
		// В релизе plaintext-HTTP недопустим: он означал бы, что переписку и
		// звонки можно перехватить на линии. Падаем громко на старте, а не
		// молча отправляем трафик в открытую.
		precondition(
			resolved.hasPrefix("https://"),
			"Release build requires an https:// API base URL (got \(resolved))"
		)
		#endif
		return resolved
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
