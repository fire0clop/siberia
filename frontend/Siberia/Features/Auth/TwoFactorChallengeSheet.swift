import SwiftUI

/// Показывается на этапе логина если у юзера включена 2FA и сервер вернул requires_2fa + temp_token.
struct TwoFactorChallengeSheet: View {

	@ObservedObject var vm: AuthViewModel
	@EnvironmentObject var appState: AppState

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				Spacer().frame(height: 16)

				ZStack {
					Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 92, height: 92)
					Image(systemName: "lock.shield.fill")
						.font(.system(size: 36))
						.foregroundStyle(Color.accentColor)
				}

				VStack(spacing: 6) {
					Text("Подтверждение входа")
						.font(.title2.bold())
					Text("Введите 6-значный код из приложения-аутентификатора")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 24)
				}

				TextField("000000", text: Binding(
					get: { vm.twoFactorCode },
					set: { vm.twoFactorCode = String($0.filter(\.isNumber).prefix(6)) }
				))
				.keyboardType(.numberPad)
				.textContentType(.oneTimeCode)
				.multilineTextAlignment(.center)
				.font(.system(size: 32, weight: .semibold, design: .monospaced))
				.padding(.vertical, 14)
				.background(Color(.secondarySystemBackground))
				.clipShape(RoundedRectangle(cornerRadius: 14))
				.padding(.horizontal, 40)

				Button {
					Task { await vm.verifyTwoFactor(appState: appState) }
				} label: {
					Text("Войти")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.frame(height: 50)
						.background(vm.twoFactorCode.count == 6 ? Color.accentColor : Color.secondary.opacity(0.3))
						.foregroundStyle(.white)
						.clipShape(RoundedRectangle(cornerRadius: 14))
				}
				.disabled(vm.twoFactorCode.count != 6 || vm.isLoading)
				.padding(.horizontal, 24)

				if let err = vm.error {
					Text(err).font(.footnote).foregroundStyle(.red)
				}

				Spacer()
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { vm.cancelTwoFactor() }
				}
			}
			.navigationBarTitleDisplayMode(.inline)
		}
		.interactiveDismissDisabled(true)
	}
}
