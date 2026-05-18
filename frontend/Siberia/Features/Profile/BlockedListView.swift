import SwiftUI

struct BlockedListView: View {

	@Environment(\.dismiss) private var dismiss
	@State private var users: [User] = []
	@State private var isLoading = false
	@State private var busyId: Int?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Group {
				if isLoading {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if users.isEmpty {
					ContentUnavailableView(
						"Никто не заблокирован",
						systemImage: "person.crop.circle.badge.checkmark",
						description: Text("Когда вы заблокируете пользователя, он появится здесь.")
					)
				} else {
					List {
						ForEach(users) { user in
							HStack(spacing: 12) {
								friendAvatar(user)
								VStack(alignment: .leading, spacing: 2) {
									Text(user.nickname).font(.system(size: 15, weight: .medium))
									if let e = user.email {
										Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1)
									}
								}
								Spacer()
								Button {
									Task { await unblock(user) }
								} label: {
									if busyId == user.id {
										ProgressView().scaleEffect(0.8)
									} else {
										Text("Разблокировать")
											.font(.system(size: 13, weight: .semibold))
											.foregroundStyle(.white)
											.padding(.horizontal, 10).padding(.vertical, 6)
											.background(Color.accentColor)
											.clipShape(Capsule())
									}
								}
								.disabled(busyId != nil)
							}
						}
					}
				}
			}
			.navigationTitle("Заблокированные")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
		.task { await load() }
	}

	private func friendAvatar(_ user: User) -> some View {
		let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
		let color = palette[abs(user.id) % palette.count]
		return ZStack {
			Circle().fill(color.gradient)
			if let s = user.avatarUrl, let url = URL(string: s) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase {
						img.resizable().scaledToFill().clipShape(Circle())
					} else {
						Text(String(user.nickname.prefix(1)).uppercased())
							.font(.system(size: 14, weight: .semibold))
							.foregroundStyle(.white)
					}
				}
			} else {
				Text(String(user.nickname.prefix(1)).uppercased())
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(.white)
			}
		}
		.frame(width: 36, height: 36)
	}

	@MainActor private func load() async {
		isLoading = true; defer { isLoading = false }
		do {
			users = try await UserService.shared.listBlocked()
		} catch {
			Log.profile.error("listBlocked failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func unblock(_ user: User) async {
		busyId = user.id; defer { busyId = nil }
		do {
			try await UserService.shared.unblock(userId: user.id)
			users.removeAll { $0.id == user.id }
		} catch {
			Log.profile.error("unblock failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
