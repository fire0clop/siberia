import SwiftUI

// MARK: – Compose bar (text input + voice recording + attach menu)

struct ComposeBarView: View {
	@ObservedObject var vm: ChatDetailViewModel
	@ObservedObject var voice: VoiceRecorder

	// Bindings for states owned by ChatDetailView
	@Binding var showAttachMenu: Bool
	@Binding var showPhotoVideoPicker: Bool
	@Binding var showFilePicker: Bool
	@Binding var showScheduleSheet: Bool

	// Callback invoked when the user wants to send a scheduled message
	// (long-press on send) — the caller shows the schedule sheet.
	// Actual send happens in ChatDetailView via the sheet.

	// MARK: – Internal recording state

	enum VoiceInputMode { case voice, circle }
	@State private var voiceInputMode: VoiceInputMode = .voice
	@State private var recordingLocked  = false
	@State private var micDragOffset:   CGSize = .zero
	@State private var pressStartTime:  Date?  = nil
	@State private var recordingTimer:  Timer? = nil

	var body: some View {
		VStack(spacing: 0) {
			if vm.isUploadingMedia {
				UploadProgressBar().transition(.opacity)
			} else {
				Divider().opacity(0.5).transition(.opacity)
			}
			inputMainRow
				.padding(.horizontal, 12).padding(.vertical, 8)
				.background(Color(.systemBackground))
		}
		.animation(.easeInOut(duration: 0.2), value: vm.isUploadingMedia)
	}

	// MARK: – Main input row

	private var inputMainRow: some View {
		HStack(alignment: .bottom, spacing: 10) {
			leftInputButton
				.animation(.spring(response: 0.25), value: voice.isRecording)
				.animation(.spring(response: 0.25), value: voice.isPreviewing)

			Group {
				if voice.isRecording {
					recordingCenter
				} else if voice.isPreviewing {
					previewCenter
				} else {
					textFieldInput
				}
			}
			.animation(.easeInOut(duration: 0.12), value: voice.isRecording)
			.animation(.easeInOut(duration: 0.12), value: voice.isPreviewing)

			rightInputButton
				.animation(.spring(response: 0.2, dampingFraction: 0.72), value: voice.isRecording)
				.animation(.spring(response: 0.2, dampingFraction: 0.72), value: voice.isPreviewing)
		}
	}

	// MARK: – Left button

	@ViewBuilder
	private var leftInputButton: some View {
		if voice.isRecording {
			Button {
				voice.cancelRecording(); recordingLocked = false
			} label: {
				Image(systemName: recordingLocked ? "trash" : "xmark")
					.font(.system(size: recordingLocked ? 17 : 14, weight: .semibold))
					.foregroundStyle(.red)
					.frame(width: 28, height: 34)
			}
		} else if voice.isPreviewing {
			Button { voice.dismissPreview() } label: {
				Image(systemName: "trash").font(.system(size: 17))
					.foregroundStyle(.red).frame(width: 28, height: 34)
			}
		} else {
			Button {
				withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { showAttachMenu.toggle() }
			} label: {
				Image(systemName: showAttachMenu ? "xmark.circle.fill" : "plus.circle.fill")
					.font(.system(size: 28))
					.foregroundStyle(showAttachMenu ? Color.secondary : ChatDetailView.accent)
					.animation(.spring(response: 0.2), value: showAttachMenu)
			}
			.disabled(vm.isUploadingMedia)
		}
	}

	// MARK: – Center content

