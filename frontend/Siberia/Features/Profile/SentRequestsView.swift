import SwiftUI

struct SentRequestsView: View {

	@Binding var requests: [FriendRequestItem]
	let onChange: () -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var busyId: Int?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Group {
				if requests.isEmpty {
					ContentUnavailableView(
						"Нет исходящих заявок",
						systemImage: "paperplane",
						description: Text("Заявки в друзья, которые вы отправили, появятся здесь.")
					)
				} else {
					List {
						ForEach(requests) { r in
							HStack(spacing: 12) {
								Circle().fill(Color.gray.gradient).frame(width: 36, height: 36)
									.overlay(Text(String(r.user.nickname.prefix(1)).uppercased())
										.font(.system(size: 14, weight: .semibold))
										.foregroundStyle(.white))
								VStack(alignment: .leading, spacing: 2) {
									Text(r.user.nickname).font(.system(size: 15, weight: .medium))
									Text("Ожидает ответа")
										.font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								Button {
									Task { await cancel(r) }
								} label: {
									if busyId == r.requestId {
										ProgressView().scaleEffect(0.8)
									} else {
										Text("Отозвать")
											.font(.system(size: 13, weight: .semibold))
											.foregroundStyle(.white)
											.padding(.horizontal, 10).padding(.vertical, 6)
											.background(Color.gray)
											.clipShape(Capsule())
									}
								}
								.disabled(busyId != nil)
							}
						}
					}
				}
			}
			.navigationTitle("Исходящие заявки")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
		}
		.task { onChange() }
	}

	@MainActor private func cancel(_ r: FriendRequestItem) async {
		busyId = r.requestId; defer { busyId = nil }
		do {
			// Backend reject endpoint работает и для отозвания собственной заявки
			// (на самом деле — лучше DELETE friend, но проще: rejected с обеих сторон удаляет связь)
			try await FriendService.shared.reject(requestId: r.requestId)
			requests.removeAll { $0.requestId == r.requestId }
		} catch {
			Log.profile.error("cancel sent request failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
