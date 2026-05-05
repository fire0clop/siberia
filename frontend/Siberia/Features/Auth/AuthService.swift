import Foundation

final class AuthService {

	static let shared = AuthService()

	private init() {}

	private func encoder() -> JSONEncoder {
		let e = JSONEncoder()
		e.keyEncodingStrategy = .convertToSnakeCase
		return e
	}

	/// Возвращает либо обычный успех (.success), либо запрос на 2FA (.twoFactorRequired).
	enum LoginOutcome {
		case success(User)
		case twoFactorRequired(tempToken: String)
	}

	func register(email: String, nickname: String, password: String) async throws -> User {
		let body = try encoder().encode(RegisterBody(email: email, nickname: nickname, password: password))

		let data = try await APIClient.shared.request(
			path: "/auth/register",
			method: "POST",
			body: body,
			requiresAuth: false,
			extraHeaders: ["X-Device-ID": DeviceIDStorage.shared.deviceId]
		)

		let response = try APIClient.shared.decode(AuthResponse.self, from: data)
		saveTokens(response)
		guard let user = response.user else {
			throw APIClientError.httpStatus(500, message: "Registration did not return a user")
		}
		return user
	}

	func login(email: String, password: String) async throws -> LoginOutcome {
		let body = try JSONSerialization.data(withJSONObject: [
			"email": email,
			"password": password,
			"device_id": DeviceIDStorage.shared.deviceId
		])

		let data = try await APIClient.shared.request(
			path: "/auth/login",
			method: "POST",
			body: body,
			requiresAuth: false,
			extraHeaders: ["X-Device-ID": DeviceIDStorage.shared.deviceId]
		)

		let response = try APIClient.shared.decode(AuthResponse.self, from: data)
		if response.isTwoFactorPending, let temp = response.tempToken {
			return .twoFactorRequired(tempToken: temp)
		}
		saveTokens(response)
		guard let user = response.user else {
			throw APIClientError.httpStatus(500, message: "Login returned no user and no 2FA challenge")
		}
		return .success(user)
	}

	// MARK: – 2FA

	func verifyTotp(tempToken: String, code: String) async throws -> User {
		let body = try encoder().encode(TotpVerifyBody(tempToken: tempToken, totpCode: code))
		let data = try await APIClient.shared.request(
			path: "/auth/2fa/verify",
			method: "POST",
			body: body,
			requiresAuth: false,
			extraHeaders: ["X-Device-ID": DeviceIDStorage.shared.deviceId]
		)
		let response = try APIClient.shared.decode(AuthResponse.self, from: data)
		saveTokens(response)
		guard let user = response.user else {
			throw APIClientError.httpStatus(500, message: "2FA verify did not return user")
		}
		return user
	}

	func setupTotp() async throws -> TotpSetupResponse {
		let data = try await APIClient.shared.request(path: "/auth/2fa/setup", method: "POST")
		return try APIClient.shared.decode(TotpSetupResponse.self, from: data)
	}

	func confirmTotp(code: String) async throws {
		let body = try encoder().encode(TotpConfirmBody(totpCode: code))
		_ = try await APIClient.shared.request(path: "/auth/2fa/confirm", method: "POST", body: body)
	}

	func disableTotp(code: String) async throws {
		let body = try encoder().encode(TotpConfirmBody(totpCode: code))
		_ = try await APIClient.shared.request(path: "/auth/2fa", method: "DELETE", body: body)
	}

	// MARK: – Email verification

	func verifyEmail(code: String) async throws {
		let body = try encoder().encode(EmailVerifyBody(code: code))
		_ = try await APIClient.shared.request(path: "/auth/verify-email", method: "POST", body: body)
	}

	func resendVerification() async throws {
		_ = try await APIClient.shared.request(path: "/auth/resend-verification", method: "POST")
	}

	func logout() async throws {
		guard let refresh = TokenStorage.shared.refreshToken else { return }

		let body = try JSONSerialization.data(withJSONObject: [
			"refresh_token": refresh,
			"device_id": DeviceIDStorage.shared.deviceId
		])

		_ = try? await APIClient.shared.request(
			path: "/auth/logout",
			method: "POST",
			body: body,
			requiresAuth: false
		)
	}

	private func saveTokens(_ response: AuthResponse) {
		if let access = response.accessToken { TokenStorage.shared.accessToken = access }
		if let refresh = response.refreshToken { TokenStorage.shared.refreshToken = refresh }
	}

	private struct RegisterBody: Encodable {
		let email: String
		let nickname: String
		let password: String
	}
}