	private var textFieldInput: some View {
		TextField("Сообщение…", text: $vm.draft, axis: .vertical)
			.textFieldStyle(.plain).lineLimit(1...5)
			.padding(.horizontal, 12).padding(.vertical, 8)
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 20))
			.onChange(of: vm.draft) { _, _ in vm.onDraftChange() }
	}

	private var recordingCenter: some View {
		HStack(spacing: 8) {
			HStack(spacing: 4) {
				BlinkingDot()
				Text(VoiceRecorder.format(voice.recordingDuration))
					.font(.system(size: 13, weight: .medium).monospacedDigit())
					.foregroundStyle(.red)
			}
			ScrollViewReader { proxy in
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(alignment: .center, spacing: 2) {
						ForEach(Array(voice.meterLevels.enumerated()), id: \.offset) { idx, level in
							Capsule()
								.fill(Color.red.opacity(0.75))
								.frame(width: 2.5, height: max(4, CGFloat(level) * 30 + 4))
								.id(idx)
						}
					}
					.padding(.horizontal, 4)
				}
				.onChange(of: voice.meterLevels.count) { _, count in
					guard count > 0 else { return }
					withAnimation(.linear(duration: 0.06)) { proxy.scrollTo(count - 1, anchor: .trailing) }
				}
			}
			if !recordingLocked {
				Text("↑ зафикс.")
					.font(.system(size: 11))
					.foregroundStyle(.secondary.opacity(0.7))
			}
		}
		.frame(maxWidth: .infinity)
		.frame(height: 36)
		.padding(.horizontal, 10)
		.background(Color(.secondarySystemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 18))
	}

	private var previewCenter: some View {
		let isPreviewPlaying = voice.isPlaying && voice.currentlyPlayingMediaId == nil
		return HStack(spacing: 8) {
			Button {
				if isPreviewPlaying { voice.stopPlaying() } else { voice.play() }
			} label: {
				ZStack {
					Circle().fill(ChatDetailView.accent.opacity(0.12)).frame(width: 30, height: 30)
					Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
						.font(.system(size: 12, weight: .bold)).foregroundStyle(ChatDetailView.accent)
						.offset(x: isPreviewPlaying ? 0 : 1)
				}
			}
			VoiceWaveformView(
				bars: voice.previewBars,
				progress: isPreviewPlaying ? voice.playbackProgress : 0,
				tint: ChatDetailView.accent,
				background: ChatDetailView.accent.opacity(0.22)
			)
			.frame(maxWidth: .infinity)
			.animation(.linear(duration: 0.05), value: voice.playbackProgress)
			Text(VoiceRecorder.format(voice.recordingDuration))
				.font(.system(size: 12, weight: .medium).monospacedDigit())
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.frame(height: 36)
		.padding(.horizontal, 10)
		.background(Color(.secondarySystemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 18))
	}

	// MARK: – Right button

	@ViewBuilder
	private var rightInputButton: some View {
		if voice.isPreviewing {
			Button {
				guard let url = voice.recordedURL else { return }
				let dur = voice.durationSec
				let bars = voice.previewBars
				voice.isPreviewing = false
				Task { await vm.sendVoice(url: url, durationSec: dur, waveformBars: bars); voice.reset() }
			} label: { sendCircle }
		} else if voice.isRecording && recordingLocked {
			Button {
				voice.stopRecording(); recordingLocked = false
			} label: {
				ZStack {
					Circle().fill(Color.red).frame(width: 34, height: 34)
					RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
				}
			}
		} else {
			let canSend = !vm.draft.trimmingCharacters(in: .whitespaces).isEmpty && !voice.isRecording
			ZStack {
				Button {
					guard canSend else { return }
					Task { await vm.send() }
					UIImpactFeedbackGenerator(style: .medium).impactOccurred()
				} label: { sendCircle }
				.simultaneousGesture(
					LongPressGesture(minimumDuration: 0.5).onEnded { _ in
						guard canSend else { return }
						UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
						showScheduleSheet = true
					}
				)
				.opacity(canSend ? 1 : 0)
				.scaleEffect(canSend ? 1 : 0.4)
				.allowsHitTesting(canSend)

				micButton
					.opacity(canSend ? 0 : 1)
					.scaleEffect(canSend ? 0.4 : 1)
					.allowsHitTesting(!canSend)
			}
			.animation(.spring(response: 0.2, dampingFraction: 0.72), value: canSend)
		}
	}

	private var micButton: some View {
		ZStack {
			Circle()
				.fill(voice.isRecording ? Color.red : ChatDetailView.accent)
				.frame(width: 34, height: 34)
			Image(systemName: voice.isRecording ? "mic.fill" :
				  (voiceInputMode == .voice ? "mic.fill" : "circle.fill"))
				.font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
				.scaleEffect(voice.isRecording ? 1.1 : 1)
		}
		.frame(width: 34, height: 34)
		.offset(y: max(-28, min(0, micDragOffset.height / 3)))
		.overlay(alignment: .top) {
			if voice.isRecording && !recordingLocked {
				VStack(spacing: 2) {
					Image(systemName: "lock.fill").font(.system(size: 10))
					Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
				}
				.foregroundStyle(abs(micDragOffset.height) > 25 ? ChatDetailView.accent : Color.secondary.opacity(0.6))
				.offset(y: -34)
			}
		}
		.gesture(voiceButtonGesture)
	}

	private var sendCircle: some View {
		ZStack {
			Circle().fill(ChatDetailView.accent).frame(width: 34, height: 34)
			Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
		}
	}

	// MARK: – Voice button gesture

	// DragGesture(minimumDistance:0) — tap vs hold:
	//   • finger-up in < 0.3 s  → toggle voice/circle mode
	//   • Timer fires at 0.3 s  → start recording
	private var voiceButtonGesture: some Gesture {
		DragGesture(minimumDistance: 0, coordinateSpace: .global)
			.onChanged { value in
				if pressStartTime == nil {
					pressStartTime = Date()
					// Circle mode is reserved for future video notes — recording disabled for now
					if voiceInputMode == .voice {
						let voiceRef = voice
						recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
							Task { @MainActor in
								guard !voiceRef.isRecording && !voiceRef.isPreviewing else { return }
								voiceRef.startRecording()
								UIImpactFeedbackGenerator(style: .medium).impactOccurred()
							}
						}
					}
				}

				guard voice.isRecording && !recordingLocked else { return }
				micDragOffset = value.translation

				if value.translation.width < -70 {
					voice.cancelRecording(); recordingLocked = false
					micDragOffset = .zero; pressStartTime = nil
					recordingTimer?.invalidate(); recordingTimer = nil
				} else if value.translation.height < -70 {
					recordingLocked = true; micDragOffset = .zero
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				}
			}
			.onEnded { _ in
				let held = pressStartTime.map { Date().timeIntervalSince($0) } ?? 0
				pressStartTime = nil
				micDragOffset  = .zero
				recordingTimer?.invalidate(); recordingTimer = nil

				if held < 0.3 && !voice.isRecording {
					voiceInputMode = voiceInputMode == .voice ? .circle : .voice
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				} else if voice.isRecording && !recordingLocked {
					voice.stopRecording()
				}
			}
	}

}

// MARK: – Attach menu card (standalone so ChatDetailView can use it in an overlay)

struct AttachMenuCard: View {
	@Binding var showAttachMenu: Bool
	@Binding var showPhotoVideoPicker: Bool
	@Binding var showFilePicker: Bool

	var body: some View {
		HStack(spacing: 12) {
			attachBtn(icon: "photo.stack.fill", color: ChatDetailView.accent, label: "Фото/Видео") {
				showAttachMenu = false; showPhotoVideoPicker = true
			}
			attachBtn(icon: "doc.fill", color: .orange, label: "Файл") {
				showAttachMenu = false; showFilePicker = true
			}
		}
		.padding(12)
		.background(Color(.systemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 18))
		.shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 4)
	}

	private func attachBtn(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 6) {
				ZStack {
					RoundedRectangle(cornerRadius: 14).fill(color).frame(width: 54, height: 54)
					Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.white)
				}
				Text(label).font(.caption2.weight(.medium)).foregroundStyle(.primary)
			}
		}
		.buttonStyle(.plain)
	}
}
