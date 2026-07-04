import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

	@Published var email = ""
	@Published var password = ""
	@Published var nickname = ""

	@Published var isLoading = false
	@Published var error: String?

	@Published var isLoginMode = true

	// MARK: – 2FA challenge state
	@Published var pendingTwoFactorToken: String? = nil
	@Published var twoFactorCode: String = ""

	// MARK: – Email verification state
	/// Если true — после успешной регистрации показываем экран ввода кода.
	@Published var pendingEmailVerification = false

	func submit(appState: AppState) async {
		isLoading = true
		error = nil
		defer { isLoading = false }

		let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)

		if !isLoginMode && trimmedNick.isEmpty {
			error = "Введите никнейм"
			return
		}

		if trimmedEmail.isEmpty || password.isEmpty {
			error = "Заполните email и пароль"
			return
		}

		// Email — простая проверка: должна быть @ и точка в доменной части
		let domainPart = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false).last
		if !trimmedEmail.contains("@") || domainPart?.contains(".") != true {
			error = "Введите корректный email"
			return
		}

		// При регистрации — пароль минимум 8 символов + хотя бы 1 цифра
		if !isLoginMode && password.count < 8 {
			error = "Пароль должен быть минимум 8 символов"
			return
		}
		if !isLoginMode && !password.contains(where: \.isNumber) {
			error = "Пароль должен содержать хотя бы одну цифру"
			return
		}
		if !isLoginMode && !password.contains(where: \.isUppercase) {
			error = "Пароль должен содержать хотя бы одну заглавную букву"
			return
		}

		// Никнейм при регистрации — 1-50 символов
		if !isLoginMode && trimmedNick.count > 50 {
			error = "Никнейм не длиннее 50 символов"
			return
		}

		do {
			if isLoginMode {
				let outcome = try await AuthService.shared.login(email: trimmedEmail, password: password)
				switch outcome {
				case .success:
					appState.setAuthenticatedAndBootstrap()
				case .twoFactorRequired(let tempToken):
					pendingTwoFactorToken = tempToken
				}
			} else {
				_ = try await AuthService.shared.register(
					email: trimmedEmail,
					nickname: trimmedNick,
					password: password
				)
				// Токены уже сохранены в Keychain. НЕ заходим в MainView пока
				// пользователь не подтвердит email (или явно не нажмёт «Позже»).
				pendingEmailVerification = true
			}
		} catch let e as APIClientError {
			// При регистрации "Invalid credentials" обычно = email уже занят
			if !isLoginMode, case .httpStatus(_, let msg) = e,
			   let m = msg?.lowercased(),
			   m.contains("invalid") || m.contains("credential") || m.contains("exist") || m.contains("already") {
				self.error = "Этот email уже зарегистрирован"
			} else {
				self.error = e.localizedDescription
			}
		} catch {
			self.error = error.localizedDescription
		}
	}

	// MARK: – 2FA verification

	func verifyTwoFactor(appState: AppState) async {
		guard let temp = pendingTwoFactorToken else { return }
		let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
		guard code.count == 6 else {
			error = "Введите 6-значный код"
			return
		}
		isLoading = true
		error = nil
		defer { isLoading = false }
		do {
			_ = try await AuthService.shared.verifyTotp(tempToken: temp, code: code)
			pendingTwoFactorToken = nil
			twoFactorCode = ""
			appState.setAuthenticatedAndBootstrap()
		} catch let e as APIClientError {
			self.error = e.localizedDescription
		} catch {
			self.error = error.localizedDescription
		}
	}

	func cancelTwoFactor() {
		pendingTwoFactorToken = nil
		twoFactorCode = ""
		error = nil
	}
}
