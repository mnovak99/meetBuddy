import AVFAudio
import AppKit
import EventKit
import SwiftUI
import UserNotifications

/// The icon in the menu bar. SF Symbols are rendered as monochrome template images there.
struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: MenuBarGhost.image(badge: model.menuBarBadge))
            .accessibilityLabel(model.statusTitle)
    }
}

/// Content of the menu bar drop-down. With the `.menu` style every Text is a disabled menu item,
/// every Button a clickable item and `Menu` a submenu.
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle)
        if let detail = model.statusDetail {
            Text(detail)
        }
        sessionActions
        shortRecordingActions
        processingSection

        if !model.isRecording {
            Divider()
            Menu("Nahrávat ručně") {
                ForEach(MeetingSource.allCases, id: \.self) { source in
                    Button(source.manualRecordingLabel) { model.startManualRecording(source) }
                        .disabled(model.signals[source]?.isRunning != true)
                }
            }
        }

        Divider()
        Menu("Diagnostika detekce") {
            ForEach(MeetingSource.allCases, id: \.self) { source in
                ForEach(model.diagnostics(for: source), id: \.self) { line in
                    Text(line)
                }
                Divider()
            }
        }

        permissionWarnings

        if let problem = model.configProblem {
            Divider()
            Text("⚠️ \(problem)")
        }

        if let warning = model.storageWarning {
            Divider()
            Text("⚠️ \(warning)")
            Button("Uvolnit místo…") { open(.storage) }
        } else if model.expiredAudioCount > 0 {
            Divider()
            Button("Staré audio ke smazání: \(model.expiredAudioCount) nahrávek…") { open(.storage) }
        }
        if !model.vocabulary.suggestions.isEmpty {
            Divider()
            Button("Návrhy do slovníku: \(model.vocabulary.suggestions.count)…") { open(.vocabulary) }
        }

        Divider()
        Button("Otevřít Meeting Buddy…") { open(.vocabulary) }
            .keyboardShortcut(",")
        Button("Znovu načíst nastavení") { model.reloadConfig() }
        Divider()
        Button("Ukončit Meeting Buddy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ section: WindowSection) {
        model.windowSection = section
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }

    @ViewBuilder
    private var sessionActions: some View {
        switch model.state {
        case .detected(let session):
            Button("Nahrávat") { model.record(session.id) }
            Button("Nenahrávat") { model.dontRecord(session.id) }
        case .recording(let session):
            if let recording = model.recording {
                Text(recording.audioStatusText)
                if let microphoneText = recording.microphoneStatusText {
                    Text(microphoneText)
                }
                Text(recording.framesStatusText)
                Divider()
                Button("Ukončit nahrávání") { model.stopRecording(session.id) }
                if session.probableEndAt != nil {
                    Button("Meeting pokračuje") { model.keepRecording(session.id) }
                }
                Menu("Okno pro snímky") {
                    let windows = model.signals[session.source]?.candidateWindows ?? []
                    if windows.isEmpty {
                        Text("Žádné okno s názvem (chybí oprávnění?)")
                    }
                    ForEach(windows, id: \.id) { window in
                        Button(window.menuLabel(selected: window.id == session.windowID)) {
                            model.selectWindow(window)
                        }
                    }
                }
                Button("Otevřít složku nahrávky") { NSWorkspace.shared.open(recording.folder) }
            }
        case .idle, .declined:
            EmptyView()
        }
    }

    @ViewBuilder
    private var shortRecordingActions: some View {
        if let pending = model.pendingShortRecording {
            Divider()
            Text("Krátký záznam: \(pending.meta.source.displayName), \(pending.meta.durationText)")
            Button("Zahodit (do Koše)") { model.discardShortRecording() }
            Button("Ponechat") { model.keepShortRecording() }
        }
    }

    @ViewBuilder
    private var processingSection: some View {
        let pipeline = model.pipeline
        if let current = pipeline.current {
            Divider()
            Text("Zpracovávám: \(pipeline.currentStatus?.message ?? "startuji")")
            Text("   \(current.lastPathComponent)" + (pipeline.queue.isEmpty ? "" : " · ve frontě další: \(pipeline.queue.count)"))
        } else if let status = pipeline.lastStatus, let folder = pipeline.lastFolder {
            Divider()
            switch status.state {
            case .done:
                Text("Poslední poznámka je hotová")
                if let warning = status.error {
                    Text("⚠️ \(warning)")
                }
            case .needsSummary:
                Text("⚠️ Poslední poznámka jen s přepisem (Claude nebyl dostupný)")
            default:
                Text("⚠️ Zpracování selhalo: \(status.error ?? "neznámá chyba")")
                Button("Otevřít log zpracování") {
                    NSWorkspace.shared.open(folder.appending(path: PipelineRunner.logFileName))
                }
            }
            if let notePath = pipeline.lastNotePath {
                Button("Otevřít poznámku") { model.openNote(notePath) }
            }
            if status.state != .done {
                Button("Zkusit znovu") { model.retryLastProcessing() }
            }
        }
    }

    @ViewBuilder
    private var permissionWarnings: some View {
        if !model.screenRecordingGranted {
            Divider()
            Text("⚠️ Chybí oprávnění „Nahrávání obrazovky a systémového zvuku“")
            Text("Bez něj nevidím názvy oken: Google Meet nepoznám, Teams a Discord jen podle zvuku.")
            Button("Otevřít Nastavení systému…") { SystemSettingsLink.openScreenRecording() }
            Button("Restartovat appku (po povolení)") { AppRelauncher.relaunch() }
        } else if model.screenRecordingNeedsRestart {
            Divider()
            Text("Oprávnění k nahrávání obrazovky povoleno, názvy oken uvidím po restartu.")
            Button("Restartovat appku") { AppRelauncher.relaunch() }
        }

        switch model.notificationStatus {
        case .denied:
            Divider()
            Text("⚠️ Notifikace jsou vypnuté, volby najdeš jen tady v menu.")
            Button("Otevřít nastavení notifikací…") { SystemSettingsLink.openNotifications() }
        case .notDetermined:
            Divider()
            Text("Notifikace: čekám na povolení (dialog systému).")
        default:
            if model.notificationAlertStyle == .banner {
                Divider()
                Text("Tip: styl notifikací „Upozornění“ nezmizí, dokud nevybereš Ano / Ne.")
                Button("Otevřít nastavení notifikací…") { SystemSettingsLink.openNotifications() }
            }
        }

        if !model.config.microphoneName.isEmpty && model.microphoneStatus == .denied {
            Divider()
            Text("⚠️ Mikrofon není povolený: nahraje se jen zvuk meetingu, bez tvého hlasu.")
            Button("Otevřít nastavení mikrofonu…") { SystemSettingsLink.openMicrophone() }
        }

        switch model.calendarStatus {
        case .fullAccess:
            EmptyView()
        case .notDetermined:
            Divider()
            Text("Kalendář: čekám na povolení (dialog systému).")
        default:
            Divider()
            Text("⚠️ Bez přístupu ke Kalendáři nebudou nahrávky mít název a účastníky.")
            Button("Otevřít nastavení Kalendáře…") { SystemSettingsLink.openCalendars() }
        }
    }
}

