import AVFAudio
import CoreAudio
import Foundation
import os

/// Records the audio output of one meeting app into audio.m4a using a Core Audio process tap.
///
/// How it works:
/// 1. A tap (`CATapDescription`) says whose audio to capture: the app's processes, by bundle ID,
///    mixed down to mono. `processRestoreEnabled` (macOS 26) re-attaches processes that restart
///    during the meeting, because Brave and Teams play audio from helper processes.
/// 2. A tap cannot be read directly. It is added to a private aggregate device, a virtual audio
///    device whose input is the tapped audio. An output-only device (no microphone) is its clock.
/// 3. An IOProc (a callback) receives the audio buffers; they are encoded to AAC.
///
/// The tap only copies the app's output: you still hear the meeting and the microphone is never
/// used. Starting the device for the first time shows the system prompt "Nahrávání systémového
/// zvuku" (Info.plist: NSAudioCaptureUsageDescription). If it is denied, the tap delivers silence.
nonisolated final class AudioTapRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case tapNotCreated
        case aggregateDeviceNotCreated
        case unsupportedFormat
        case ioProcNotCreated(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapNotCreated: "Nejde vytvořit odbočku zvuku (Core Audio tap)."
            case .aggregateDeviceNotCreated: "Nejde vytvořit virtuální zvukové zařízení."
            case .unsupportedFormat: "Neznámý formát zvuku z odbočky."
            case .ioProcNotCreated(let status): "Nejde začít číst zvuk (chyba \(status))."
            }
        }
    }

    struct Stats: Sendable {
        /// Number of audio buffers received from Core Audio (0 = the device delivers nothing).
        var buffersReceived = 0
        /// Last time a buffer contained anything but digital silence.
        var lastSignalAt: Date?
        var droppedBuffers = 0
        var sampleRate: Double?
    }

    let bundleIDs: [String]
    private let fileURL: URL
    private let bitRate: Int
    private let muteBehavior: CATapMuteBehavior
    /// IOProc callbacks run on this serial queue; the file writer is only used here.
    private let queue = DispatchQueue(label: "dev.matej.MeetingAssistant.audio", qos: .userInitiated)
    /// Shared between the audio queue (writes) and the main thread (reads).
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    // Set in start() and cleared in stop(), both called from the main thread.
    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AACFileWriter?

    /// Peak level below this counts as silence (about −80 dB).
    private static let silenceLevel: Float = 0.0001

    /// - Parameter muteBehavior: `.unmuted` (default) = the user still hears the app.
    ///   Tests use `.muted` so their test tone stays silent.
    init(bundleIDs: [String], fileURL: URL, bitRate: Int, muteBehavior: CATapMuteBehavior = .unmuted) {
        self.bundleIDs = bundleIDs
        self.fileURL = fileURL
        self.bitRate = bitRate
        self.muteBehavior = muteBehavior
    }

    var currentStats: Stats {
        stats.withLock { $0 }
    }

    func start() throws {
        let system = AudioHardwareSystem.shared

        // 1. The tap: mono mix of the app's processes; they keep playing to the speakers (unmuted).
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
        self.tap = tap
        Log.audio.notice("Tap created for \(self.bundleIDs.joined(separator: ", "), privacy: .public) (\(processIDs.count) running processes)")

        // 2. Private aggregate device with the tap as its input and an output-only device as its clock.
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Assistant",
            kAudioAggregateDeviceUIDKey: "dev.matej.MeetingAssistant.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let clock = try Self.clockDevice(system) {
            let clockUID = try clock.uid
            composition[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockUID]]
            Log.audio.notice("Clock device: \((try? clock.name) ?? clockUID, privacy: .public)")
        } else {
            Log.audio.notice("No output-only device found, aggregate device with the tap only")
        }
        guard let device = try system.makeAggregateDevice(description: composition) else {
            throw RecorderError.aggregateDeviceNotCreated
        }
        aggregateDevice = device

        // 3. The file writer, in the tap's format (32-bit float, mono, usually 48 kHz).
        var streamFormat = try tap.format
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else {
            throw RecorderError.unsupportedFormat
        }
        writer = try AACFileWriter(url: fileURL, inputFormat: format, bitRate: bitRate)
        stats.withLock { $0.sampleRate = format.sampleRate }

        // 4. The IOProc: Core Audio calls this block on `queue` for every chunk of audio (~10 ms).
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, queue) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData, format: format)
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcNotCreated(status) }
        ioProcID = procID
        try device.start(IOProcID: procID)
        Log.audio.notice("Audio recording started, \(format.sampleRate) Hz")
    }

    /// The aggregate device needs a clock device. A device with an input stream (e.g. a headset
    /// with a microphone) would make macOS check microphone access for the whole aggregate device,
    /// and this app must never use the microphone; the request is refused and no audio arrives.
    /// So the clock is an output-only device: the default output if it has no microphone,
    /// otherwise the built-in speakers or any other output-only device.
    private static func clockDevice(_ system: AudioHardwareSystem) throws -> AudioHardwareDevice? {
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

    /// Stops capturing and finishes the file. Safe to call more than once.
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

        // Let callbacks already queued finish, then close the file.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        if let writer {
            await writer.finish()
            Log.audio.notice("Audio file finished, \(writer.framesWritten) samples")
        }
        writer = nil
    }

    /// Runs on `queue`. The buffer list belongs to Core Audio and is only valid during this call.
    private func process(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let writer,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
        else { return }
        let hasSignal = Self.peakLevel(of: buffer) > Self.silenceLevel
        let written = writer.append(buffer)
        stats.withLock { stats in
            stats.buffersReceived += 1
            if hasSignal { stats.lastSignalAt = Date() }
            if !written { stats.droppedBuffers += 1 }
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
