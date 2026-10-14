import AppKit
import CoreAudio
import Foundation
import ServiceManagement

/// Start at login (System Settings → General → Login Items), via ServiceManagement.
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// macOS may require the user to approve the item in System Settings first.
    static var needsApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The Hugging Face token for the pyannote model, kept in the login Keychain. The pipeline reads it
/// with the `security` tool, so the app uses the same tool: the Keychain item stays readable for it.
enum HuggingFaceToken {
    static let service = "MeetingAssistant HF token"

    /// True if the token is stored (without reading the secret itself).
    static var isStored: Bool {
        run(["find-generic-password", "-s", service]) == 0
    }

    static func store(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return run(["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-w", trimmed]) == 0
    }

    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// Names of connected microphones, for picking the one recorded into mic.m4a.
enum AudioInputDevices {
    static func names() -> [String] {
        let devices = (try? AudioHardwareSystem.shared.devices) ?? []
        return devices.compactMap { device in
            let hasInput = ((try? device.streams) ?? []).contains { (try? $0.direction) == .input }
            guard hasInput,
                  (try? device.transportType) != kAudioDeviceTransportTypeAggregate,
                  (try? device.isHidden) != true
            else { return nil }
            return try? device.name
        }
        .sorted()
    }
}
