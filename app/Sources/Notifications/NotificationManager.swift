import Foundation
import UserNotifications

/// Posts the "Nahrávat?" and "Meeting skončil?" notifications and reports the user's choice.
///
/// How actions work in UserNotifications: buttons are defined once as a `UNNotificationCategory`
/// with `UNNotificationAction`s; each notification names its category. When the user clicks a
/// button, the system calls the delegate with the action's identifier.
final class NotificationManager: NSObject {
    enum Choice: Sendable {
        case record, dontRecord, stop, keepRecording, discardShortRecording, keepShortRecording
    }

    /// Called on the main thread when the user picks an action in one of our notifications.
    var onChoice: ((Choice, UUID) -> Void)?
    /// Called when the user clicks a "note ready" notification (absolute path of the note).
    var onOpenNote: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    /// Identifiers shared by the categories, actions and the delegate callback.
    nonisolated private enum ID {
        static let detectedCategory = "MEETING_DETECTED"
        static let endedCategory = "MEETING_ENDED"
        static let record = "RECORD"
        static let dontRecord = "DONT_RECORD"
        static let stop = "STOP"
        static let keep = "KEEP"
        static let shortCategory = "SHORT_RECORDING"
        static let discard = "DISCARD"
        static let keepShort = "KEEP_SHORT"
        static let sessionKey = "sessionID"
        static let notePathKey = "notePath"
    }

