import UIKit

/// Регистрирует push-токены на бэке. Каждое устройство шлёт два разных токена:
///   - apns: обычные алёрты для сообщений (через APNs)
///   - voip: PushKit-токен для звонков (мгновенная доставка + пробуждение приложения)
final class PushTokenService {
	static let shared = PushTokenService()
	private init() {}

	enum Kind: String {
		case apns
		case voip
	}

	func register(token: String, kind: Kind) async throws {
		let body = try JSONEncoder().encode(PushTokenBody(
			device_token: token,
			platform: "ios",
			kind: kind.rawValue
		))
		_ = try await APIClient.shared.request(
			path: "/devices/push-token",
			method: "POST",
			body: body
		)
	}

	func unregister(token: String) async {
		let body = try? JSONEncoder().encode(DeleteBody(device_token: token))
		_ = try? await APIClient.shared.request(
			path: "/devices/push-token",
			method: "DELETE",
			body: body
		)
	}

	private struct PushTokenBody: Encodable {
		let device_token: String
		let platform: String
		let kind: String
	}
	private struct DeleteBody: Encodable {
		let device_token: String
	}
}
