import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MeetingAssistant

/// Plays a quiet 440 Hz tone from this (test) process. `nonisolated`, because the render block
/// runs on Core Audio's real-time thread, not on the main thread.
private nonisolated final class TonePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        // The sample position comes from the timestamp, so the block keeps no state.
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList in
            let start = timestamp.pointee.mSampleTime
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    samples[frame] = 0.2 * Float(sin(2 * Double.pi * 440 * (start + Double(frame)) / 48_000))
                }
            }
            return noErr
        }
        engine.attach(source)
        // Output only: the engine's input node (the microphone) is never touched.
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

/// Integration test on real Core Audio: the test process taps its own tone (muted, so nothing is
/// heard). Verifies the tap, the aggregate device and the AAC file. The microphone is left out on
/// purpose: a test must not record the user's voice.
struct AudioRecorderTests {
    @Test(.timeLimit(.minutes(1)))
    func tapRecordsOwnProcessAudio() async throws {
        let player = TonePlayer()
        try player.start()
        defer { player.stop() }
        try await Task.sleep(for: .milliseconds(500))  // let the process appear in Core Audio

        let url = FileManager.default.temporaryDirectory.appending(path: "tap-\(UUID().uuidString).m4a")
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let recorder = AudioRecorder(
            bundleIDs: [bundleID], appFileURL: url, microphone: nil, bitRate: 32_000, muteBehavior: .muted)
        try recorder.start()
        try await Task.sleep(for: .seconds(3))
        let stats = recorder.currentStats
        await recorder.stop()

        #expect(stats.buffersReceived > 0, "the aggregate device delivered no audio")
        #expect(stats.lastSignalAt != nil, "only silence was recorded")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 2)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Mapping of the aggregate device's input streams to IOProc buffers.
struct AudioStreamLayoutTests {
    private let microphone: UInt32 = 0x6D69_6372  // "micr"

    @Test func microphoneAndTapAsOnThisMac() {
        let layout = AudioStreamLayout(streams: [
            .init(terminalType: microphone, channels: 1, isNonInterleaved: false),
            .init(terminalType: 0, channels: 1, isNonInterleaved: false),
        ])
        #expect(layout.microphoneStreamIndex == 0)
        #expect(layout.tapStreamIndex == 1)
        #expect(layout.bufferIndex(ofStream: 1) == 1)
    }

    @Test func nonInterleavedStereoMicrophoneTakesTwoBuffers() {
        let layout = AudioStreamLayout(streams: [
            .init(terminalType: microphone, channels: 2, isNonInterleaved: true),
            .init(terminalType: 0, channels: 1, isNonInterleaved: false),
        ])
        #expect(layout.bufferIndex(ofStream: layout.tapStreamIndex!) == 2)
    }

    @Test func tapOnly() {
        let layout = AudioStreamLayout(streams: [.init(terminalType: 0, channels: 1, isNonInterleaved: false)])
        #expect(layout.tapStreamIndex == 0)
        #expect(layout.microphoneStreamIndex == nil)
    }
}