    /// Call early at launch: the delegate must be set before the app finishes launching,
    /// otherwise clicks on notifications can be lost (UNUserNotificationCenter.h).
    func configure() {
        center.delegate = self
        let detected = UNNotificationCategory(
            identifier: ID.detectedCategory,
            actions: [
                UNNotificationAction(identifier: ID.record, title: "Ano"),
                UNNotificationAction(identifier: ID.dontRecord, title: "Ne", options: [.destructive]),
            ],
            intentIdentifiers: [],
            // Also report "dismissed" (closed without a choice) to the delegate, for the log.
            options: [.customDismissAction]
        )
        let ended = UNNotificationCategory(
            identifier: ID.endedCategory,
            actions: [
                UNNotificationAction(identifier: ID.stop, title: "Ukončit", options: [.destructive]),
                UNNotificationAction(identifier: ID.keep, title: "Pokračovat"),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let short = UNNotificationCategory(
            identifier: ID.shortCategory,
            actions: [
                UNNotificationAction(identifier: ID.discard, title: "Zahodit", options: [.destructive]),
                UNNotificationAction(identifier: ID.keepShort, title: "Ponechat"),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([detected, ended, short])
    }

    /// Shows the system permission prompt on first launch; later it just returns the stored answer.
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.notifications.info("Notification permission granted: \(granted)")
        } catch {
            Log.notifications.error("Notification permission request failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Current permission and presentation style (banner disappears, alert stays until clicked).
    func currentSettings() async -> (status: UNAuthorizationStatus, alertStyle: UNAlertStyle) {
        let settings = await center.notificationSettings()
        return (settings.authorizationStatus, settings.alertStyle)
    }

    func postMeetingDetected(_ session: MeetingSession) {
        let content = UNMutableNotificationContent()
        content.title = "Detekován meeting v \(session.source.displayName) – nahrávat?"
        content.body = session.windowTitle.map { "Okno: \($0)" } ?? "Název okna není k dispozici."
        content.sound = .default
        content.categoryIdentifier = ID.detectedCategory
        content.userInfo = [ID.sessionKey: session.id.uuidString]
        post(content, identifier: Self.detectedIdentifier(session.id))
    }

    func postMeetingProbablyEnded(_ session: MeetingSession, reason: EndReason, endSilenceMinutes: Double) {
        let name = session.source.displayName
        let content = UNMutableNotificationContent()
        content.title = "Meeting v \(name) pravděpodobně skončil"
        let minutes = endSilenceMinutes.formatted()
        let why = switch reason {
        case .appQuit: "\(name) byl ukončen."
        case .signalsGone: "Okno meetingu je zavřené a \(name) nehraje zvuk."
        case .primaryGone: session.source == .meet
            ? "Okno Google Meet už \(minutes) min není vidět."
            : "\(name) už \(minutes) min nehraje zvuk."
        }
        content.body = "\(why) Ukončit nahrávání?"
        content.sound = .default
        content.categoryIdentifier = ID.endedCategory
        content.userInfo = [ID.sessionKey: session.id.uuidString]
        post(content, identifier: Self.endedIdentifier(session.id))
    }

    /// A finished recording is shorter than `minDurationMinutes`: offer to discard it.
    func postShortRecording(_ meta: RecordingMeta) {
        let minutes = Int(((meta.durationSeconds ?? 0) / 60).rounded(.up))
        let content = UNMutableNotificationContent()
        content.title = "Záznam z \(meta.source.displayName) má jen \(minutes) min – zahodit?"
        content.body = "Zahozený záznam se přesune do Koše. Bez odpovědi zůstane uložený."
        content.sound = .default
        content.categoryIdentifier = ID.shortCategory
        content.userInfo = [ID.sessionKey: meta.id.uuidString]
        post(content, identifier: "short-\(meta.id.uuidString)")
    }

    /// Plain information without buttons (window not capturable, silent audio, errors).
    func postInfo(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        post(content, identifier: identifier)
    }

    /// The pipeline finished a recording: note ready, note without summary, or failure.
    func postPipelineFinished(folderName: String, status: PipelineStatus?, notePath: String?) {
        let content = UNMutableNotificationContent()
        let noteName = notePath.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
        switch status?.state {
        case .done:
            content.title = "Poznámka je hotová"
            content.body = "\(noteName ?? folderName) – kliknutím ji otevřeš v Obsidianu."
            if let warning = status?.error {
                content.body += " ⚠️ \(warning)"
            }
        case .needsSummary:
            content.title = "Poznámka zatím jen s přepisem"
            content.body = "Claude nebyl dostupný. Shrnutí doplním při příštím spuštění appky "
                + "nebo po „Zkusit znovu“ v menu."
        default:
            content.title = "Zpracování nahrávky selhalo"
            content.body = status?.error ?? "Neznámá chyba, podrobnosti v pipeline.log."
        }
        content.sound = .default
        if let notePath {
            content.userInfo = [ID.notePathKey: notePath]
        }
        post(content, identifier: "pipeline-\(folderName)")
    }

    /// Removes notifications of a meeting that is over, so nobody answers a stale question.
    func removeNotifications(for sessionID: UUID) {
        let ids = [Self.detectedIdentifier(sessionID), Self.endedIdentifier(sessionID), "short-\(sessionID.uuidString)"]
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Private

    private static func detectedIdentifier(_ id: UUID) -> String { "detected-\(id.uuidString)" }
    private static func endedIdentifier(_ id: UUID) -> String { "ended-\(id.uuidString)" }

    private func post(_ content: UNMutableNotificationContent, identifier: String) {
        // trigger nil = deliver immediately.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
                Log.notifications.info("Posted notification \(identifier, privacy: .public)")
            } catch {
                Log.notifications.error("Cannot post notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handle(actionIdentifier: String, sessionIDString: String?, notePath: String?) {
        if let notePath, actionIdentifier == UNNotificationDefaultActionIdentifier {
            onOpenNote?(notePath)
            return
        }
        guard let sessionIDString, let sessionID = UUID(uuidString: sessionIDString) else { return }
        let choice: Choice
        switch actionIdentifier {
        case ID.record: choice = .record
        case ID.dontRecord: choice = .dontRecord
        case ID.stop: choice = .stop
        case ID.keep: choice = .keepRecording
        case ID.discard: choice = .discardShortRecording
        case ID.keepShort: choice = .keepShortRecording
        case UNNotificationDismissActionIdentifier:
            Log.notifications.info("Notification dismissed without a choice")
            return
        default:
            // UNNotificationDefaultActionIdentifier: the user clicked the notification body.
            Log.notifications.info("Notification clicked without choosing an action")
            return
        }
        onChoice?(choice, sessionID)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// The user clicked a button, the notification itself, or dismissed it.
    /// The framework may call this on a background thread, hence `nonisolated` and the explicit
    /// hop to the main actor (MainActor.run) before touching app state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo[ID.sessionKey] as? String
        let notePath = userInfo[ID.notePathKey] as? String
        await MainActor.run {
            self.handle(actionIdentifier: action, sessionIDString: sessionID, notePath: notePath)
        }
    }

    /// Without this, notifications are not shown while the app counts as "in the foreground".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
