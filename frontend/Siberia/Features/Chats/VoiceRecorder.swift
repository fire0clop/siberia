import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {

	@Published var isRecording  = false
	@Published var isPlaying    = false
	@Published var isPreviewing = false

	@Published var recordingDuration: TimeInterval = 0
	@Published var playbackProgress:  Double       = 0
	@Published var recordedURL: URL?

	/// Rolling window of normalised meter values shown as live bars during recording
	@Published var meterLevels: [Float] = []
	/// Resampled bars used for the preview waveform after recording stops
	@Published var previewBars: [Float] = []
	/// mediaId of the chat message currently being played (nil = preview playback)
	@Published var currentlyPlayingMediaId: String? = nil

	private var recorder: AVAudioRecorder?
	private var player:   AVPlayer?
	private var timeObserver: Any?
	private var durationTimer: Timer?

	private var meterHistory: [Float] = []
	private let liveDisplayCount = 50
	private let previewBarCount  = 40

	var durationSec: Int { Int(recordingDuration) }

	// MARK: – Recording

	func startRecording() {
		let session = AVAudioSession.sharedInstance()
		try? session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
		try? session.setActive(true)

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("voice_\(Int(Date().timeIntervalSince1970)).m4a")

		let settings: [String: Any] = [
			AVFormatIDKey:              Int(kAudioFormatMPEG4AAC),
			AVSampleRateKey:            44_100,
			AVNumberOfChannelsKey:      1,
			AVEncoderAudioQualityKey:   AVAudioQuality.high.rawValue
		]

		recorder = try? AVAudioRecorder(url: url, settings: settings)
		recorder?.isMeteringEnabled = true
		recorder?.record()

		recordedURL       = url
		isRecording       = true
		isPreviewing      = false
		recordingDuration = 0
		meterHistory      = []
		meterLevels       = []

		durationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.recordingDuration += 0.05
				self.recorder?.updateMeters()
				let power = self.recorder?.averagePower(forChannel: 0) ?? -60
				let level = max(0.06, min(1, (power + 60) / 60))
				self.meterHistory.append(level)
				let start = max(0, self.meterHistory.count - self.liveDisplayCount)
				self.meterLevels = Array(self.meterHistory[start...])
			}
		}
	}

	func stopRecording() {
		recorder?.stop()
		durationTimer?.invalidate(); durationTimer = nil
		isRecording = false
		previewBars = resample(meterHistory, to: previewBarCount)
		isPreviewing = true
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}

	func cancelRecording() {
		recorder?.stop()
		durationTimer?.invalidate(); durationTimer = nil
		if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
		recordedURL       = nil
		isRecording       = false
		isPreviewing      = false
		recordingDuration = 0
		meterHistory      = []
		meterLevels       = []
		previewBars       = []
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}

	func dismissPreview() {
		stopPlaying()
		if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
		recordedURL       = nil
		isPreviewing      = false
		previewBars       = []
		recordingDuration = 0
		meterHistory      = []
		meterLevels       = []
	}

	// MARK: – Playback (AVPlayer handles both local files and remote HTTPS URLs)

	/// mediaId = nil for preview playback; pass the message's mediaId for chat message playback
	func play(url: URL? = nil, mediaId: String? = nil) {
		let target = url ?? recordedURL
		guard let target else { return }
		stopPlaying()

		let session = AVAudioSession.sharedInstance()
		try? session.setCategory(.playback)
		try? session.setActive(true)

		let item = AVPlayerItem(url: target)
		let p = AVPlayer(playerItem: item)
		player = p

		let interval = CMTimeMake(value: 1, timescale: 20) // every ~50 ms
		timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
			MainActor.assumeIsolated {
				guard let self, let item = self.player?.currentItem else { return }
				let dur = item.duration.seconds
				guard dur.isFinite && dur > 0 else { return }
				self.playbackProgress = time.seconds / dur
			}
		}

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(playerItemDidReachEnd),
			name: .AVPlayerItemDidPlayToEndTime,
			object: item
		)

		p.play()
		isPlaying            = true
		playbackProgress     = 0
		currentlyPlayingMediaId = mediaId
	}

	func stopPlaying() {
		if let obs = timeObserver {
			player?.removeTimeObserver(obs)
			timeObserver = nil
		}
		NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
		player?.pause()
		player               = nil
		isPlaying            = false
		playbackProgress     = 0
		currentlyPlayingMediaId = nil
	}

	func reset() {
		stopPlaying()
		if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
		recordedURL       = nil
		recordingDuration = 0
		meterHistory      = []
		meterLevels       = []
		previewBars       = []
		isPreviewing      = false
	}

	@objc nonisolated private func playerItemDidReachEnd() {
		Task { @MainActor in
			self.isPlaying            = false
			self.playbackProgress     = 0
			self.currentlyPlayingMediaId = nil
			if let obs = self.timeObserver {
				self.player?.removeTimeObserver(obs)
				self.timeObserver = nil
			}
			self.player = nil
		}
	}

	// MARK: – Helpers

	static func format(_ seconds: TimeInterval) -> String {
		let s = Int(seconds)
		return String(format: "%d:%02d", s / 60, s % 60)
	}

	private func resample(_ input: [Float], to count: Int) -> [Float] {
		guard !input.isEmpty else { return Array(repeating: 0.2, count: count) }
		if input.count == count { return input }
		return (0..<count).map { i in
			let pos = Double(i) * Double(input.count - 1) / Double(max(1, count - 1))
			let lo  = Int(pos); let hi = min(lo + 1, input.count - 1)
			let t   = Float(pos - Double(lo))
			return input[lo] * (1 - t) + input[hi] * t
		}
	}
}
