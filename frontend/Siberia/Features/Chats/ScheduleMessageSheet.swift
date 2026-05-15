import SwiftUI

/// Sheet выбора даты для отложенной отправки.
struct ScheduleMessageSheet: View {

	let onSelect: (Date) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var date: Date = Date().addingTimeInterval(3600)

	var body: some View {
		NavigationStack {
			Form {
				Section("Когда отправить") {
					DatePicker(
						"Дата и время",
						selection: $date,
						in: Date()...,
						displayedComponents: [.date, .hourAndMinute]
					)
					.datePickerStyle(.graphical)
				}
				Section("Быстрый выбор") {
					quickButton("Через час",  offset: 3600)
					quickButton("Завтра 9:00", date: nextDayAt(hour: 9))
					quickButton("Через неделю", offset: 7 * 86_400)
				}
			}
			.navigationTitle("Отложенная отправка")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("Отправить") {
						onSelect(date)
						dismiss()
					}
					.fontWeight(.semibold)
					.disabled(date <= Date())
				}
			}
		}
	}

	private func quickButton(_ title: String, offset: TimeInterval) -> some View {
		Button(title) {
			date = Date().addingTimeInterval(offset)
		}
	}

	private func quickButton(_ title: String, date: Date) -> some View {
		Button(title) { self.date = date }
	}

	private func nextDayAt(hour: Int) -> Date {
		let cal = Calendar.current
		let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
		return cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
	}
}

/// Список отложенных сообщений в чате с возможностью отменить.
struct ScheduledMessagesSheet: View {

	let chatId: Int
	@Environment(\.dismiss) private var dismiss

	@State private var messages: [ChatMessage] = []
	@State private var isLoading = false
	@State private var busyId: Int?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Group {
				if isLoading {
					ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if messages.isEmpty {
					ContentUnavailableView(
						"Нет отложенных сообщений",
						systemImage: "clock.arrow.circlepath"
					)
				} else {
					List {
						ForEach(messages) { m in
							HStack(alignment: .top, spacing: 12) {
								VStack(alignment: .leading, spacing: 4) {
									Text(m.text ?? "—").font(.system(size: 14))
									Text("Отправится через сервер")
										.font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								Button(role: .destructive) {
									Task { await cancel(m) }
								} label: {
									if busyId == m.id {
										ProgressView().scaleEffect(0.7)
									} else {
										Image(systemName: "xmark.circle.fill")
											.font(.title3)
									}
								}
								.disabled(busyId != nil)
							}
							.padding(.vertical, 4)
						}
					}
				}
			}
			.navigationTitle("Отложенные")
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

	@MainActor private func load() async {
		isLoading = true; defer { isLoading = false }
		do {
			messages = try await ChatService.shared.listScheduledMessages(chatId: chatId)
		} catch {
			Log.chat.error("listScheduled failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func cancel(_ m: ChatMessage) async {
		busyId = m.id; defer { busyId = nil }
		do {
			try await ChatService.shared.cancelScheduled(messageId: m.id)
			messages.removeAll { $0.id == m.id }
		} catch {
			Log.chat.error("cancelScheduled failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}
