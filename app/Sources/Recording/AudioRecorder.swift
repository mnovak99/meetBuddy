import AVFAudio
import CoreAudio
import Foundation
import os

/// Records two audio tracks of a meeting, sample-aligned:
/// - audio.m4a: the meeting app's output (the other participants), via a Core Audio process tap,
/// - mic.m4a: the user's microphone (a fixed device, `microphoneName` in config.json).
///
/// How it works:
/// 1. A tap (`CATapDescription`) says whose audio to capture: the app's processes, by bundle ID,
///    mixed down to mono. `processRestoreEnabled` (macOS 26) re-attaches processes that restart
///    during the meeting, because Brave and Teams play audio from helper processes.
/// 2. A tap cannot be read directly. It is added to a private aggregate device: a virtual device
///    combining the microphone (also the clock) and the tap as two input streams.
/// 3. One IOProc (a callback) receives both streams in the same buffer list, so both files share
///    one timeline. Each stream is encoded to AAC into its own file.
///
/// The tap only copies the app's output: the user still hears the meeting. Permissions:
/// "Nahrávání systémového zvuku" for the tap (asked on the first start) and "Mikrofon" (asked at
/// app launch). Without the microphone permission or device, only audio.m4a is recorded: a
/// microphone in the aggregate device without permission would stop the whole device.
nonisolated final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case tapNotCreated
        case aggregateDeviceNotCreated
        case tapStreamNotFound
        case unsupportedFormat
        case ioProcNotCreated(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapNotCreated: "Nejde vytvořit odbočku zvuku (Core Audio tap)."
            case .aggregateDeviceNotCreated: "Nejde vytvořit virtuální zvukové zařízení."
            case .tapStreamNotFound: "Ve virtuálním zařízení chybí zvuk meeting aplikace."
            case .unsupportedFormat: "Neznámý formát zvuku."
            case .ioProcNotCreated(let status): "Nejde začít číst zvuk (chyba \(status))."
            }
        }
    }

    /// What should be recorded from the microphone.
    struct MicrophoneRequest: Sendable {
        /// The first input device whose name contains this text; empty = the system's default input.
        var deviceName: String
        var fileURL: URL
        /// Microphone permission granted (checked by the caller on the main thread).
        var isAuthorized: Bool
    }

    struct Stats: Sendable {
        /// Number of IOProc calls (0 = the aggregate device delivers nothing).
        var buffersReceived = 0
        /// Last time the app track contained anything but digital silence.
        var lastSignalAt: Date?
        /// Last time the microphone track contained sound.
        var lastMicSignalAt: Date?
        var droppedBuffers = 0
        var sampleRate: Double?
    }

    let bundleIDs: [String]
    /// Name of the microphone device in use, nil when the microphone is not recorded.
    private(set) var microphoneDeviceName: String?
    /// Why the microphone is not recorded (Czech, for the menu and meta.json).
    private(set) var microphoneProblem: String?

    private let appFileURL: URL
    private let microphone: MicrophoneRequest?
    private let bitRate: Int
    private let muteBehavior: CATapMuteBehavior
    /// IOProc callbacks run on this serial queue; the file writers are only used here.
    private let queue = DispatchQueue(label: "dev.matej.MeetingAssistant.audio", qos: .userInitiated)
    /// Shared between the audio queue (writes) and the main thread (reads).
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    // Set in start() and cleared in stop(), both called from the main thread.
    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var appTrack: Track?
    private var micTrack: Track?

    /// One recorded stream: where it is in the IOProc buffer list and where it is written.
    private struct Track {
        var bufferIndex: Int
        var format: AVAudioFormat
        var writer: AACFileWriter
    }

    /// Peak level below this counts as silence (about −80 dB).
    private static let silenceLevel: Float = 0.0001

    /// - Parameter muteBehavior: `.unmuted` (default) = the user still hears the app.
    ///   Tests use `.muted` so their test tone stays silent.
    init(
        bundleIDs: [String], appFileURL: URL, microphone: MicrophoneRequest?, bitRate: Int,
        muteBehavior: CATapMuteBehavior = .unmuted
    ) {
        self.bundleIDs = bundleIDs
        self.appFileURL = appFileURL
        self.microphone = microphone
        self.bitRate = bitRate
        self.muteBehavior = muteBehavior
    }

    var currentStats: Stats {
        stats.withLock { $0 }
    }

    func start() throws {
        let system = AudioHardwareSystem.shared
        let tap = try makeTap(system)
        self.tap = tap

        // The aggregate device: the tap plus a clock device. With the microphone, the microphone
        // device is the clock; otherwise an output-only device (no microphone involved at all).
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Assistant",
            kAudioAggregateDeviceUIDKey: "dev.matej.MeetingAssistant.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid, kAudioSubTapDriftCompensationKey: true]],
        ]
        let micDevice = try microphoneDevice(system)
        if let clock = try micDevice ?? Self.outputOnlyDevice(system) {
            let clockUID = try clock.uid
            composition[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
            Log.audio.notice("Clock device: \((try? clock.name) ?? clockUID, privacy: .public)")
        }
        guard let device = try system.makeAggregateDevice(description: composition) else {
            throw RecorderError.aggregateDeviceNotCreated
        }
        aggregateDevice = device

        // Which buffer of the IOProc's buffer list carries which stream.
        let inputStreams = try device.streams
            .filter { (try? $0.direction) == .input }
            .sorted { ((try? $0.startingChannel) ?? 0) < ((try? $1.startingChannel) ?? 0) }
        let descriptions = try inputStreams.map { stream in
            let format = try stream.virtualFormat
            return AudioStreamLayout.Stream(
                terminalType: try stream.terminalType,
                channels: Int(format.mChannelsPerFrame),
                isNonInterleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        }
        let layout = AudioStreamLayout(streams: descriptions)
        guard let tapIndex = layout.tapStreamIndex else { throw RecorderError.tapStreamNotFound }

        // Writers. The tap delivers 32-bit float mono, usually at 48 kHz.
        var tapFormatDescription = try tap.format
        guard let tapFormat = AVAudioFormat(streamDescription: &tapFormatDescription) else {
            throw RecorderError.unsupportedFormat
        }
        appTrack = Track(
            bufferIndex: layout.bufferIndex(ofStream: tapIndex), format: tapFormat,
            writer: try AACFileWriter(url: appFileURL, inputFormat: tapFormat, bitRate: bitRate))
        if let microphone, micDevice != nil, let micIndex = layout.microphoneStreamIndex {
            var micFormatDescription = try inputStreams[micIndex].virtualFormat
            if let micFormat = AVAudioFormat(streamDescription: &micFormatDescription) {
                micTrack = Track(
                    bufferIndex: layout.bufferIndex(ofStream: micIndex), format: micFormat,
                    writer: try AACFileWriter(url: microphone.fileURL, inputFormat: micFormat, bitRate: bitRate))
            } else {
                microphoneProblem = "Neznámý formát zvuku z mikrofonu."
                microphoneDeviceName = nil
            }
        }
        stats.withLock { $0.sampleRate = tapFormat.sampleRate }

        // The IOProc: Core Audio calls this block on `queue` for every chunk of audio (~10 ms).
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, queue) { [weak self] _, inputData, _, outputData, _ in
            self?.process(inputData, output: outputData)
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcNotCreated(status) }
        ioProcID = procID
        try device.start(IOProcID: procID)
        Log.audio.notice("Audio recording started, \(tapFormat.sampleRate) Hz, microphone: \(self.micTrack == nil ? "no" : "yes", privacy: .public)")
    }

    /// Stops capturing and finishes the files. Safe to call more than once.
    func stop() async {
        if let device = aggregateDevice, let procID = ioProcID {
            try? device.stop(IOProcID: procID)
            AudioDeviceDestroyIOProcID(device.id, procID)
        }
        if let device = aggregateDevice {
            try? AudioHardwareSystem.shared.destroyAggregateDevice(device)
        }
        if let tap {
            try? AudioHardwareSystem.shared.destroyProcessTap(tap)
        }
        ioProcID = nil
        aggregateDevice = nil
        tap = nil

        // Let callbacks already queued finish, then close the files.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        for (name, track) in [("app", appTrack), ("microphone", micTrack)] {
            guard let track else { continue }
            await track.writer.finish()
            Log.audio.notice("Audio file \(name, privacy: .public) finished, \(track.writer.framesWritten) samples")
        }
        appTrack = nil
        micTrack = nil
    }

    // MARK: - Private

    /// The tap: mono mix of the app's processes. By default they keep playing to the user.
    private func makeTap(_ system: AudioHardwareSystem) throws -> AudioHardwareTap {
        let description = CATapDescription()
        description.name = "Meeting Assistant"
        // Processes running now, by their Core Audio object ID…
        var processIDs: [AudioObjectID] = []
        for process in try system.processes {
            if let bundleID = try? process.bundleID, bundleIDs.contains(bundleID) {
                processIDs.append(process.id)
            }
        }
        description.processes = processIDs
        // …and by bundle ID, so processes started later or restarted are tapped too.
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = true
        description.isMixdown = true
        description.isMono = true
        description.isExclusive = false  // false = tap only the listed processes
        description.isPrivate = true
        description.muteBehavior = muteBehavior
        guard let tap = try system.makeProcessTap(description: description) else {
            throw RecorderError.tapNotCreated
        }
        Log.audio.notice("Tap created for \(self.bundleIDs.joined(separator: ", "), privacy: .public) (\(processIDs.count) running processes)")
        return tap
    }

    /// The configured microphone, or nil (with `microphoneProblem` set) when it cannot be used.
    private func microphoneDevice(_ system: AudioHardwareSystem) throws -> AudioHardwareDevice? {
        guard let microphone else { return nil }
        guard microphone.isAuthorized else {
            microphoneProblem = "Appka nemá povolený mikrofon."
            return nil
        }
        if microphone.deviceName.isEmpty {
            guard let device = try system.defaultInputDevice else {
                microphoneProblem = "Mac nemá žádný mikrofon."
                return nil
            }
            microphoneDeviceName = try? device.name
            return device
        }
        let device = try system.devices.first { device in
            let name = (try? device.name) ?? ""
            let hasInput = ((try? device.streams) ?? []).contains { (try? $0.direction) == .input }
            return hasInput && name.localizedCaseInsensitiveContains(microphone.deviceName)
        }
        guard let device else {
            microphoneProblem = "Mikrofon „\(microphone.deviceName)“ není připojený."
            Log.audio.notice("Microphone \(microphone.deviceName, privacy: .public) not found")
            return nil
        }
        microphoneDeviceName = try? device.name
        return device
    }

    /// A clock device without any input stream, used when the microphone is not recorded.
    /// The default output if it has no microphone, otherwise the built-in speakers or any other.
    private static func outputOnlyDevice(_ system: AudioHardwareSystem) throws -> AudioHardwareDevice? {
        func isOutputOnly(_ device: AudioHardwareDevice) -> Bool {
            guard let streams = try? device.streams else { return false }
            let directions = streams.compactMap { try? $0.direction }
            return directions.contains(.output) && !directions.contains(.input)
        }
        if let output = try system.defaultOutputDevice, isOutputOnly(output) {
            return output
        }
        let candidates = try system.devices.filter { device in
            isOutputOnly(device)
                && (try? device.transportType) != kAudioDeviceTransportTypeAggregate
                && (try? device.isHidden) != true
        }
        return candidates.first { (try? $0.transportType) == kAudioDeviceTransportTypeBuiltIn } ?? candidates.first
    }

    /// Runs on `queue`. The buffer lists belong to Core Audio and are only valid during this call.
    private func process(_ inputData: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        // The clock device's speakers are part of the aggregate device: we play nothing to them.
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let app = appTrack.map { write(buffers, track: $0) }
        let mic = micTrack.map { write(buffers, track: $0) }
        stats.withLock { stats in
            stats.buffersReceived += 1
            if app?.hasSignal == true { stats.lastSignalAt = Date() }
            if mic?.hasSignal == true { stats.lastMicSignalAt = Date() }
            if app?.written == false || mic?.written == false { stats.droppedBuffers += 1 }
        }
    }

    /// Wraps the track's buffer (no copy) and appends it to its file.
    private func write(_ buffers: UnsafeMutableAudioBufferListPointer, track: Track) -> (written: Bool, hasSignal: Bool) {
        guard track.bufferIndex < buffers.count else { return (false, false) }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: buffers[track.bufferIndex])
        return withUnsafePointer(to: &single) { list in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: track.format, bufferListNoCopy: list, deallocator: nil) else {
                return (false, false)
            }
            return (track.writer.append(pcm), Self.peakLevel(of: pcm) > Self.silenceLevel)
        }
    }

    /// Loudest sample of the first channel (0 = silence, 1 = full scale).
    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }
}

/// Where the tap and the microphone are among the aggregate device's input streams, and which
/// buffer of the IOProc's buffer list each starts at. Pure logic, tested without audio hardware.
///
/// Verified on this Mac: Arctis + tap → [microphone (terminal "micr"), tap (terminal 0)].
nonisolated struct AudioStreamLayout {
    struct Stream {
        /// What the stream is connected to ("micr" = microphone, …). Taps have none (0).
        var terminalType: UInt32
        var channels: Int
        /// Non-interleaved streams use one buffer per channel, interleaved ones a single buffer.
        var isNonInterleaved: Bool
    }

    var streams: [Stream]

    var tapStreamIndex: Int? {
        streams.firstIndex { $0.terminalType == 0 }
    }

    var microphoneStreamIndex: Int? {
        streams.firstIndex { $0.terminalType != 0 }
    }

    func bufferIndex(ofStream index: Int) -> Int {
        streams.prefix(index).reduce(0) { $0 + ($1.isNonInterleaved ? $1.channels : 1) }
    }
}
