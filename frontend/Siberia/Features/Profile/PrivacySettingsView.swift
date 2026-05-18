import SwiftUI

struct PrivacySettingsView: View {

	@Environment(\.dismiss) private var dismiss
	@State private var settings: PrivacySettings? = nil
	@State private var isLoading = false
	@State private var isSaving = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Group {
				if let settings = settings {
					form(settings)
				} else if isLoading {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ContentUnavailableView("Не удалось загрузить", systemImage: "lock.slash")
				}
			}
			.navigationTitle("Конфиденциальность")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Готово") { dismiss() }
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
			.overlay {
				if isSaving {
					ProgressView().controlSize(.large)
				}
			}
		}
		.task { await load() }
	}

	private func form(_ s: PrivacySettings) -> some View {
		Form {
			Section(header: Text("Невидимый режим"),
			        footer: Text("Включите чтобы скрыть свой online-статус ото всех. " +
			                     "Когда вы открываете чат, собеседник в этот момент будет видеть вас в сети, " +
			                     "но только пока чат активен.")) {
				Toggle("Невидимка", isOn: Binding(
					get: { s.invisibleMode },
					set: { newValue in
						Task { await save(invisibleMode: newValue) }
					}
				))
			}

			Section(header: Text("Кто может видеть мой последний визит"),
			        footer: Text("Если выбрано «Никто», вы тоже не увидите чужой последний визит.")) {
				visibilityPicker(value: s.lastSeen) { v in
					Task { await save(lastSeen: v) }
				}
			}
			Section(header: Text("Кто видит мой аватар")) {
				visibilityPicker(value: s.avatar) { v in
					Task { await save(avatar: v) }
				}
			}
			Section(header: Text("Кто может писать мне первым"),
			        footer: Text("Это применяется только к новым диалогам. Существующие чаты остаются как есть.")) {
				visibilityPicker(value: s.messagesFrom) { v in
					Task { await save(messagesFrom: v) }
				}
			}
		}
	}

	@ViewBuilder
	private func visibilityPicker(value: String, onChange: @escaping (String) -> Void) -> some View {
		let binding = Binding<PrivacyVisibility>(
			get: { PrivacyVisibility(rawValue: value) ?? .everyone },
			set: { newValue in onChange(newValue.rawValue) }
		)
		Picker("", selection: binding) {
			ForEach(PrivacyVisibility.allCases) { v in
				Text(v.displayName).tag(v)
			}
		}
		.pickerStyle(.inline)
		.labelsHidden()
	}

	@MainActor
	private func load() async {
		isLoading = true; defer { isLoading = false }
		do {
			settings = try await UserService.shared.getPrivacy()
		} catch {
			Log.profile.error("getPrivacy failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor
	private func save(
		lastSeen: String? = nil,
		avatar: String? = nil,
		messagesFrom: String? = nil,
		invisibleMode: Bool? = nil
	) async {
		isSaving = true; defer { isSaving = false }
		do {
			let updated = try await UserService.shared.updatePrivacy(
				lastSeen: lastSeen,
				avatar: avatar,
				messagesFrom: messagesFrom,
				invisibleMode: invisibleMode
			)
			settings = updated
		} catch {
			Log.profile.error("updatePrivacy failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
