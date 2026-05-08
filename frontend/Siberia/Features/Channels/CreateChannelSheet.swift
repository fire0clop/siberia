import SwiftUI

/// Создание канала: название, описание, публичность.
struct CreateChannelSheet: View {

	let onCreated: (ChatRoute) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var title = ""
	@State private var description = ""
	@State private var isPublic = true
	@State private var isBusy = false
	@State private var error: String?

	private var canCreate: Bool {
		!title.trimmingCharacters(in: .whitespaces).isEmpty
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Канал") {
					TextField("Название", text: $title)
					TextField("Описание (необязательно)", text: $description, axis: .vertical)
						.lineLimit(1...4)
				}

				Section {
					Toggle(isOn: $isPublic) {
						VStack(alignment: .leading, spacing: 3) {
							Text("Публичный канал")
							Text(isPublic
								 ? "Виден в поиске, любой может подписаться"
								 : "Только по приглашению")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				}
			}
			.navigationTitle("Новый канал")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("Создать") { Task { await create() } }
						.disabled(!canCreate || isBusy)
						.fontWeight(.semibold)
				}
			}
			.overlay {
				if isBusy {
					Color.black.opacity(0.15).ignoresSafeArea()
					ProgressView().controlSize(.large).tint(.white)
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
	}

	@MainActor
	private func create() async {
		let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
		let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
		guard !trimmedTitle.isEmpty else { return }
		isBusy = true
		defer { isBusy = false }
		do {
			let chat = try await ChannelService.shared.create(
				title: trimmedTitle,
				description: trimmedDesc.isEmpty ? nil : trimmedDesc,
				isPublic: isPublic
			)
			let route = ChatRoute(chatId: chat.id, title: trimmedTitle, syncSeq: chat.syncSeq)
			onCreated(route)
			dismiss()
		} catch {
			Log.chat.error("createChannel failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
