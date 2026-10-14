import AVFoundation
import Foundation
import Testing
@testable import MeetingAssistant

/// The audio file part of the recorder, fed with a generated tone (no microphone, no permissions).
struct AACFileWriterTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Writes `seconds` of a 440 Hz tone in 0.1 s buffers, faster than real time.
    private func writeTone(_ writer: AACFileWriter, seconds: Int) throws {
        let framesPerBuffer: AVAudioFrameCount = 4_800
        var offset = 0
        for _ in 0..<(seconds * 10) {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer))
            buffer.frameLength = framesPerBuffer
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(framesPerBuffer) {
                samples[index] = 0.3 * sin(2 * .pi * 440 * Float(offset + index) / 48_000)
            }
            offset += Int(framesPerBuffer)
            // The encoder works in the background; wait when its queue is full.
            var attempts = 0
            while !writer.isReady && attempts < 2_000 {
                Thread.sleep(forTimeInterval: 0.001)
                attempts += 1
            }
            #expect(writer.append(buffer))
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).m4a")
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func writesPlayableAAC() async throws {
        let url = temporaryURL()
        let writer = try AACFileWriter(url: url, inputFormat: format, bitRate: 32_000, realTime: false)
        try writeTone(writer, seconds: 2)
        await writer.finish()

        #expect(abs(try await duration(of: url) - 2.0) < 0.1)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(description.mediaSubType == .mpeg4AAC)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func interruptedFileStaysReadable() async throws {
        let url = temporaryURL()
        let writer = try AACFileWriter(url: url, inputFormat: format, bitRate: 32_000, realTime: false)
        try writeTone(writer, seconds: 25)
        try await Task.sleep(for: .seconds(1))  // let the writer flush its fragments

        // Copy the file while it is still being written, as if the app had crashed now.
        let snapshot = temporaryURL()
        try FileManager.default.copyItem(at: url, to: snapshot)
        #expect(try await duration(of: snapshot) >= 10)

        await writer.finish()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: snapshot)
    }
}
