import SwiftUI

// MARK: – Single message bubble (text, media, voice, audio, file, deleted)

struct MessageBubbleView: View {
	let message: ChatMessage
	let mine: Bool
	@ObservedObject var vm: ChatDetailViewModel
	@ObservedObject var voice: VoiceRecorder
	let onScrollTo: (Int) -> Void        // scroll-to-message (for reply quotes)
	let onOpenGallery: (Int) -> Void     // open fullscreen gallery at index
	let onSetHistoryId: (Int) -> Void    // show edit history sheet

	private static let timeFmt: DateFormatter = {
		let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
	}()
	private static let isoFull: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	var body: some View {
		let pending = vm.isPending(message)
		VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
			if !mine && vm.isGroup {
				Text(senderName(message))
					.font(.caption.bold())
					.foregroundStyle(nameColor(userId: message.userId ?? 0))
					.padding(.leading, 2)
			}
			if message.isForwarded {
				let originName = vm.chatMembers
					.first(where: { $0.userId == message.forwardedFromUserId })?.user.nickname
					?? (message.forwardedFromUserId.map { "User \($0)" } ?? "Неизвестно")
				HStack(spacing: 4) {
					Image(systemName: "arrowshape.turn.up.right").font(.caption2)
					Text("Переслано от \(originName)").font(.caption2.weight(.medium))
				}
				.foregroundStyle(mine ? Color.white : ChatDetailView.accent)
				.padding(.horizontal, 10)
				.padding(.top, 6)
				.padding(.bottom, 2)
			}
			bubbleContent(message, mine: mine, pending: pending)
			reactionsRow(message)
		}
	}

	// MARK: – Bubble dispatcher

	@ViewBuilder
	private func bubbleContent(_ m: ChatMessage, mine: Bool, pending: Bool) -> some View {
		if m.isDeleted {
			deletedBubble()
		} else if let mediaId = m.mediaId, let mediaType = m.mediaType {
			mediaBubble(mediaId: mediaId, mediaType: mediaType, m: m, mine: mine, pending: pending)
		} else {
			textBubble(m, mine: mine, pending: pending)
		}
	}

	// MARK: – Text bubble

	@ViewBuilder
	private func textBubble(_ m: ChatMessage, mine: Bool, pending: Bool) -> some View {
		let quoted = m.replyToMessageId.flatMap { rId in vm.messages.first(where: { $0.id == rId }) }
		VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
			if let q = quoted {
				replyQuote(q, mine: mine)
					.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
			}
			VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
				if let t = m.text, !t.isEmpty { mentionText(t, mine: mine) }
				timeRow(m, mine: mine, pending: pending)
			}
			.padding(.horizontal, 12)
			.padding(.top, quoted != nil ? 4 : 8)
			.padding(.bottom, 6)
		}
		.frame(maxWidth: UIScreen.main.bounds.width * 0.72)
		.fixedSize(horizontal: true, vertical: false)
		.background(mine ? AnyShapeStyle(ChatDetailView.mineGrad) : AnyShapeStyle(ChatDetailView.otherBg))
		.clipShape(tailShape(mine: mine))
		.shadow(color: .black.opacity(0.07), radius: 2, x: 0, y: 1)
		.opacity(pending ? 0.72 : 1)
	}

	// MARK: – Media bubble

	@ViewBuilder
	private func mediaBubble(mediaId: String, mediaType: String, m: ChatMessage, mine: Bool, pending: Bool) -> some View {
		let quoted = m.replyToMessageId.flatMap { rId in vm.messages.first(where: { $0.id == rId }) }
		switch mediaType {

		case "image":
			VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
				if let q = quoted {
					replyQuote(q, mine: mine)
						.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
				}
				imageBubbleContent(mediaId: mediaId, mine: mine)
				if let t = m.text, !t.isEmpty {
					mentionText(t, mine: mine).padding(.horizontal, 10).padding(.top, 5)
				}
				timeRow(m, mine: mine, pending: pending)
					.padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
			}
			.background(mine ? AnyShapeStyle(ChatDetailView.mineGrad) : AnyShapeStyle(ChatDetailView.otherBg))
			.clipShape(tailShape(mine: mine))
			.shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
			.opacity(pending ? 0.72 : 1)

		case "video", "video_note":
			VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
				if let q = quoted {
					replyQuote(q, mine: mine)
						.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
				}
				VideoThumbView(mediaId: mediaId, vm: vm) {
					if let idx = vm.allMediaItems.firstIndex(where: { $0.id == mediaId }) {
						onOpenGallery(idx)
					}
				}
				timeRow(m, mine: mine, pending: pending)
					.padding(.horizontal, 10).padding(.vertical, 5)
					.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
					.background(mine ? AnyShapeStyle(ChatDetailView.mineGrad) : AnyShapeStyle(ChatDetailView.otherBg))
			}
			.clipShape(tailShape(mine: mine))
			.shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
			.opacity(pending ? 0.72 : 1)

		default:
			VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
				if let q = quoted { replyQuote(q, mine: mine) }
				inlineMediaContent(mediaId: mediaId, mediaType: mediaType, m: m, mine: mine)
				if let t = m.text, !t.isEmpty { mentionText(t, mine: mine) }
				timeRow(m, mine: mine, pending: pending)
			}
			.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
			.background(mine ? AnyShapeStyle(ChatDetailView.mineGrad) : AnyShapeStyle(ChatDetailView.otherBg))
			.clipShape(tailShape(mine: mine))
			.shadow(color: .black.opacity(0.07), radius: 2, x: 0, y: 1)
			.opacity(pending ? 0.72 : 1)
		}
	}

	// MARK: – Image content

	@ViewBuilder
	private func imageBubbleContent(mediaId: String, mine: Bool) -> some View {
		let urlStr = vm.mediaURLCache[mediaId]
		if let s = urlStr, let url = URL(string: s) {
			AsyncImage(url: url) { ph in
				switch ph {
				case .success(let img):
					img.resizable()
						.scaledToFit()
						.frame(maxWidth: 240, maxHeight: 320)
						.clipped()
						.onTapGesture {
							if let idx = vm.allMediaItems.firstIndex(where: { $0.id == mediaId }) {
								onOpenGallery(idx)
							}
						}
				case .failure:
					mediaSkeleton(240, 200)
						.task {
							vm.mediaURLCache.removeValue(forKey: mediaId)
							_ = await vm.loadMediaURL(mediaId: mediaId)
						}
				default: mediaSkeleton(240, 200)
				}
			}
		} else {
			mediaSkeleton(240, 200)
				.task { _ = await vm.loadMediaURL(mediaId: mediaId) }
		}
	}

	// MARK: – Inline media (voice / audio / document)

	@ViewBuilder
	private func inlineMediaContent(mediaId: String, mediaType: String, m: ChatMessage, mine: Bool) -> some View {
		switch mediaType {
		case "voice":  voiceControl(mediaId: mediaId, mine: mine)
		case "audio":  audioControl(mediaId: mediaId, mine: mine)
		default:       fileContent(mediaId: mediaId, m: m, mine: mine)
		}
	}

	// MARK: – Voice

	@ViewBuilder
	private func voiceControl(mediaId: String, mine: Bool) -> some View {
		let urlStr = vm.mediaURLCache[mediaId]
		let waveform = vm.mediaWaveforms[mediaId] ?? syntheticWaveform(mediaId: mediaId)
		let isThisPlaying = voice.currentlyPlayingMediaId == mediaId
		let durationStr: String = {
			if let d = vm.mediaDurations[mediaId] {
				return VoiceRecorder.format(TimeInterval(d))
			}
			return "0:00"
		}()
		HStack(spacing: 8) {
			playButton(isPlaying: isThisPlaying, mine: mine) {
				if isThisPlaying { voice.stopPlaying() }
				else if let s = urlStr, let url = URL(string: s) { voice.play(url: url, mediaId: mediaId) }
				else { Task {
					guard let s = await vm.loadMediaURL(mediaId: mediaId),
					      let url = URL(string: s) else { return }
					voice.play(url: url, mediaId: mediaId)
				}}
			}
			VoiceWaveformView(
				bars: waveform,
				progress: isThisPlaying ? voice.playbackProgress : 0,
				tint: mine ? .white : ChatDetailView.accent,
				background: mine ? Color.white.opacity(0.32) : ChatDetailView.accent.opacity(0.22)
			)
			.frame(width: 110)
			.animation(.linear(duration: 0.05), value: voice.playbackProgress)
			Text(durationStr)
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(mine ? .white.opacity(0.65) : .secondary)
		}
		.frame(width: 210)
	}

	private func syntheticWaveform(mediaId: String, count: Int = 28) -> [Float] {
		var seed = UInt64(truncatingIfNeeded: abs(mediaId.hashValue))
		return (0..<count).map { _ in
			seed = seed &* 6364136223846793005 &+ 1442695040888963407
			return 0.08 + Float((seed >> 33) & 0xFFFF) / Float(0xFFFF) * 0.92
		}
	}

	// MARK: – Audio track

	@ViewBuilder
	private func audioControl(mediaId: String, mine: Bool) -> some View {
		let name = vm.mediaOriginalNames[mediaId] ?? "Аудио"
		HStack(spacing: 12) {
			playButton(isPlaying: voice.isPlaying, mine: mine) {
				if voice.isPlaying { voice.stopPlaying() }
				else { Task {
					guard let s = await vm.loadMediaURL(mediaId: mediaId),
					      let url = URL(string: s) else { return }
					voice.play(url: url)
				}}
			}
			VStack(alignment: .leading, spacing: 4) {
				Text(name).font(.caption.weight(.medium))
					.foregroundStyle(mine ? .white : .primary).lineLimit(1)
				progressBar(progress: voice.playbackProgress, mine: mine)
			}
		}
		.frame(width: 210)
	}

	private func playButton(isPlaying: Bool, mine: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			ZStack {
				Circle()
					.fill(mine ? Color.white.opacity(0.2) : ChatDetailView.accent.opacity(0.1))
					.frame(width: 40, height: 40)
				Image(systemName: isPlaying ? "pause.fill" : "play.fill")
					.font(.system(size: 14, weight: .bold))
					.foregroundStyle(mine ? .white : ChatDetailView.accent)
					.offset(x: isPlaying ? 0 : 1)
			}
		}
	}

	private func progressBar(progress: Double, mine: Bool) -> some View {
		GeometryReader { geo in
			ZStack(alignment: .leading) {
				Capsule().fill(mine ? Color.white.opacity(0.25) : Color(.systemFill)).frame(height: 3)
				Capsule().fill(mine ? Color.white : ChatDetailView.accent)
					.frame(width: geo.size.width * CGFloat(progress), height: 3)
			}
		}
		.frame(height: 3)
	}

	// MARK: – File

	@ViewBuilder
	private func fileContent(mediaId: String, m: ChatMessage, mine: Bool) -> some View {
		let name = vm.mediaOriginalNames[mediaId] ?? m.text ?? "Файл"
		let ext  = (name as NSString).pathExtension.uppercased()

		HStack(alignment: .top, spacing: 10) {
			ZStack {
				RoundedRectangle(cornerRadius: 10)
					.fill(mine ? Color.white.opacity(0.18) : ChatDetailView.accent.opacity(0.1))
					.frame(width: 44, height: 44)
				VStack(spacing: 1) {
					Image(systemName: extIcon(ext))
						.font(.system(size: 17)).foregroundStyle(mine ? .white : ChatDetailView.accent)
					if !ext.isEmpty {
						Text(ext).font(.system(size: 7, weight: .bold))
							.foregroundStyle(mine ? .white.opacity(0.6) : ChatDetailView.accent.opacity(0.7))
					}
				}
			}
			VStack(alignment: .leading, spacing: 3) {
				Text(name).font(.subheadline.weight(.medium))
					.foregroundStyle(mine ? .white : .primary).lineLimit(2)
				if let s = vm.mediaURLCache[mediaId], let url = URL(string: s) {
					Link("Открыть ↗", destination: url)
						.font(.caption).foregroundStyle(mine ? .white.opacity(0.8) : ChatDetailView.accent)
				} else {
					Text("Загрузка…").font(.caption)
						.foregroundStyle(mine ? .white.opacity(0.5) : .secondary)
						.task { _ = await vm.loadMediaURL(mediaId: mediaId) }
				}
			}
		}
		.frame(width: 216, alignment: .leading)
	}

	private func extIcon(_ ext: String) -> String {
		switch ext {
		case "PDF":                    return "doc.richtext.fill"
		case "DOC", "DOCX":           return "doc.text.fill"
		case "XLS", "XLSX":           return "tablecells.fill"
		case "PPT", "PPTX":          return "rectangle.on.rectangle.angled.fill"
		case "ZIP", "RAR", "7Z":      return "archivebox.fill"
		case "MP3", "M4A", "WAV", "OGG", "FLAC": return "music.note"
		case "TXT", "MD":             return "doc.plaintext.fill"
		default:                       return "doc.fill"
		}
	}

	private func mediaSkeleton(_ w: CGFloat, _ h: CGFloat) -> some View {
		Rectangle().fill(Color(.systemFill)).frame(width: w, height: h)
			.overlay(ProgressView().tint(.secondary))
	}

	// MARK: – Deleted bubble

	private func deletedBubble() -> some View {
		HStack(spacing: 6) {
			Image(systemName: "trash").font(.caption)
			Text("Сообщение удалено").italic()
		}
		.font(.subheadline).foregroundStyle(.secondary)
		.padding(.horizontal, 12).padding(.vertical, 8)
		.background(Color(.tertiarySystemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16))
	}

	// MARK: – Reply quote

	@ViewBuilder
	private func replyQuote(_ quoted: ChatMessage, mine: Bool) -> some View {
		Button { onScrollTo(quoted.id) } label: {
			HStack(alignment: .center, spacing: 7) {
				RoundedRectangle(cornerRadius: 2)
					.fill(mine ? Color.white : ChatDetailView.accent)
					.frame(width: 3, height: 34)
				if let mid = quoted.mediaId, let mtype = quoted.mediaType {
					ReplyThumbnailView(mediaId: mid, mediaType: mtype, mine: mine, vm: vm)
				}
				VStack(alignment: .leading, spacing: 2) {
					Text(senderName(quoted))
						.font(.system(size: 11, weight: .semibold))
						.foregroundStyle(mine ? .white : ChatDetailView.accent)
						.lineLimit(1)
					Text(quotePreviewText(quoted))
						.font(.system(size: 11))
						.foregroundStyle(mine ? .white.opacity(0.72) : Color(.secondaryLabel))
						.lineLimit(1)
				}
			}
			.padding(.vertical, 5).padding(.horizontal, 8)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(mine ? Color.white.opacity(0.14) : ChatDetailView.accent.opacity(0.08))
			)
		}
		.buttonStyle(.plain)
	}

	private func quotePreviewText(_ m: ChatMessage) -> String {
		if let t = m.text, !t.isEmpty { return t }
		switch m.mediaType {
		case "image":      return "Фото"
		case "video":      return "Видео"
		case "video_note": return "Видеосообщение"
		case "voice":      return "Голосовое"
		case "audio":      return "Аудио"
		default:           return "Файл"
		}
	}

	// MARK: – Read receipt indicator (DM: checkmarks; group: «k/N»)

	@ViewBuilder
	private func readStatusIcon(for m: ChatMessage) -> some View {
		if vm.isGroup {
			let others = vm.chatMembers.filter { $0.userId != vm.currentUserId }
			let total = others.count
			let readCount = others.filter { (vm.readReceipts[$0.userId] ?? 0) >= m.id }.count
			if total == 0 {
				EmptyView()
			} else if readCount == total {
				HStack(spacing: -3) {
					Image(systemName: "checkmark")
					Image(systemName: "checkmark")
				}
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(.white.opacity(0.95))
			} else if readCount > 0 {
				Text("\(readCount)/\(total)")
					.font(.system(size: 9, weight: .semibold, design: .monospaced))
					.foregroundStyle(.white.opacity(0.85))
			} else {
				Image(systemName: "checkmark")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(.white.opacity(0.55))
			}
		} else {
			let isRead = m.id > 0 && m.id <= vm.partnerReadUpToMessageId
			if isRead {
				HStack(spacing: -3) {
					Image(systemName: "checkmark")
					Image(systemName: "checkmark")
				}
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(.white.opacity(0.95))
			} else {
				Image(systemName: "checkmark")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(.white.opacity(0.6))
			}
		}
	}

	// MARK: – Time row

	private func timeRow(_ m: ChatMessage, mine: Bool, pending: Bool) -> some View {
		HStack(spacing: 3) {
			Text(timeStr(m.createdAt))
				.font(.system(size: 10))
				.foregroundStyle(mine ? .white.opacity(0.6) : .secondary)
			if m.editedAt != nil {
				Text("ред.").font(.system(size: 9))
					.foregroundStyle(mine ? .white.opacity(0.45) : .secondary)
			}
			if mine {
				if pending {
					Image(systemName: "clock")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(.white.opacity(0.45))
				} else {
					readStatusIcon(for: m)
				}
			}
		}
	}

	// MARK: – Reactions

	@ViewBuilder
	private func reactionsRow(_ m: ChatMessage) -> some View {
		if let reactions = m.reactions, !reactions.isEmpty {
			HStack(spacing: 4) {
				ForEach(reactions, id: \.emoji) { r in
					let isMine = r.userIds?.contains(vm.currentUserId ?? -1) ?? false
					Button { Task { await vm.toggleReaction(r.emoji, on: m) } } label: {
						HStack(spacing: 2) {
							Text(r.emoji).font(.system(size: 13))
							if r.count > 1 {
								Text("\(r.count)").font(.system(size: 10, weight: .semibold))
									.foregroundStyle(isMine ? .white : .primary)
							}
						}
						.padding(.horizontal, 8).padding(.vertical, 4)
						.background(isMine ? AnyShapeStyle(ChatDetailView.accent) : AnyShapeStyle(Color(.secondarySystemBackground)))
						.clipShape(Capsule())
						.overlay(Capsule().stroke(
							isMine ? Color.clear : Color.secondary.opacity(0.18), lineWidth: 0.5))
					}
				}
			}
		}
	}

	// MARK: – Helpers

	private func tailShape(mine: Bool) -> UnevenRoundedRectangle {
		UnevenRoundedRectangle(
			topLeadingRadius: 18,
			bottomLeadingRadius: mine ? 18 : 4,
			bottomTrailingRadius: mine ? 4 : 18,
			topTrailingRadius: 18
		)
	}

	private func senderName(_ m: ChatMessage) -> String {
		if let nick = vm.chatMembers.first(where: { $0.userId == m.userId })?.user.nickname {
			return nick
		}
		if m.userId != vm.currentUserId { return vm.title }
		return "User \(m.userId ?? 0)"
	}

	private func nameColor(userId: Int) -> Color {
		let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
		return palette[abs(userId) % palette.count]
	}

	private func timeStr(_ iso: String?) -> String {
		guard let iso else { return "" }
		if let d = Self.isoFull.date(from: iso) { return Self.timeFmt.string(from: d) }
		if let d = ISO8601DateFormatter().date(from: iso) { return Self.timeFmt.string(from: d) }
		return ""
	}

	// MARK: – Mention-highlighted text

	private func mentionText(_ text: String, mine: Bool) -> some View {
		let words = text.components(separatedBy: " ")
		var attr  = AttributedString()
		for (i, word) in words.enumerated() {
			var chunk = AttributedString(i < words.count - 1 ? word + " " : word)
			if word.hasPrefix("@") {
				chunk.foregroundColor = mine ? .white : ChatDetailView.accent
				chunk.font = .body.bold()
			} else {
				chunk.foregroundColor = mine ? .white : .primary
				chunk.font = .body
			}
			attr += chunk
		}
		return Text(attr)
	}
}
