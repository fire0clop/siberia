import Foundation
import UserNotifications

// MARK: – Per-chat Do Not Disturb schedule (client-side, UserDefaults)

struct ChatDnDSchedule: Codable, Equatable {
	var enabled: Bool = false
	var fromHour: Int = 23
	var fromMinute: Int = 0
	var toHour: Int = 7
	var toMinute: Int = 0

	/// Returns true if *now* falls within the DnD window.
	func isActiveNow() -> Bool {
		guard enabled else { return false }
		let cal = Calendar.current
		let now = Date()
		let nowH = cal.component(.hour, from: now)
		let nowM = cal.component(.minute, from: now)
		let nowMins = nowH * 60 + nowM
		let fromMins = fromHour * 60 + fromMinute
		let toMins   = toHour   * 60 + toMinute

		if fromMins <= toMins {
			// Same day: e.g. 09:00 – 18:00
			return nowMins >= fromMins && nowMins < toMins
		} else {
			// Overnight: e.g. 23:00 – 07:00
			return nowMins >= fromMins || nowMins < toMins
		}
	}

	var displayString: String {
		guard enabled else { return "Выкл." }
		let f = { (h: Int, m: Int) in String(format: "%02d:%02d", h, m) }
		return "\(f(fromHour, fromMinute)) – \(f(toHour, toMinute))"
	}
}

// MARK: – Store

final class ChatNotificationSettingsStore {

	static let shared = ChatNotificationSettingsStore()
	private init() {}

	private let defaults = UserDefaults.standard
	private func key(_ chatId: Int) -> String { "dnd_schedule_\(chatId)" }

	func schedule(for chatId: Int) -> ChatDnDSchedule {
		guard let data = defaults.data(forKey: key(chatId)),
		      let s = try? JSONDecoder().decode(ChatDnDSchedule.self, from: data)
		else { return ChatDnDSchedule() }
		return s
	}

	func save(_ schedule: ChatDnDSchedule, for chatId: Int) {
		guard let data = try? JSONEncoder().encode(schedule) else { return }
		defaults.set(data, forKey: key(chatId))
	}

	func isDnDActive(for chatId: Int) -> Bool {
		schedule(for: chatId).isActiveNow()
	}
}

// MARK: – SwiftUI settings sheet

import SwiftUI

struct ChatNotificationSettingsSheet: View {
	let chatId: Int
	let chatTitle: String
	@Environment(\.dismiss) private var dismiss

	@State private var schedule: ChatDnDSchedule

	init(chatId: Int, chatTitle: String) {
		self.chatId = chatId
		self.chatTitle = chatTitle
		let s = ChatNotificationSettingsStore.shared.schedule(for: chatId)
		self._schedule = State(initialValue: s)
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Toggle("Режим «Не беспокоить»", isOn: $schedule.enabled)
				} footer: {
					Text("При включённом режиме уведомления из этого чата не показываются в указанный промежуток времени.")
						.font(.caption)
				}

				if schedule.enabled {
					Section("Расписание") {
						HStack {
							Text("С")
							Spacer()
							timePicker(hour: $schedule.fromHour, minute: $schedule.fromMinute)
						}
						HStack {
							Text("До")
							Spacer()
							timePicker(hour: $schedule.toHour, minute: $schedule.toMinute)
						}
					}

					Section {
						HStack {
							Image(systemName: "info.circle").foregroundStyle(.secondary)
							Text("Сейчас: \(schedule.isActiveNow() ? "режим активен" : "обычный режим")")
								.foregroundStyle(.secondary)
								.font(.footnote)
						}
					}
				}
			}
			.navigationTitle("Уведомления")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Отмена") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Сохранить") {
						ChatNotificationSettingsStore.shared.save(schedule, for: chatId)
						dismiss()
					}
					.fontWeight(.semibold)
				}
			}
		}
	}

	private func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
		HStack(spacing: 4) {
			Picker("", selection: hour) {
				ForEach(0..<24, id: \.self) { h in
					Text(String(format: "%02d", h)).tag(h)
				}
			}
			.pickerStyle(.wheel)
			.frame(width: 54, height: 100).clipped()
			Text(":").font(.title3.bold())
			Picker("", selection: minute) {
				ForEach([0, 15, 30, 45], id: \.self) { m in
					Text(String(format: "%02d", m)).tag(m)
				}
			}
			.pickerStyle(.wheel)
			.frame(width: 54, height: 100).clipped()
		}
	}
}
