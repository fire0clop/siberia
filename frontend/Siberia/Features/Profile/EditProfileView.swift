import SwiftUI

struct EditProfileView: View {

	@EnvironmentObject var appState: AppState
	@Environment(\.dismiss) private var dismiss

	@State private var nickname: String = ""
	@State private var bio: String = ""
	@State private var isSaving = false
	@State private var error: String?

	private var canSave: Bool {
		let trimmed = nickname.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return false }
		let current = appState.currentUser
		return trimmed != current?.nickname || bio != (current?.bio ?? "")
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Никнейм") {
					TextField("Никнейм", text: $nickname)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				Section(header: Text("О себе"),
				        footer: Text("\(bio.count)/200")) {
					TextField("Несколько слов о себе…", text: $bio, axis: .vertical)
						.lineLimit(3...8)
						.onChange(of: bio) { _, n in
							if n.count > 200 { bio = String(n.prefix(200)) }
						}
				}
			}
			.navigationTitle("Редактирование")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					Button("Сохранить") { Task { await save() } }
						.fontWeight(.semibold)
						.disabled(!canSave || isSaving)
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
			.overlay { if isSaving { ProgressView().controlSize(.large) } }
		}
		.onAppear {
			nickname = appState.currentUser?.nickname ?? ""
			bio = appState.currentUser?.bio ?? ""
		}
	}

	@MainActor
	private func save() async {
		isSaving = true; defer { isSaving = false }
		let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
		let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
		let current = appState.currentUser
		let newNick = trimmedNick == current?.nickname ? nil : trimmedNick
		let newBio  = trimmedBio == (current?.bio ?? "") ? nil : trimmedBio
		do {
			let user = try await UserService.shared.updateProfile(nickname: newNick, bio: newBio)
			appState.currentUser = user
			dismiss()
		} catch {
			Log.profile.error("updateProfile failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
