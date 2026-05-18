import SwiftUI

/// Единый поиск по пользователям + сообщениям + чатам/группам.
/// Вызывает `GET /search?q=…`.
struct GlobalSearchView: View {

	let onOpenChat: (ChatRoute) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var query = ""
	@State private var response: GlobalSearchResponse? = nil
	@State private var isSearching = false
	@State private var error: String?
	@State private var task: Task<Void, Never>?
	@State private var selectedTab = 0

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				searchBar.padding(.horizontal, 16).padding(.vertical, 10)
				Divider().opacity(0.5)

				if response != nil {
					Picker("", selection: $selectedTab) {
						Text(tabLabel("Чаты", response?.chats.count)).tag(0)
						Text(tabLabel("Сообщения", response?.messages.count)).tag(1)
						Text(tabLabel("Люди", response?.users.count)).tag(2)
					}
					.pickerStyle(.segmented)
					.padding(.horizontal, 16)
					.padding(.vertical, 8)
				}

				ScrollView {
					LazyVStack(spacing: 8) {
						if query.isEmpty {
							hint
						} else if isSearching && response == nil {
							ProgressView().padding(.top, 40)
						} else if let r = response {
							switch selectedTab {
							case 0: chatsList(r.chats)
							case 1: messagesList(r.messages)
							default: usersList(r.users)
							}
						}
					}
					.padding(.vertical, 8)
				}
			}
			.background(Color(.systemGroupedBackground).ignoresSafeArea())
			.navigationTitle("Поиск")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } }
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
	}

	private func tabLabel(_ name: String, _ count: Int?) -> String {
		if let c = count, c > 0 { return "\(name) \(c)" }
		return name
	}

	private var searchBar: some View {
		HStack(spacing: 10) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 15))
				.foregroundStyle(.secondary)
			TextField("Поиск везде", text: $query)
				.font(.system(size: 16))
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.onChange(of: query) { _, q in schedule(q) }
			if isSearching {
				ProgressView().scaleEffect(0.75)
			} else if !query.isEmpty {
				Button { query = ""; response = nil } label: {
					Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
				}.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 14).padding(.vertical, 11)
		.background(Color(.secondarySystemFill))
		.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
	}

	private var hint: some View {
		VStack(spacing: 12) {
			Image(systemName: "text.magnifyingglass")
				.font(.system(size: 40))
				.foregroundStyle(Color.accentColor.opacity(0.25))
			Text("Найти людей, сообщения или чаты")
				.font(.system(size: 16, weight: .medium))
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 60)
	}

	@ViewBuilder
	private func chatsList(_ chats: [GlobalSearchResponse.ChatHit]) -> some View {
		if chats.isEmpty {
			Text("Нет совпадений").foregroundStyle(.secondary).padding(.top, 40)
		} else {
			ForEach(chats) { c in
				row(icon: c.type == "channel" ? "megaphone.fill" : "person.3.fill",
				    color: c.type == "channel" ? .orange : .indigo,
				    title: c.title ?? "Без названия",
				    subtitle: c.type == "channel" ? "Канал" : (c.type == "group" ? "Группа" : "Чат")) {
					onOpenChat(ChatRoute(chatId: c.id, title: c.title ?? "Чат", syncSeq: 0))
					dismiss()
				}
			}
		}
	}

	@ViewBuilder
	private func messagesList(_ msgs: [GlobalSearchResponse.MessageHit]) -> some View {
		if msgs.isEmpty {
			Text("Нет совпадений").foregroundStyle(.secondary).padding(.top, 40)
		} else {
			ForEach(msgs) { m in
				row(icon: "text.bubble.fill", color: .blue,
				    title: m.text ?? "",
				    subtitle: "Чат #\(m.chatId)") {
					onOpenChat(ChatRoute(chatId: m.chatId, title: "Чат", syncSeq: 0))
					dismiss()
				}
			}
		}
	}

	@ViewBuilder
	private func usersList(_ users: [GlobalSearchResponse.UserHit]) -> some View {
		if users.isEmpty {
			Text("Нет совпадений").foregroundStyle(.secondary).padding(.top, 40)
		} else {
			ForEach(users) { u in
				row(icon: "person.fill", color: .purple,
				    title: u.nickname,
				    subtitle: u.username.map { "@\($0)" } ?? "") {
					Task { await openDM(with: u.id, name: u.nickname) }
				}
			}
		}
	}

	private func row(icon: String, color: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 12) {
				ZStack {
					Circle().fill(color.gradient).frame(width: 40, height: 40)
					Image(systemName: icon)
						.font(.system(size: 16, weight: .semibold))
						.foregroundStyle(.white)
				}
				VStack(alignment: .leading, spacing: 2) {
					Text(title).font(.system(size: 15, weight: .medium))
						.foregroundStyle(.primary).lineLimit(1)
					if !subtitle.isEmpty {
						Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
					}
				}
				Spacer()
				Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
			}
			.padding(.horizontal, 14).padding(.vertical, 10)
			.background(Color(.secondarySystemGroupedBackground))
			.clipShape(RoundedRectangle(cornerRadius: 12))
			.padding(.horizontal, 16)
		}
		.buttonStyle(.plain)
	}

	private func schedule(_ q: String) {
		task?.cancel()
		let trimmed = q.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { response = nil; isSearching = false; return }
		task = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 350_000_000)
			if Task.isCancelled { return }
			await search(trimmed)
		}
	}

	@MainActor
	private func search(_ q: String) async {
		isSearching = true; defer { isSearching = false }
		do {
			response = try await UserService.shared.globalSearch(query: q)
		} catch {
			Log.network.error("globalSearch failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor
	private func openDM(with userId: Int, name: String) async {
		do {
			let chat = try await ChatService.shared.createChat(withUserId: userId)
			onOpenChat(ChatRoute(chatId: chat.id, title: name, syncSeq: chat.syncSeq))
			dismiss()
		} catch {
			Log.chat.error("createChat failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
