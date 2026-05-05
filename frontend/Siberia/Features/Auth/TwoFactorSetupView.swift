import SwiftUI

/// Включение/выключение 2FA из настроек профиля.
struct TwoFactorSetupView: View {

	@Environment(\.dismiss) private var dismiss
	var onCompleted: (() -> Void)? = nil

	@State private var stage: Stage = .loading
	@State private var setup: TotpSetupResponse?
	@State private var code = ""
	@State private var isBusy = false
	@State private var error: String?

	enum Stage {
		case loading
		case showQR
		case confirming
		case done
	}

	var body: some View {
		NavigationStack {
			Group {
				switch stage {
				case .loading:
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				case .showQR, .confirming:
					setupContent
				case .done:
					doneContent
				}
			}
			.navigationTitle("Двухфакторная защита")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
		.task { await loadSetup() }
	}

	private var setupContent: some View {
		ScrollView {
			VStack(spacing: 20) {
				Text("Шаг 1. Откройте приложение-аутентификатор (Google Authenticator, 1Password, Authy) и добавьте код из QR.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.horizontal, 24)
					.padding(.top, 12)

				if let setup {
					qrPlaceholder(for: setup.qrUrl)
						.padding(.horizontal, 40)

					VStack(alignment: .leading, spacing: 6) {
						Text("Или введите ключ вручную:").font(.caption).foregroundStyle(.secondary)
						HStack {
							Text(setup.secret)
								.font(.system(.callout, design: .monospaced))
								.lineLimit(1)
								.minimumScaleFactor(0.7)
							Spacer()
							Button {
								UIPasteboard.general.string = setup.secret
							} label: {
								Image(systemName: "doc.on.doc")
							}
						}
						.padding(12)
						.background(Color(.secondarySystemBackground))
						.clipShape(RoundedRectangle(cornerRadius: 10))
					}
					.padding(.horizontal, 24)
				}

				Text("Шаг 2. Введите 6-значный код, который покажет приложение.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.padding(.horizontal, 24)
					.padding(.top, 4)

				TextField("000000", text: Binding(
					get: { code },
					set: { code = String($0.filter(\.isNumber).prefix(6)) }
				))
				.keyboardType(.numberPad)
				.textContentType(.oneTimeCode)
				.multilineTextAlignment(.center)
				.font(.system(size: 28, weight: .semibold, design: .monospaced))
				.padding(.vertical, 12)
				.background(Color(.secondarySystemBackground))
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.padding(.horizontal, 60)

				Button {
					Task { await confirm() }
				} label: {
					Text("Включить 2FA")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.frame(height: 50)
						.background(code.count == 6 ? Color.accentColor : Color.secondary.opacity(0.3))
						.foregroundStyle(.white)
						.clipShape(RoundedRectangle(cornerRadius: 14))
				}
				.disabled(code.count != 6 || isBusy)
				.padding(.horizontal, 24)
				.padding(.bottom, 20)
			}
		}
	}

	private var doneContent: some View {
		VStack(spacing: 16) {
			Spacer()
			Image(systemName: "checkmark.shield.fill")
				.font(.system(size: 56))
				.foregroundStyle(.green)
			Text("Двухфакторная защита включена")
				.font(.headline)
			Text("При следующем входе потребуется код из приложения-аутентификатора.")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 24)
			Spacer()
			Button {
				dismiss()
			} label: {
				Text("Готово")
					.font(.headline)
					.frame(maxWidth: .infinity)
					.frame(height: 50)
					.background(Color.accentColor)
					.foregroundStyle(.white)
					.clipShape(RoundedRectangle(cornerRadius: 14))
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 20)
		}
	}

	private func qrPlaceholder(for urlString: String) -> some View {
		// Простая отрисовка QR через CIFilter — без сторонних зависимостей.
		let image = generateQRCode(from: urlString)
		return Image(uiImage: image)
			.interpolation(.none)
			.resizable()
			.scaledToFit()
			.padding(8)
			.background(Color.white)
			.clipShape(RoundedRectangle(cornerRadius: 14))
			.shadow(color: .black.opacity(0.1), radius: 8, y: 4)
	}

	private func generateQRCode(from string: String) -> UIImage {
		let context = CIContext()
		let filter = CIFilter(name: "CIQRCodeGenerator")
		filter?.setValue(Data(string.utf8), forKey: "inputMessage")
		filter?.setValue("M", forKey: "inputCorrectionLevel")
		if let output = filter?.outputImage {
			let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
			if let cg = context.createCGImage(scaled, from: scaled.extent) {
				return UIImage(cgImage: cg)
			}
		}
		return UIImage()
	}

	@MainActor
	private func loadSetup() async {
		stage = .loading
		do {
			let s = try await AuthService.shared.setupTotp()
			setup = s
			stage = .showQR
		} catch {
			Log.auth.error("setupTotp failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor
	private func confirm() async {
		isBusy = true
		defer { isBusy = false }
		do {
			try await AuthService.shared.confirmTotp(code: code)
			stage = .done
			onCompleted?()
		} catch {
			Log.auth.error("confirmTotp failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}

/// Отключение 2FA (требует код).
struct TwoFactorDisableSheet: View {

	@Environment(\.dismiss) private var dismiss
	var onDisabled: (() -> Void)? = nil

	@State private var code = ""
	@State private var isBusy = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 16) {
				Image(systemName: "lock.open.fill")
					.font(.system(size: 36))
					.foregroundStyle(.orange)
					.padding(.top, 24)
				Text("Отключение 2FA")
					.font(.title3.bold())
				Text("Введите текущий 6-значный код из приложения-аутентификатора чтобы выключить двухфакторную защиту.")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)

				TextField("000000", text: Binding(
					get: { code },
					set: { code = String($0.filter(\.isNumber).prefix(6)) }
				))
				.keyboardType(.numberPad)
				.textContentType(.oneTimeCode)
				.multilineTextAlignment(.center)
				.font(.system(size: 28, weight: .semibold, design: .monospaced))
				.padding(.vertical, 12)
				.background(Color(.secondarySystemBackground))
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.padding(.horizontal, 60)

				Button(role: .destructive) {
					Task { await disable() }
				} label: {
					Text("Отключить 2FA")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.frame(height: 50)
						.background(code.count == 6 ? Color.red : Color.secondary.opacity(0.3))
						.foregroundStyle(.white)
						.clipShape(RoundedRectangle(cornerRadius: 14))
				}
				.disabled(code.count != 6 || isBusy)
				.padding(.horizontal, 24)

				if let err = error {
					Text(err).font(.footnote).foregroundStyle(.red)
				}

				Spacer()
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
			}
			.navigationBarTitleDisplayMode(.inline)
		}
	}

	@MainActor
	private func disable() async {
		isBusy = true; error = nil
		defer { isBusy = false }
		do {
			try await AuthService.shared.disableTotp(code: code)
			onDisabled?()
			dismiss()
		} catch {
			Log.auth.error("disableTotp failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
