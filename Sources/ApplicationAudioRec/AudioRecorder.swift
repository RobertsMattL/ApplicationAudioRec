import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AudioToolbox

/// A running application that can be chosen as the capture source.
struct AppInfo: Equatable {
    let bundleID: String
    let name: String
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// Captures a single application's audio via ScreenCaptureKit and pipes the raw
/// PCM into `ffmpeg`, which encodes it to MP3 in real time.
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var ffmpeg: Process?
    private var ffmpegInput: FileHandle?
    private let audioQueue = DispatchQueue(label: "com.matthewroberts.applicationaudiorec.audio")

    /// Read from the main thread to drive the UI; written under `audioQueue`.
    private(set) var isRecording = false

    /// Output format requested from ScreenCaptureKit and handed to ffmpeg.
    private let sampleRate = 48_000
    private let channelCount = 2

    /// Invoked (on an arbitrary thread) if the system tears the stream down.
    var onError: ((String) -> Void)?

    // MARK: - ffmpeg discovery

    /// A Finder-launched .app does not inherit the shell PATH, so probe the
    /// usual install locations directly rather than relying on `which`.
    static func ffmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Source discovery

    func fetchApps() async throws -> [AppInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        var apps: [AppInfo] = []
        for app in content.applications {
            let id = app.bundleIdentifier
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let name = app.applicationName.isEmpty ? id : app.applicationName
            apps.append(AppInfo(bundleID: id, name: name))
        }
        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Recording lifecycle

    func start(bundleID: String, bitrateKbps: Int, outputURL: URL) async throws {
        guard let ffmpegPath = Self.ffmpegPath() else {
            throw RecorderError.message(
                "ffmpeg was not found. Install it with:\n\n    brew install ffmpeg")
        }

        // Resolve the capture target first; these are the throwing steps that
        // happen before any external process is spawned.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecorderError.message("No display is available to attach the capture to.")
        }
        let targets = content.applications.filter { $0.bundleIdentifier == bundleID }
        guard !targets.isEmpty else {
            throw RecorderError.message(
                "That app isn't currently running. Launch it (and start playback), then try again.")
        }

        let filter = SCContentFilter(display: display, including: targets, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        config.excludesCurrentProcessAudio = true
        // We never consume the video, but a valid video config is still
        // required. Keep it tiny and slow to minimise overhead.
        config.width = 128
        config.height = 128
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        // Launch the encoder: raw little-endian Float32 PCM in, MP3 out.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-f", "f32le",
            "-ar", String(sampleRate),
            "-ac", String(channelCount),
            "-i", "pipe:0",
            "-c:a", "libmp3lame",
            "-b:a", "\(bitrateKbps)k",
            "-y", outputURL.path,
        ]
        let inPipe = Pipe()
        proc.standardInput = inPipe
        try proc.run()
        self.ffmpeg = proc
        self.ffmpegInput = inPipe.fileHandleForWriting

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.stream = stream
            audioQueue.sync { self.isRecording = true }
        } catch {
            // Stream failed to start — don't leave ffmpeg blocked on its pipe.
            try? ffmpegInput?.close()
            ffmpegInput = nil
            proc.terminate()
            ffmpeg = nil
            throw error
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Serialise teardown against the audio callback, then flush ffmpeg by
        // closing its stdin and waiting for it to finish writing the file.
        audioQueue.sync {
            self.isRecording = false
            try? self.ffmpegInput?.close()
            self.ffmpegInput = nil
        }
        ffmpeg?.waitUntilExit()
        ffmpeg = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, isRecording, let input = ffmpegInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let data = Self.interleavedFloatData(from: sampleBuffer),
              !data.isEmpty else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            // Broken pipe means ffmpeg exited; surface it and stop.
            onError?("The encoder stopped unexpectedly.")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    // MARK: - Sample-buffer conversion

    /// Flattens a CoreMedia audio buffer into interleaved little-endian Float32
    /// bytes, handling both interleaved and planar (per-channel) layouts.
    static func interleavedFloatData(from sampleBuffer: CMSampleBuffer) -> Data? {
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr, sizeNeeded > 0 else { return nil }

        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(ablPtr)

        // Single buffer => already interleaved (or mono): pass the bytes through.
        if list.count == 1 {
            let buf = list[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return nil }
            return Data(bytes: data, count: Int(buf.mDataByteSize))
        }

        // Multiple buffers => planar: weave the per-channel samples together.
        let channels = list.count
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return nil }
        var out = [Float](repeating: 0, count: frames * channels)
        for ch in 0..<channels {
            guard let p = list[ch].mData else { continue }
            let src = p.bindMemory(to: Float.self, capacity: frames)
            for i in 0..<frames {
                out[i * channels + ch] = src[i]
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
