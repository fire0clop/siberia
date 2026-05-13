import SwiftUI

struct EditHistorySheet: View {

	let messageId: Int
	@Environment(\.dismiss) private var dismiss

	@State private var versions: [MessageHistoryResponse.Version] = []
	@State private var isLoading = false
	@State private var error: String?

	private let formatter: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "ru_RU")
		f.dateFormat = "d MMM, HH:mm"
		return f
	}()
	private let iso = ISO8601DateFormatter()

	var body: some View {
		NavigationStack {
			Group {
				if isLoading && versions.isEmpty {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if versions.count <= 1 {
					ContentUnavailableView(
						"Сообщение не редактировалось",
						systemImage: "pencil.slash"
					)
				} else {
					List {
						ForEach(Array(versions.enumerated()), id: \.offset) { idx, v in
							VStack(alignment: .leading, spacing: 6) {
								HStack {
									if idx == versions.count - 1 {
										Text("Текущая версия")
											.font(.caption.bold())
											.foregroundStyle(Color.accentColor)
									} else if idx == 0 {
										Text("Оригинал")
											.font(.caption.bold())
											.foregroundStyle(.secondary)
									} else {
										Text("Версия \(idx + 1)")
											.font(.caption.bold())
											.foregroundStyle(.secondary)
									}
									Spacer()
									Text(formatTime(v.editedAt))
										.font(.caption2)
										.foregroundStyle(.tertiary)
								}
								Text(v.text ?? "(пусто)")
									.font(.system(size: 15))
									.padding(10)
									.frame(maxWidth: .infinity, alignment: .leading)
									.background(idx == versions.count - 1
												? Color.accentColor.opacity(0.10)
												: Color(.secondarySystemBackground))
									.clipShape(RoundedRectangle(cornerRadius: 10))
							}
							.padding(.vertical, 4)
						}
					}
				}
			}
			.navigationTitle("История изменений")
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

	private func formatTime(_ s: String?) -> String {
		guard let s, let d = iso.date(from: s) else { return "" }
		return formatter.string(from: d)
	}

	@MainActor private func load() async {
		isLoading = true; defer { isLoading = false }
		do {
			let r = try await ChatService.shared.messageHistory(messageId: messageId)
			versions = r.versions
		} catch {
			Log.chat.error("messageHistory failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