// MARK: - Texts shown in the menu

extension AppModel {
    var menuBarBadge: MenuBarGhost.Badge {
        switch state {
        case .idle, .declined: .none
        case .detected: .alert
        case .recording: .recording
        }
    }

    var statusTitle: String {
        switch state {
        case .idle:
            "Čekám na meeting"
        case .detected(let session):
            "Detekován meeting: \(session.source.displayName)"
        case .declined(let session):
            "Meeting v \(session.source.displayName) se nenahrává"
        case .recording(let session):
            "Nahrávám: \(session.source.displayName) · \(Self.durationText(recording?.elapsedSeconds ?? 0))"
        }
    }

    var statusDetail: String? {
        guard let session = state.session else { return nil }
        if case .recording = state, session.probableEndAt != nil {
            return "Meeting asi skončil. Ukončit nahrávání?"
        }
        if let title = recording?.meta.calendar?.title, !title.isEmpty {
            return "Kalendář: „\(title)“"
        }
        return session.windowTitle.map { "Okno: „\($0)“" }
    }

    /// Lines for the diagnostics submenu: what the detector currently sees for one source.
    func diagnostics(for source: MeetingSource) -> [String] {
        let s = signals[source] ?? SourceSignals()
        let enabled = config.enabledSources.contains(source) ? "" : " (vypnuto v nastavení)"
        var lines = [
            "\(source.displayName)\(enabled)",
            "   běží: \(s.isRunning ? "ano" : "ne") · zvuk: \(s.audioOutputActive ? "ano" : "ne") · meeting: \(s.isMeeting ? "ano" : "ne")",
        ]
        if let window = s.meetingWindow?.title {
            lines.append("   okno: „\(window)“")
        }
        return lines
    }

    /// "0:12:34"
    static func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .hourMinuteSecond))
    }
}

extension RecordingController {
    var audioStatusText: String {
        if let audioError {
            return "⚠️ Zvuk: \(audioError)"
        }
        if silenceSuspected {
            return "⚠️ Zvuk: jen ticho, zkontroluj oprávnění Systémový zvuk"
        }
        return hasAudioSignal ? "Zvuk: nahrává se ✓" : "Zvuk: zatím ticho"
    }

    /// Nil when the microphone is switched off in config.json.
    var microphoneStatusText: String? {
        guard let microphone = meta.microphone else { return nil }
        if let error = microphone.error {
            return "⚠️ Mikrofon: \(error)"
        }
        let device = microphone.device ?? "mikrofon"
        return hasMicSignal ? "Mikrofon: \(device) · mluvíš ✓" : "Mikrofon: \(device) · ticho"
    }

    var framesStatusText: String {
        if meta.window == nil {
            return "Snímky: neznámé okno, vyber ho níže v „Okno pro snímky“"
        }
        if windowUnavailable {
            return "⚠️ Snímky: \(frameCount), okno teď nejde snímat (minimalizované?)"
        }
        return "Snímky: \(frameCount)"
    }
}

extension RecordingMeta {
    var durationText: String {
        let minutes = Int(((durationSeconds ?? 0) / 60).rounded(.up))
        return "\(minutes) min"
    }
}

extension MeetingSource {
    var manualRecordingLabel: String {
        switch self {
        case .teams: "Teams"
        case .meet: "Brave (Google Meet i jiné záložky)"
        case .discord: "Discord"
        }
    }
}

extension WindowInfo {
    func menuLabel(selected: Bool) -> String {
        let title = title ?? "Bez názvu"
        let short = title.count > 60 ? String(title.prefix(57)) + "…" : title
        return selected ? "✓ \(short)" : "    \(short)"
    }
}
