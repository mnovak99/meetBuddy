import AVFAudio
import EventKit
import Foundation
import Observation
import UserNotifications

/// One permission as shown in the UI (dashboard, settings, menu bar panel).
nonisolated struct PermissionItem: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case screenRecording, systemAudio, microphone, notifications, calendar
    }

    enum State: Sendable {
        case granted
        case denied
        /// The system has not asked yet: the app can show the prompt.
        case notDetermined
        /// Cannot be read (system audio); the system asks on first use.
        case unknown
        /// Granted, but takes effect after a restart (screen recording).
        case needsRestart
    }

    var kind: Kind
    var state: State

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .screenRecording: "Nahrávání obrazovky"
        case .systemAudio: "Systémový zvuk"
        case .microphone: "Mikrofon"
        case .notifications: "Notifikace"
        case .calendar: "Kalendář"
        }
    }

    /// Why the app needs it.
    var purpose: String {
        switch kind {
        case .screenRecording: "Názvy oken (poznání Google Meet) a snímky sdílené obrazovky."
        case .systemAudio: "Zvuk meeting aplikace. Systém se zeptá při prvním nahrávání."
        case .microphone: "Tvůj hlas jako samostatná stopa, aby přepis věděl, co jsi řekl ty."
        case .notifications: "Otázka „Nahrávat?“ a zpráva, že je poznámka hotová."
        case .calendar: "Název meetingu a účastníci z Kalendáře."
        }
    }

    var symbolName: String {
        switch kind {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        case .notifications: "bell.badge"
        case .calendar: "calendar"
        }
    }

    var isProblem: Bool {
        switch state {
        case .granted, .unknown: false
        case .denied, .notDetermined, .needsRestart: true
        }
    }
}

/// Current state of every macOS permission the app uses, refreshed on each poll, with the
/// actions the UI offers (ask the system, open System Settings).
@Observable
final class PermissionsMonitor {
    private(set) var screenRecordingGranted = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var notificationAlertStyle: UNAlertStyle = .none
    private(set) var calendarStatus: EKAuthorizationStatus = .notDetermined
    private(set) var microphoneStatus: AVAudioApplication.recordPermission = .undetermined

    @ObservationIgnored private var screenRecordingGrantedAtLaunch = false
    @ObservationIgnored private let notifications: NotificationManager
    @ObservationIgnored private let calendar: CalendarLookup

    init(notifications: NotificationManager, calendar: CalendarLookup) {
        self.notifications = notifications
        self.calendar = calendar
    }

    /// Granted in System Settings, but window titles appear only after a restart.
    var screenRecordingNeedsRestart: Bool {
        screenRecordingGranted && !screenRecordingGrantedAtLaunch
    }

    var items: [PermissionItem] {
        PermissionItem.Kind.allCases.map { PermissionItem(kind: $0, state: state(of: $0)) }
    }

    func state(of kind: PermissionItem.Kind) -> PermissionItem.State {
        switch kind {
        case .screenRecording:
            if screenRecordingNeedsRestart { return .needsRestart }
            return screenRecordingGranted ? .granted : .denied
        case .systemAudio:
            return .unknown
        case .microphone:
            switch microphoneStatus {
            case .granted: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
        case .notifications:
            switch notificationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
        case .calendar:
            switch calendarStatus {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// At launch: read the current state and show the system prompts one after another.
    func start(requestMicrophone: Bool) async {
        screenRecordingGrantedAtLaunch = ScreenRecordingPermission.isGranted
        screenRecordingGranted = screenRecordingGrantedAtLaunch
        if screenRecordingGranted {
            Log.permissions.info("Screen Recording permission: granted")
        } else {
            Log.permissions.notice("Screen Recording permission missing, asking the system")
            ScreenRecordingPermission.request()
        }
        await notifications.requestAuthorization()
        await refresh()
        if calendar.status == .notDetermined {
            await calendar.requestAccess()
        }
        if requestMicrophone && MicrophonePermission.status == .undetermined {
            _ = await requestMicrophoneAccess()
        }
        await refresh()
    }

    /// Called every poll: permissions can change in System Settings while the app runs.
    func refresh() async {
        let granted = ScreenRecordingPermission.isGranted
        if granted != screenRecordingGranted {
            Log.permissions.info("Screen Recording permission changed: \(granted ? "granted" : "missing", privacy: .public)")
            screenRecordingGranted = granted
        }
        let settings = await notifications.currentSettings()
        if settings.status != notificationStatus {
            Log.permissions.info("Notification permission status: \(settings.status.rawValue)")
            notificationStatus = settings.status
        }
        if settings.alertStyle != notificationAlertStyle {
            notificationAlertStyle = settings.alertStyle
        }
        if calendar.status != calendarStatus {
            calendarStatus = calendar.status
        }
        if MicrophonePermission.status != microphoneStatus {
            microphoneStatus = MicrophonePermission.status
        }
    }

    /// Shows the system prompt (first time) or returns the stored answer.
    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        let granted = await MicrophonePermission.request()
        Log.permissions.info("Microphone permission granted: \(granted)")
        microphoneStatus = MicrophonePermission.status
        return granted
    }

    func requestCalendarAccess() async {
        await calendar.requestAccess()
        calendarStatus = calendar.status
    }

    /// The right action for a permission in its current state: ask the system when it has not
    /// been asked yet, otherwise open the matching pane in System Settings.
    func resolve(_ kind: PermissionItem.Kind) {
        switch (kind, state(of: kind)) {
        case (.microphone, .notDetermined):
            Task { await requestMicrophoneAccess() }
        case (.calendar, .notDetermined):
            Task { await requestCalendarAccess() }
        case (.notifications, .notDetermined):
            Task {
                await notifications.requestAuthorization()
                await refresh()
            }
        case (.screenRecording, .needsRestart):
            AppRelauncher.relaunch()
        case (.screenRecording, _):
            ScreenRecordingPermission.request()
            SystemSettingsLink.openScreenRecording()
        case (.microphone, _):
            SystemSettingsLink.openMicrophone()
        case (.calendar, _):
            SystemSettingsLink.openCalendars()
        case (.notifications, _):
            SystemSettingsLink.openNotifications()
        case (.systemAudio, _):
            SystemSettingsLink.openScreenRecording()
        }
    }
}
