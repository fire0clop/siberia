import SwiftUI

/// Создание группового чата: название + описание + мульти-выбор друзей.
struct CreateGroupSheet: View {

	let onCreated: (ChatRoute) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var title = ""
	@State private var description = ""
	@State private var friends: [User] = []
	@State private var selectedIds = Set<Int>()
	@State private var searchText = ""
	@State private var isBusy = false
	@State private var error: String?

	private var filteredFriends: [User] {
		guard !searchText.isEmpty else { return friends }
		let q = searchText.lowercased()
		return friends.filter { $0.nickname.lowercased().contains(q) }
	}

	private var canCreate: Bool {
		!title.trimmingCharacters(in: .whitespaces).isEmpty && !selectedIds.isEmpty
	}

	var body: some View {
		NavigationStack {
			Form {
				Section("Название") {
					TextField("Название группы", text: $title)
					TextField("Описание (необязательно)", text: $description, axis: .vertical)
						.lineLimit(1...3)
				}

				Section(header: HStack {
					Text("Участники")
					Spacer()
					Text("\(selectedIds.count) выбрано")
						.font(.caption)
						.foregroundStyle(.secondary)
				}) {
					if friends.isEmpty {
						HStack {
							Spacer()
							ProgressView()
							Spacer()
						}
					} else {
						TextField("Поиск среди друзей", text: $searchText)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()

						ForEach(filteredFriends) { friend in
							Button {
								if selectedIds.contains(friend.id) {
									selectedIds.remove(friend.id)
								} else {
									selectedIds.insert(friend.id)
								}
							} label: {
								HStack(spacing: 12) {
									friendAvatar(friend)
									VStack(alignment: .leading, spacing: 2) {
										Text(friend.nickname)
											.font(.system(size: 15, weight: .medium))
											.foregroundStyle(.primary)
										if let e = friend.email {
											Text(e).font(.caption).foregroundStyle(.secondary)
										}
									}
									Spacer()
									Image(systemName: selectedIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
										.font(.system(size: 22))
										.foregroundStyle(selectedIds.contains(friend.id) ? Color.accentColor : .secondary)
								}
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
			.navigationTitle("Новая группа")
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
		.task {
			friends = (try? await FriendService.shared.getFriends()) ?? []
		}
	}

	private func friendAvatar(_ user: User) -> some View {
		let color = colorFor(user.id)
		return ZStack {
			Circle().fill(color.gradient)
			if let s = user.avatarUrl, let url = URL(string: s) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase {
						img.resizable().scaledToFill().clipShape(Circle())
					} else {
						initialsText(user.nickname)
					}
				}
			} else {
				initialsText(user.nickname)
			}
		}
		.frame(width: 36, height: 36)
	}

	private func initialsText(_ name: String) -> some View {
		Text(String(name.prefix(1)).uppercased())
			.font(.system(size: 14, weight: .semibold))
			.foregroundStyle(.white)
	}

	private func colorFor(_ id: Int) -> Color {
		let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
		return palette[abs(id) % palette.count]
	}

	@MainActor
	private func create() async {
		let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
		let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
		guard !trimmedTitle.isEmpty, !selectedIds.isEmpty else { return }
		isBusy = true
		defer { isBusy = false }
		do {
			let chat = try await ChatService.shared.createGroup(
				title: trimmedTitle,
				userIds: Array(selectedIds),
				description: trimmedDesc.isEmpty ? nil : trimmedDesc
			)
			let route = ChatRoute(chatId: chat.id, title: trimmedTitle, syncSeq: chat.syncSeq)
			onCreated(route)
			dismiss()
		} catch {
			Log.chat.error("createGroup failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
