import SwiftUI

private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥", "👏", "🎉"]

struct ReactionPickerView: View {

	let message: ChatMessage
	let currentUserId: Int?
	let onReact: (String) -> Void

	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(spacing: 16) {
			Capsule()
				.fill(Color.secondary.opacity(0.4))
				.frame(width: 36, height: 5)
				.padding(.top, 8)

			Text("Реакция")
				.font(.subheadline.bold())

			HStack(spacing: 12) {
				ForEach(quickEmojis, id: \.self) { emoji in
					let alreadyReacted = message.reactions?
						.first(where: { $0.emoji == emoji })?
						.userIds?.contains(currentUserId ?? -1) ?? false

					Button {
						onReact(emoji)
						dismiss()
					} label: {
						Text(emoji)
							.font(.system(size: 30))
							.padding(8)
							.background(
								Circle()
									.fill(alreadyReacted
										  ? Color.blue.opacity(0.15)
										  : Color(.tertiarySystemBackground))
							)
							.overlay(
								Circle()
									.stroke(alreadyReacted ? Color.blue : Color.clear, lineWidth: 2)
							)
					}
					.scaleEffect(alreadyReacted ? 1.1 : 1.0)
					.animation(.spring(response: 0.2), value: alreadyReacted)
				}
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 20)
		}
		.presentationDetents([.height(160)])
		.presentationDragIndicator(.hidden)
	}
}
