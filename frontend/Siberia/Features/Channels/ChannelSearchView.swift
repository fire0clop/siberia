import SwiftUI

/// Поиск публичных каналов + подписка.
struct ChannelSearchView: View {

	let onJoined: (ChatRoute) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var query = ""
	@State private var results: [ChannelSearchResult] = []
	@State private var isSearching = false
	@State private var busyId: Int?
	@State private var error: String?
	@State private var searchTask: Task<Void, Never>?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				searchBar
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
				Divider().opacity(0.5)

				ScrollView {
					LazyVStack(spacing: 8) {
						if !query.isEmpty && results.isEmpty && !isSearching {
							ContentUnavailableView.search(text: query)
								.padding(.top, 40)
						} else if query.isEmpty {
							hint
						} else {
							ForEach(results) { channel in
								channelRow(channel)
							}
						}
					}
					.padding(.top, 8)
					.padding(.bottom, 24)
				}
			}
			.background(Color(.systemGroupedBackground).ignoresSafeArea())
			.navigationTitle("Каналы")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Готово") { dismiss() }
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
	}

	private var searchBar: some View {
		HStack(spacing: 10) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 15))
				.foregroundStyle(.secondary)
			TextField("Найти канал", text: $query)
				.font(.system(size: 16))
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
				.onChange(of: query) { _, q in scheduleSearch(q) }
			if isSearching {
				ProgressView().scaleEffect(0.75)
			} else if !query.isEmpty {
				Button { query = ""; results = [] } label: {
					Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)
		.background(Color(.secondarySystemFill))
		.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
	}

	private var hint: some View {
		VStack(spacing: 12) {
			Image(systemName: "megaphone")
				.font(.system(size: 40))
				.foregroundStyle(Color.accentColor.opacity(0.25))
			Text("Введите название канала")
				.font(.system(size: 16, weight: .medium))
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 60)
	}

	private func channelRow(_ c: ChannelSearchResult) -> some View {
		HStack(spacing: 12) {
			ZStack {
				Circle().fill(
					LinearGradient(
						colors: [Color.orange, Color.pink],
						startPoint: .topLeading, endPoint: .bottomTrailing
					)
				)
				Image(systemName: "megaphone.fill")
					.font(.system(size: 18, weight: .semibold))
					.foregroundStyle(.white)
			}
			.frame(width: 46, height: 46)

			VStack(alignment: .leading, spacing: 3) {
				Text(c.title ?? "Без названия")
					.font(.system(size: 16, weight: .semibold))
					.lineLimit(1)
				if let d = c.description, !d.isEmpty {
					Text(d).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
				}
				Text("\(c.subscribersCount) подписчиков")
					.font(.system(size: 11))
					.foregroundStyle(.tertiary)
			}

			Spacer()

			Button {
				Task { await subscribe(c) }
			} label: {
				if busyId == c.id {
					ProgressView().scaleEffect(0.8)
				} else {
					Text("Подписаться")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.background(Color.accentColor)
						.clipShape(Capsule())
				}
			}
			.disabled(busyId != nil)
		}
		.padding(12)
		.background(Color(.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.padding(.horizontal, 16)
	}

	private func scheduleSearch(_ q: String) {
		searchTask?.cancel()
		let trimmed = q.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { results = []; isSearching = false; return }
		searchTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 350_000_000)
			if Task.isCancelled { return }
			await doSearch(trimmed)
		}
	}

	@MainActor
	private func doSearch(_ q: String) async {
		isSearching = true
		defer { isSearching = false }
		do {
			results = try await ChannelService.shared.searchPublic(query: q)
		} catch {
			Log.network.error("channel search failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor
	private func subscribe(_ c: ChannelSearchResult) async {
		busyId = c.id
		defer { busyId = nil }
		do {
			let chat = try await ChannelService.shared.subscribe(channelId: c.id)
			let route = ChatRoute(chatId: chat.id, title: c.title ?? "Канал", syncSeq: chat.syncSeq)
			onJoined(route)
			dismiss()
		} catch {
			Log.chat.error("subscribe failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
