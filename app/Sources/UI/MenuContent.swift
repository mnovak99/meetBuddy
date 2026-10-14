import AppKit
import SwiftUI
import UserNotifications

/// The icon in the menu bar. SF Symbols are rendered as monochrome template images there.
struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel(model.statusTitle)
    }
}

/// Content of the menu bar drop-down. With the `.menu` style every Text is a disabled menu item,
/// every Button a clickable item and `Menu` a submenu.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.statusTitle)
        if let detail = model.statusDetail {
            Text(detail)
        }
        sessionActions

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

        Divider()
        Button("Znovu načíst nastavení") { model.reloadConfig() }
        Button("Otevřít složku s daty") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
        Divider()
        Button("Ukončit Meeting Assistant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var sessionActions: some View {
        switch model.state {
        case .detected(let session):
            Button("Nahrávat") { model.record(session.id) }
            Button("Nenahrávat") { model.dontRecord(session.id) }
        case .recording(let session):
            Button("Ukončit nahrávání") { model.stopRecording(session.id) }
            if session.probableEndAt != nil {
                Button("Meeting pokračuje") { model.keepRecording(session.id) }
            }
        case .idle, .declined:
            EmptyView()
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
    }
}

// MARK: - Texts shown in the menu

extension AppModel {
    var menuBarSymbol: String {
        switch state {
        case .idle, .declined: "waveform"
        case .detected: "waveform.badge.exclamationmark"
        case .recording: "record.circle.fill"
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
            "Nahrávám: \(session.source.displayName) (simulace, nic se neukládá)"
        }
    }

    var statusDetail: String? {
        guard let session = state.session else { return nil }
        if case .recording = state, session.probableEndAt != nil {
            return "Meeting asi skončil. Ukončit nahrávání?"
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
}
