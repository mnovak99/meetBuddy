import AVFoundation
import CoreMedia

/// Encodes PCM audio buffers to AAC in an .m4a file using AVAssetWriter.
///
/// `movieFragmentInterval` writes the file in 10-second fragments: if the app crashes or the Mac
/// loses power, the file stays playable up to the last fragment (AVAssetWriter.h).
/// Not thread-safe: call it from one serial queue only.
nonisolated final class AACFileWriter {
    enum WriterError: LocalizedError {
        case unsupportedSettings
        case cannotStart(Error?)

        var errorDescription: String? {
            switch self {
            case .unsupportedSettings: "Kodér AAC nepodporuje zvolené nastavení."
            case .cannotStart(let error): "Nejde začít zapisovat audio: \(error?.localizedDescription ?? "neznámá chyba")."
            }
        }
    }

    let inputFormat: AVAudioFormat
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    /// Samples written so far; also the timestamp of the next buffer (gapless timeline).
    private(set) var framesWritten: Int64 = 0

    /// - Parameter realTime: true for live capture; tests feed audio faster than real time.
    init(url: URL, inputFormat: AVAudioFormat, bitRate: Int, realTime: Bool = true) throws {
        self.inputFormat = inputFormat
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        assetWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        // Invalid settings would raise an Objective-C exception (a crash) instead of an error.
        guard assetWriter.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw WriterError.unsupportedSettings
        }
        input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: settings, sourceFormatHint: inputFormat.formatDescription)
        input.expectsMediaDataInRealTime = realTime
        guard assetWriter.canAdd(input) else { throw WriterError.unsupportedSettings }
        assetWriter.add(input)

        guard assetWriter.startWriting() else { throw WriterError.cannotStart(assetWriter.error) }
        assetWriter.startSession(atSourceTime: .zero)
    }

    var isReady: Bool {
        input.isReadyForMoreMediaData
    }

    /// Appends one buffer. Returns false if it had to be dropped (encoder busy or failed).
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0, input.isReadyForMoreMediaData,
              let sampleBuffer = makeSampleBuffer(buffer), input.append(sampleBuffer)
        else { return false }
        framesWritten += Int64(buffer.frameLength)
        return true
    }

    func finish() async {
        input.markAsFinished()
        await assetWriter.finishWriting()
        if assetWriter.status == .failed {
            Log.audio.error("Finishing audio file failed: \(String(describing: self.assetWriter.error), privacy: .public)")
        }
    }

    /// AVAssetWriter takes CMSampleBuffers; this wraps the PCM samples into one, timestamped
    /// by the number of samples written so far.
    private func makeSampleBuffer(_ buffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let timescale = CMTimeScale(inputFormat.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: framesWritten, timescale: timescale),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: inputFormat.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard created == noErr, let sampleBuffer else { return nil }
        // Copies the samples into memory owned by the sample buffer, so the caller's buffer
        // (owned by Core Audio during the callback) can be reused right after.
        let copied = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
        return copied == noErr ? sampleBuffer : nil
    }
}
