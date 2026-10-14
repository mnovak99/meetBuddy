import CoreAudio

/// Reads Core Audio "process objects" (macOS 14.4+): one object for every process that is connected
/// to the audio system, with flags telling whether it currently runs output or input streams.
///
/// Reading these properties needs no permission and touches no audio data (that comes in step 2
/// with a process tap). Reference: CoreAudio/AudioHardware.h, `kAudioHardwarePropertyProcessObjectList`
/// and the `kAudioProcessProperty…` selectors.
///
/// Core Audio is a C API: every value is read with `AudioObjectGetPropertyData`, which takes an
/// "address" (selector + scope + element) and a pointer to memory it fills in.
nonisolated enum CoreAudioProcesses {
    static func current() -> [AudioProcessInfo] {
        processObjectIDs().compactMap { objectID in
            guard
                let pid = readPID(objectID),
                let bundleID = readBundleID(objectID)
            else { return nil }
            return AudioProcessInfo(
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: readUInt32(objectID, kAudioProcessPropertyIsRunningOutput) == 1,
                isRunningInput: readUInt32(objectID, kAudioProcessPropertyIsRunningInput) == 1
            )
        }
    }

    /// IDs of all process objects. C API pattern: ask for the data size first, then fetch the data.
    private static func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        // The list can shrink between the two calls; `size` now holds the real byte count.
        return Array(ids.prefix(Int(size) / stride))
    }

    private static func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = globalAddress(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && value > 0 ? value : nil
    }

    /// The bundle ID comes back as a CFString that we own (+1 retain count, see the header),
    /// hence `takeRetainedValue()`. Processes without a bundle return an empty string.
    private static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        let bundleID = cfString as String
        return bundleID.isEmpty ? nil : bundleID
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
