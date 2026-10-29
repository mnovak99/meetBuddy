import SwiftUI

/// Notifikace: which optional notifications are shown, and the permission that makes them appear.
struct NotificationsSettingsTab: View {
    let model: AppModel

    var body: some View {
        SettingsPane(model: model) {
            Section {
                Toggle("Zvuk notifikací", isOn: model.configBinding(\.notificationSound))
            } header: {
                Text("Zvuk")
            }

            Section {
                Toggle("Meeting pravděpodobně skončil", isOn: model.configBinding(\.notifyMeetingEnded))
                Toggle("Poznámka je hotová", isOn: model.configBinding(\.notifyNoteReady))
                Toggle("Úložiště nad limitem", isOn: model.configBinding(\.notifyStorage))
                Toggle("Problémy při nahrávání", isOn: model.configBinding(\.notifyRecordingProblems))
            } header: {
                Text("Co oznamovat")
            } footer: {
                SettingsFooter(
                    "Otázka „Nahrávat?“ a chyby zpracování se zobrazí vždy. Otázka po pravděpodobném konci "
                        + "zůstává v panelu v menu baru, i když je její notifikace vypnutá.")
            }

            Section {
                if let item = model.permissions.items.first(where: { $0.kind == .notifications }) {
                    PermissionRow(item: item) { model.permissions.resolve(.notifications) }
                }
                if model.permissions.notificationAlertStyle == .banner {
                    NotificationStyleTip(model: model)
                }
                // The row above already offers "Povolit…" / "Otevřít Nastavení systému…" while
                // the permission is missing; once granted, this is the way to the style and sound.
                if model.permissions.state(of: .notifications).settingsActionTitle == nil {
                    Button("Otevřít nastavení notifikací…") { model.permissions.resolve(.notifications) }
                }
            } header: {
                Text("Oprávnění")
            } footer: {
                SettingsFooter(
                    "Styl Upozornění nechá otázku na obrazovce, dokud neodpovíš; Bannery po chvíli zmizí.")
            }
        }
    }
}
