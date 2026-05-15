import SwiftUI

struct AddFriendView: View {

	@EnvironmentObject private var appState: AppState
	@Environment(\.scenePhase) private var scenePhase

	@State private var friends:       [User]   = []
	@State private var searchResults: [User]   = []
	@State private var searchText   = ""
	@State private var isSearching  = false
	@State private var busyIds:     Set<Int>   = []
	@State private var notice:      String?
	@State private var navPath      = NavigationPath()
	@State private var searchTask:  Task<Void, Never>?

	private var isInSearch: Bool { !searchText.isEmpty }

	// MARK: – Body

	var body: some View {
		NavigationStack(path: $navPath) {
			VStack(spacing: 0) {
				searchBar
					.padding(.horizontal, 16)
					.padding(.vertical, 10)

				Divider().opacity(0.5)

				Group {
					if isInSearch { searchContent } else { friendsContent }
				}
			}
			.background(Color(.systemGroupedBackground).ignoresSafeArea())
			.navigationTitle("Люди")
			.navigationBarTitleDisplayMode(.large)
			.navigationDestination(for: ChatRoute.self) { ChatDetailView(route: $0) }
			.alert("Сообщение", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
				Button("OK", role: .cancel) { notice = nil }
			} message: { Text(notice ?? "") }
		}
		.task { await loadFriends() }
		.onChange(of: scenePhase) { _, p in if p == .active { Task { await loadFriends() } } }
	}

	// MARK: – Search bar

	private var searchBar: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(.secondary)

			TextField("Найти по нику", text: $searchText)
				.font(.system(size: 16))
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.onChange(of: searchText) { _, q in scheduleSearch(q) }

			if isSearching {
				ProgressView().scaleEffect(0.8)
			} else if !searchText.isEmpty {
				Button { searchText = ""; searchResults = [] } label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 15))
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(Color(.secondarySystemFill))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	// MARK: – Friends

	@ViewBuilder
	private var friendsContent: some View {
		if friends.isEmpty {
			ContentUnavailableView(
				"Нет друзей",
				systemImage: "person.2",
				description: Text("Найдите кого-нибудь через поиск выше.")
			)
		} else {
			ScrollView {
				sectionLabel("Мои друзья · \(friends.count)")
				LazyVStack(spacing: 8) {
					ForEach(friends) { user in
						userCard(user, isFriend: true)
					}
				}
				.padding(.horizontal, 16)
				.padding(.bottom, 20)
			}
			.refreshable { await loadFriends() }
		}
	}

	// MARK: – Search results

	@ViewBuilder
	private var searchContent: some View {
		if searchResults.isEmpty && !isSearching {
			ContentUnavailableView.search(text: searchText)
		} else {
			ScrollView {
				if !searchResults.isEmpty {
					sectionLabel("Результаты поиска")
				}
				LazyVStack(spacing: 8) {
					ForEach(searchResults) { user in
						userCard(user, isFriend: friends.contains(where: { $0.id == user.id }))
					}
				}
				.padding(.horizontal, 16)
				.padding(.bottom, 20)
			}
		}
	}

	// MARK: – User card

	@ViewBuilder
	private func userCard(_ user: User, isFriend: Bool) -> some View {
		let (c1, c2) = paletteColors(for: user.nickname)
		let grad = LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
		let busy = busyIds.contains(user.id)

		HStack(spacing: 0) {
			// Color bar
			grad
				.opacity(0.55)
				.frame(width: 4)
				.clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
				.padding(.vertical, 14)

			// Avatar
			ZStack {
				Circle()
					.strokeBorder(grad.opacity(0.45), lineWidth: 2.5)
					.frame(width: 55, height: 55)
				avatarCircle(user.nickname, size: 49)
			}
			.padding(.leading, 12)

			// Info
			VStack(alignment: .leading, spacing: 3) {
				Text(user.nickname)
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				if let email = user.email {
					Text(email)
						.font(.system(size: 13))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			.padding(.leading, 12)

			Spacer(minLength: 8)

			// Action button
			if busy {
				ProgressView().scaleEffect(0.8).padding(.trailing, 16)
			} else if isFriend {
				Button { Task { await openChat(with: user) } } label: {
					Image(systemName: "message.fill")
						.font(.system(size: 14, weight: .semibold))
						.foregroundStyle(.white)
						.frame(width: 36, height: 36)
						.background(grad)
						.clipShape(Circle())
				}
				.buttonStyle(.plain)
				.padding(.trailing, 16)
			} else {
				Button { Task { await addFriend(user) } } label: {
					Image(systemName: "person.badge.plus")
						.font(.system(size: 14, weight: .semibold))
						.foregroundStyle(c1)
						.frame(width: 36, height: 36)
						.background(c1.opacity(0.12))
						.clipShape(Circle())
				}
				.buttonStyle(.plain)
				.padding(.trailing, 16)
			}
		}
		.padding(.vertical, 8)
		.background(Color(.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.shadow(color: .black.opacity(0.06), radius: 6, y: 2)
	}

	// MARK: – Avatar

	private func avatarCircle(_ name: String, size: CGFloat) -> some View {
		let (c1, c2) = paletteColors(for: name)
		return ZStack {
			Circle().fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
			Text(String(name.prefix(1)).uppercased())
				.font(.system(size: size * 0.37, weight: .semibold))
				.foregroundStyle(.white)
		}
		.frame(width: size, height: size)
	}

	private func paletteColors(for name: String) -> (Color, Color) {
		let t: [(String, String)] = [
			("5B8DEF","2B5BD7"), ("B48EFF","7C3AED"), ("FB923C","EA580C"),
			("F472B6","BE185D"), ("34D399","059669"), ("22D3EE","0E7490"), ("FBBF24","D97706"),
		]
		let i = abs(name.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % t.count
		return (Color(hex: t[i].0), Color(hex: t[i].1))
	}

	private func sectionLabel(_ text: String) -> some View {
		Text(text.uppercased())
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.top, 14)
			.padding(.bottom, 6)
	}

	// MARK: – Actions

	private func scheduleSearch(_ q: String) {
		searchTask?.cancel()
		let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !t.isEmpty else { searchResults = []; return }
		searchTask = Task {
			try? await Task.sleep(nanoseconds: 350_000_000)
			guard !Task.isCancelled else { return }
			isSearching = true
			if let r = try? await UserService.shared.searchUsers(query: t) { searchResults = r }
			isSearching = false
		}
	}

	private func loadFriends() async {
		if let list = try? await FriendService.shared.getFriends() { friends = list }
	}

	private func addFriend(_ user: User) async {
		busyIds.insert(user.id); defer { busyIds.remove(user.id) }
		do {
			try await FriendService.shared.addFriend(userId: user.id)
			notice = "Заявка отправлена \(user.nickname)"
			await loadFriends()
		} catch { notice = error.localizedDescription }
	}

	private func openChat(with user: User) async {
		busyIds.insert(user.id); defer { busyIds.remove(user.id) }
		do {
			let chat = try await ChatService.shared.createChat(withUserId: user.id)
			navPath.append(ChatRoute(chatId: chat.id, title: user.nickname, syncSeq: chat.syncSeq))
		} catch { notice = error.localizedDescription }
	}
}
