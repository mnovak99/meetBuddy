import AppKit
import SwiftUI

/// Obecné: name, Obsidian vault, start at login and the macOS permissions.
struct GeneralSettingsTab: View {
    let model: AppModel

    @State private var loginProblem: String?

    var body: some View {
        SettingsPane(model: model) {
            Section {
                TextField(
                    "Tvoje jméno", text: model.configBinding(\.userName),
                    prompt: Text(AppConfig().effectiveUserName))
            } header: {
                Text("Jméno")
            } footer: {
                SettingsFooter(
                    "Jak ti říkají kolegové. Podle jména Claude pozná tvoje úkoly a zmínky o tobě. "
                        + "Prázdné = křestní jméno z účtu na Macu.")
            }

            Section {
                LabeledContent("Složka vaultu") {
                    HStack(spacing: 8) {
                        Text(vaultPath.isEmpty ? "Nevybrána" : vaultPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Vybrat…") { chooseVault() }
                    }
                }
                if !vaultPath.isEmpty {
                    Button("Zobrazit ve Finderu") { revealVault() }
                        .disabled(!model.environment.vaultExists)
                }
                if vaultPath.isEmpty {
                    SettingsNote(tone: .warning, text: "Bez vaultu poznámky nevzniknou.")
                } else if !model.environment.vaultExists {
                    SettingsNote(tone: .error, text: "Složka neexistuje. Vyber ji znovu.")
                }
            } header: {
                Text("Obsidian")
            } footer: {
                SettingsFooter(
                    "Poznámky z meetingů se zapisují do složky \(model.config.notesFolder)/RRRR/MM uvnitř vaultu.")
            }

            Section {
                Toggle("Spouštět po přihlášení", isOn: loginBinding)
                if model.environment.loginItemStatus == .requiresApproval {
                    HStack {
                        SettingsNote(
                            tone: .warning,
                            text: "Čeká na schválení v Nastavení systému → Obecné → Položky při přihlášení.")
                        Spacer()
                        Button("Otevřít…") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                if let loginProblem {
                    SettingsNote(tone: .error, text: loginProblem)
                }
            } header: {
                Text("Spouštění")
            } footer: {
                SettingsFooter("Appka naběhne hned po přihlášení a hlídá meetingy od začátku práce.")
            }

            Section {
                ForEach(model.permissions.items) { item in
                    PermissionRow(item: item) { model.permissions.resolve(item.kind) }
                }
                if model.permissions.notificationAlertStyle == .banner {
                    NotificationStyleTip(model: model)
                }
            } header: {
                Text("Oprávnění")
            } footer: {
                SettingsFooter(
                    "Bez Nahrávání obrazovky appka nepozná okno Google Meet a nesnímá sdílený obsah. "
                        + "Stav se obnovuje sám, i když ho změníš v Nastavení systému.")
            }
        }
    }

    // MARK: - Vault

    private var vaultPath: String {
        model.config.obsidianVaultPath
    }

    /// NSOpenPanel is AppKit's standard "choose a file or folder" dialog; `runModal` blocks until
    /// the user confirms or cancels.
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Vyber složku Obsidian vaultu"
        panel.prompt = "Vybrat"
        if let vault = model.config.vaultURL {
            panel.directoryURL = vault
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateConfig { $0.obsidianVaultPath = url.path(percentEncoded: false) }
    }

    private func revealVault() {
        guard let vault = model.config.vaultURL else { return }
        // Finder opens with the folder selected, like "Show in Finder" in other apps.
        NSWorkspace.shared.activateFileViewerSelecting([vault])
    }

    // MARK: - Login item

    /// `requiresApproval` counts as on: the user turned it on and macOS still waits for them.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: {
                let status = model.environment.loginItemStatus
                return status == .enabled || status == .requiresApproval
            },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                    loginProblem = nil
                } catch {
                    loginProblem = "Spouštění po přihlášení nejde změnit: \(error.localizedDescription)"
                }
                model.environment.loginItemChanged()
            }
        )
    }
}
