import SwiftUI

/// Резервная копия E2E identity-ключа под пассфразу (стадия 4b).
/// Бэкап: ключ шифруется пассфразой (PBKDF2 → AES-GCM) и кладётся на сервер —
/// сервер видит только шифроблоб. Восстановление на новом устройстве требует
/// той же пассфразы. Пассфразу нельзя восстановить: забыл — бэкап бесполезен.
struct KeyBackupSheet: View {
	@Environment(\.dismiss) private var dismiss

	@State private var mode: Mode = .backup
	@State private var passphrase = ""
	@State private var confirm = ""
	@State private var busy = false
	@State private var message: String?
	@State private var ok = false

	enum Mode: String, CaseIterable { case backup = "Сохранить", restore = "Восстановить" }

	var body: some View {
		NavigationStack {
			Form {
				Picker("", selection: $mode) {
					ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)
				.listRowBackground(Color.clear)

				Section {
					SecureField("Пассфраза", text: $passphrase)
						.textContentType(.newPassword)
					if mode == .backup {
						SecureField("Повторите пассфразу", text: $confirm)
							.textContentType(.newPassword)
					}
				} footer: {
					Text(mode == .backup
						 ? "Ключ зашифруется этой пассфразой и уйдёт на сервер в закрытом виде. Пассфразу невозможно восстановить — запишите её."
						 : "Введите пассфразу, которой делали бэкап. Ключ восстановится на это устройство.")
				}

				if let message {
					Section {
						Text(message)
							.font(.system(size: 13))
							.foregroundStyle(ok ? .green : .red)
					}
				}

				Section {
					Button {
						Task { await run() }
					} label: {
						HStack {
							Spacer()
							if busy { ProgressView() } else { Text(mode.rawValue).fontWeight(.semibold) }
							Spacer()
						}
					}
					.disabled(busy || !valid)
				}
			}
			.navigationTitle("Резервная копия ключей")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
		}
	}

	private var valid: Bool {
		guard passphrase.count >= 8 else { return false }
		return mode == .restore || passphrase == confirm
	}

	private func run() async {
		busy = true; message = nil
		let success: Bool
		if mode == .backup {
			success = await E2ECrypto.shared.backupIdentityKey(passphrase: passphrase)
		} else {
			success = await E2ECrypto.shared.restoreIdentityKey(passphrase: passphrase)
		}
		busy = false
		ok = success
		if success {
			message = mode == .backup ? "Резервная копия сохранена." : "Ключ восстановлен на это устройство."
		} else {
			message = mode == .backup
				? "Не удалось сохранить резервную копию."
				: "Не удалось восстановить: неверная пассфраза или копии нет."
		}
	}
}
