import SwiftUI

/// Экран подтверждения email после регистрации.
/// Показывается также из ProfileView если email_verified=false.
struct EmailVerificationView: View {

	let email: String?
	var onVerified: (() -> Void)? = nil
	@Environment(\.dismiss) private var dismiss

	@State private var code = ""
	@State private var isBusy = false
	@State private var notice: String?
	@State private var error: String?
	@State private var resendCooldown = 0
	@State private var cooldownTask: Task<Void, Never>?

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				Spacer().frame(height: 20)

				ZStack {
					Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 92, height: 92)
					Image(systemName: "envelope.badge.shield.half.filled")
						.font(.system(size: 36))
						.foregroundStyle(Color.accentColor)
				}

				VStack(spacing: 6) {
					Text("Подтверждение email")
						.font(.title2.bold())
					Text(email.map { "Мы отправили 6-значный код на \($0)." } ?? "Мы отправили 6-значный код на ваш email.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 20)
				}

				codeField
					.padding(.horizontal, 40)

				Button {
					Task { await verify() }
				} label: {
					Text("Подтвердить")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.frame(height: 50)
						.background(code.count == 6 ? Color.accentColor : Color.secondary.opacity(0.3))
						.foregroundStyle(.white)
						.clipShape(RoundedRectangle(cornerRadius: 14))
				}
				.disabled(code.count != 6 || isBusy)
				.padding(.horizontal, 24)

				Button {
					Task { await resend() }
				} label: {
					Text(resendCooldown > 0
						 ? "Отправить заново через \(resendCooldown)s"
						 : "Отправить код заново")
						.font(.subheadline)
						.foregroundStyle(resendCooldown > 0 ? .secondary : Color.accentColor)
				}
				.disabled(resendCooldown > 0 || isBusy)

				if let notice {
					Text(notice).font(.footnote).foregroundStyle(.green)
				}
				if let error {
					Text(error).font(.footnote).foregroundStyle(.red)
				}

				Spacer()
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Позже") { dismiss() }
				}
			}
		}
		.onDisappear { cooldownTask?.cancel() }
	}

	private var codeField: some View {
		TextField("000000", text: Binding(
			get: { code },
			set: { code = String($0.filter(\.isNumber).prefix(6)) }
		))
		.keyboardType(.numberPad)
		.textContentType(.oneTimeCode)
		.multilineTextAlignment(.center)
		.font(.system(size: 32, weight: .semibold, design: .monospaced))
		.padding(.vertical, 14)
		.background(Color(.secondarySystemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 14))
	}

	@MainActor
	private func verify() async {
		isBusy = true; error = nil; notice = nil
		defer { isBusy = false }
		do {
			try await AuthService.shared.verifyEmail(code: code)
			notice = "Email подтверждён"
			onVerified?()
			try? await Task.sleep(nanoseconds: 700_000_000)
			dismiss()
		} catch {
			Log.auth.error("verifyEmail failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor
	private func resend() async {
		isBusy = true; error = nil; notice = nil
		defer { isBusy = false }
		do {
			try await AuthService.shared.resendVerification()
			notice = "Код отправлен заново"
			startCooldown()
		} catch {
			Log.auth.error("resendVerification failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	private func startCooldown() {
		cooldownTask?.cancel()
		resendCooldown = 60
		cooldownTask = Task { @MainActor in
			while resendCooldown > 0 && !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 1_000_000_000)
				if Task.isCancelled { break }
				resendCooldown = max(0, resendCooldown - 1)
			}
		}
	}
}
