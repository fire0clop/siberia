import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

// MARK: – Media send & cache helpers

extension ChatDetailViewModel {

	// MARK: Send image

	func sendImage(_ imageData: Data, fileName: String) async {
		beginUpload()
		let clientId = UUID()
		let pending = makePendingMessage(text: nil, clientId: clientId, replyTo: nil, mediaId: "pending", mediaType: "image")
		pendingClientIds.insert(clientId.uuidString)
		upsert(pending)

		do {
			let uploaded = try await MediaService.shared.upload(
				data: imageData, fileName: fileName, mimeType: "image/jpeg", type: "image"
			)
			let r = try await ChatService.shared.sendMessage(
				chatId: chatId, text: nil, clientMessageId: clientId,
				mediaId: uploaded.id
			)
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString && $0.id < 0 }
			upsert(r.message.withResolvedChatId(chatId))
		} catch {
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString }
			self.error = error.localizedDescription
		}
		endUpload()
	}

	// MARK: Send voice

	func sendVoice(url: URL, durationSec: Int, waveformBars: [Float] = []) async {
		guard let data = try? Data(contentsOf: url) else { return }
		beginUpload()
		let clientId = UUID()
		let pending = makePendingMessage(text: nil, clientId: clientId, replyTo: nil, mediaId: "pending", mediaType: "voice")
		pendingClientIds.insert(clientId.uuidString)
		upsert(pending)
		scrollToBottomSignal += 1

		do {
			let uploaded = try await MediaService.shared.upload(
				data: data, fileName: "voice.m4a", mimeType: "audio/mp4",
				type: "voice", durationSec: durationSec,
				waveform: waveformBars.isEmpty ? nil : waveformBars
			)
			if !waveformBars.isEmpty { mediaWaveforms[uploaded.id] = waveformBars }
			if durationSec > 0 { mediaDurations[uploaded.id] = durationSec }
			let r = try await ChatService.shared.sendMessage(
				chatId: chatId, text: nil, clientMessageId: clientId,
				mediaId: uploaded.id
			)
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString && $0.id < 0 }
			upsert(r.message.withResolvedChatId(chatId))
		} catch {
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString }
			self.error = error.localizedDescription
		}
		endUpload()
	}

	// MARK: Send multiple picked items

	func sendPickedItems(_ items: [PhotosPickerItem]) async {
		for item in items { await sendPickedItem(item) }
	}

	func sendPickedItem(_ item: PhotosPickerItem) async {
		let videoType = item.supportedContentTypes.first {
			$0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
		}
		let isVideo = videoType != nil

		if isVideo {
			if let url = try? await item.loadTransferable(type: URL.self) {
				await sendVideoCompressed(url: url)
				return
			}
			guard let data = try? await item.loadTransferable(type: Data.self) else {
				self.error = "Не удалось загрузить видео. Попробуйте через «Файл»."
				return
			}
			let ext = videoType?.preferredFilenameExtension ?? "mp4"
			let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick_\(UUID().uuidString).\(ext)")
			try? data.write(to: tmp)
			await sendVideoCompressed(url: tmp)
			try? FileManager.default.removeItem(at: tmp)
		} else {
			guard let data = try? await item.loadTransferable(type: Data.self) else { return }
			guard let uiImage = UIImage(data: data),
			      let jpeg = uiImage.jpegData(compressionQuality: 0.85) else { return }
			await sendImage(jpeg, fileName: "photo.jpg")
		}
	}

	// Compress video to 720p using AVAssetExportSession before uploading.
	func sendVideoCompressed(url: URL) async {
		let asset = AVURLAsset(url: url)
		let preset = AVAssetExportPreset1280x720

		guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4) else {
			if let data = try? Data(contentsOf: url) { await sendVideo(data, fileName: "video.mp4") }
			return
		}

		guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
			if let data = try? Data(contentsOf: url) { await sendVideo(data, fileName: "video.mp4") }
			return
		}

		let outURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("compressed_\(UUID().uuidString).mp4")
		session.outputURL = outURL
		session.outputFileType = .mp4
		session.shouldOptimizeForNetworkUse = true

		await session.export()

		defer { try? FileManager.default.removeItem(at: outURL) }

		if session.status == .completed, let data = try? Data(contentsOf: outURL) {
			Log.media.info("Video compressed: \(data.count / 1024)KB")
			await sendVideo(data, fileName: "video.mp4")
		} else {
			if let data = try? Data(contentsOf: url) { await sendVideo(data, fileName: "video.mp4") }
		}
	}

	// MARK: Send video

	func sendVideo(_ videoData: Data, fileName: String) async {
		beginUpload()
		let clientId = UUID()
		let pending = makePendingMessage(text: nil, clientId: clientId, replyTo: nil, mediaId: "pending", mediaType: "video")
		pendingClientIds.insert(clientId.uuidString)
		upsert(pending)
		do {
			let ext = (fileName as NSString).pathExtension.lowercased()
			let mime = ext == "mov" ? "video/quicktime" : "video/mp4"
			let uploaded = try await MediaService.shared.upload(
				data: videoData, fileName: fileName, mimeType: mime, type: "video"
			)
			if let name = uploaded.originalName { mediaOriginalNames[uploaded.id] = name }
			let r = try await ChatService.shared.sendMessage(
				chatId: chatId, text: nil, clientMessageId: clientId, mediaId: uploaded.id
			)
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString && $0.id < 0 }
			upsert(r.message.withResolvedChatId(chatId))
		} catch {
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString }
			self.error = error.localizedDescription
		}
		endUpload()
	}

	// MARK: Send document / audio

	func sendDocument(data: Data, fileName: String, mimeType: String) async {
		let inferredType = Self.mediaTypeFor(mimeType: mimeType)
		let inferredMediaType: String
		switch inferredType {
		case "image":    await sendImage(data, fileName: fileName); return
		case "video":    await sendVideo(data, fileName: fileName); return
		case "audio":    inferredMediaType = "audio"
		default:         inferredMediaType = "document"
		}

		beginUpload()
		let clientId = UUID()
		let pending = makePendingMessage(
			text: nil, clientId: clientId, replyTo: nil,
			mediaId: "pending", mediaType: inferredMediaType
		)
		pendingClientIds.insert(clientId.uuidString)
		upsert(pending)
		do {
			let uploaded = try await MediaService.shared.upload(
				data: data, fileName: fileName, mimeType: mimeType, type: inferredType
			)
			if let name = uploaded.originalName { mediaOriginalNames[uploaded.id] = name }
			if let mime = uploaded.mimeType     { mediaMimeTypes[uploaded.id]    = mime }
			let r = try await ChatService.shared.sendMessage(
				chatId: chatId, text: nil, clientMessageId: clientId, mediaId: uploaded.id
			)
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString && $0.id < 0 }
			upsert(r.message.withResolvedChatId(chatId))
		} catch {
			pendingClientIds.remove(clientId.uuidString)
			messages.removeAll { $0.clientMessageId == clientId.uuidString }
			self.error = error.localizedDescription
		}
		endUpload()
	}

	/// Map MIME type to backend MediaType string.
	static func mediaTypeFor(mimeType: String) -> String {
		let mime = mimeType.lowercased()
		if mime.hasPrefix("image/") { return "image" }
		if mime.hasPrefix("video/") { return "video" }
		if mime == "audio/ogg" || mime == "audio/mp4" || mime == "audio/m4a"
			|| mime == "audio/aac" || mime == "audio/mpeg" { return "audio" }
		if mime.hasPrefix("audio/") { return "audio" }
		return "document"
	}

	// MARK: Media URL / meta cache

	func loadMediaURL(mediaId: String) async -> String? {
		guard mediaId != "pending" else { return nil }
		if let cached = mediaURLCache[mediaId] { return cached }
		guard let meta = try? await MediaService.shared.getMeta(mediaId: mediaId) else { return nil }
		mediaURLCache[mediaId] = meta.url
		if let thumb = meta.thumbnailUrl { mediaThumbURLCache[mediaId] = thumb }
		if let name  = meta.originalName { mediaOriginalNames[mediaId] = name }
		if let mime  = meta.mimeType     { mediaMimeTypes[mediaId]     = mime }
		if let dur   = meta.durationSec  { mediaDurations[mediaId]     = dur  }
		if let wf = meta.waveform, !wf.isEmpty {
			mediaWaveforms[mediaId] = wf
		}
		return meta.url
	}

	func loadVideoPreview(mediaId: String) async {
		if mediaThumbURLCache[mediaId] != nil || videoThumbnailCache[mediaId] != nil { return }
		guard let urlStr = await loadMediaURL(mediaId: mediaId) else { return }
		if mediaThumbURLCache[mediaId] != nil { return }
		guard let url = URL(string: urlStr) else { return }
		let asset = AVURLAsset(url: url)
		let gen = AVAssetImageGenerator(asset: asset)
		gen.appliesPreferredTrackTransform = true
		gen.maximumSize = CGSize(width: 480, height: 360)
		if let cgImage = try? await gen.image(at: .zero).image {
			videoThumbnailCache[mediaId] = UIImage(cgImage: cgImage)
		}
	}
}
