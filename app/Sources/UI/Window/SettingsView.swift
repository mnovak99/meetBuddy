import AppKit
import AVFAudio
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// Nastavení: an editable copy of config.json, saved with "Uložit"; login item, permissions and
/// the Hugging Face token take effect immediately.
struct SettingsView: View {
    let model: AppModel

    @State private var draft = AppConfig()
    @State private var microphones: [String] = []
    @State private var loginStatus = LoginItem.status
    @State private var tokenStored = false
    @State private var tokenInput = ""
    @State private var message: String?

    var body: some View {
        Form {
            general
            recording
            detection
            frames
            storage
            permissions
            huggingFace
            advanced
        }
        .formStyle(.grouped)
        .navigationTitle("Nastavení")
        .toolbar {
            ToolbarItem {
                Button("Zahodit změny") { draft = model.config }
                    .disabled(draft == model.config)
            }
            ToolbarItem {
                Button("Uložit") { save() }
                    .keyboardShortcut("s")
                    .disabled(draft == model.config)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .onAppear {
            draft = model.config
            microphones = AudioInputDevices.names()
            loginStatus = LoginItem.status
            tokenStored = HuggingFaceToken.isStored
        }
    }

    // MARK: - Sections

    private var general: some View {
        Section("Obecné") {
            TextField("Tvoje jméno", text: $draft.userName)
                .help("Podle něj Claude pozná tvoje úkoly a zmínky o tobě")
            Toggle("Spouštět po přihlášení", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { setLogin($0) }
            ))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("⚠️ macOS čeká na schválení v Nastavení systému → Obecné → Položky při přihlášení.")
                        .font(.caption)
                    Button("Otevřít…") { LoginItem.openSystemSettings() }
                }
            }
            LabeledContent("Obsidian vault") {
                HStack {
                    Text(draft.obsidianVaultPath.isEmpty ? "nevybrán" : draft.obsidianVaultPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Vybrat…") { chooseVault() }
                }
            }
        }
    }

    private var recording: some View {
        Section("Nahrávání") {
            Picker("Mikrofon (tvůj hlas)", selection: $draft.microphoneName) {
                Text("Nenahrávat").tag("")
                ForEach(microphoneChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            ForEach(MeetingSource.allCases, id: \.self) { source in
                Toggle("Hlídat \(source.displayName)", isOn: Binding(
                    get: { draft.enabledSources.contains(source) },
                    set: { enabled in
                        draft.enabledSources = MeetingSource.allCases.filter {
                            $0 == source ? enabled : draft.enabledSources.contains($0)
                        }
                    }
                ))
            }
            Stepper(value: $draft.minDurationMinutes, in: 0...30, step: 1) {
                Text("Kratší než \(Int(draft.minDurationMinutes)) min nabídnout k zahození")
            }
        }
    }

    private var detection: some View {
        Section("Detekce meetingu") {
            Stepper(value: $draft.detectionConfirmSeconds, in: 0...60, step: 3) {
                Text("Zeptat se po \(Int(draft.detectionConfirmSeconds)) s signálu")
            }
            Stepper(value: $draft.endSilenceMinutes, in: 1...30, step: 1) {
                Text("Pravděpodobný konec po \(Int(draft.endSilenceMinutes)) min bez zvuku")
            }
        }
    }

    private var frames: some View {
        Section("Snímky obrazovky") {
            Stepper(value: $draft.frameIntervalSeconds, in: 1...10, step: 0.5) {
                Text("Kontrolovat každé \(draft.frameIntervalSeconds.formatted()) s")
            }
            Picker("Největší rozměr", selection: $draft.frameMaxDimension) {
                ForEach([1280, 1600, 1920, 2560], id: \.self) { size in
                    Text("\(size) px").tag(size)
                }
            }
            LabeledContent("Citlivost na změnu") {
                HStack {
                    Text("víc snímků").font(.caption)
                    Slider(value: $draft.frameChangeThreshold, in: 0.03...0.3)
                    Text("méně").font(.caption)
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private var storage: some View {
        Section("Úložiště") {
            Stepper(value: $draft.audioRetentionDays, in: 1...90) {
                Text("Audio nabídnout ke smazání po \(draft.audioRetentionDays) dnech")
            }
            Stepper(value: $draft.storageLimitGB, in: 1...200, step: 1) {
                Text("Limit nahrávek \(Int(draft.storageLimitGB)) GB")
            }
        }
    }

    private var permissions: some View {
        Section("Oprávnění") {
            permissionRow(
                "Nahrávání obrazovky (názvy oken, snímky)", granted: model.screenRecordingGranted,
                action: SystemSettingsLink.openScreenRecording)
            LabeledContent("Systémový zvuk (zvuk meeting appky)") {
                Text("ptá se systém při prvním nahrávání").font(.caption).foregroundStyle(.secondary)
            }
            permissionRow(
                "Mikrofon (tvůj hlas)", granted: model.microphoneStatus == .granted,
                action: SystemSettingsLink.openMicrophone)
            permissionRow(
                "Notifikace", granted: model.notificationStatus == .authorized,
                action: SystemSettingsLink.openNotifications)
            permissionRow(
                "Kalendář (název a účastníci)", granted: model.calendarStatus == .fullAccess,
                action: SystemSettingsLink.openCalendars)
        }
    }

    private var huggingFace: some View {
        Section {
            LabeledContent("Token") {
                Text(tokenStored ? "uložen v Klíčence ✓" : "⚠️ chybí").foregroundStyle(.secondary)
            }
            HStack {
                SecureField("Nový token (hf_…)", text: $tokenInput)
                Button("Uložit token") {
                    if HuggingFaceToken.store(tokenInput) {
                        tokenInput = ""
                        tokenStored = true
                        message = "Token uložen do Klíčenky."
                    } else {
                        message = "Token se nepodařilo uložit."
                    }
                }
                .disabled(!tokenInput.hasPrefix("hf_"))
            }
        } header: {
            Text("Hugging Face (rozlišení mluvčích)")
        } footer: {
            Text("Token typu Read; na huggingface.co/pyannote/speaker-diarization-community-1 musí být potvrzené podmínky.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advanced: some View {
        Section("Pokročilé") {
            TextField("Složka pipeline", text: $draft.pipelinePath)
            TextField("Cesta k uv", text: $draft.uvPath)
            Button("Otevřít složku s daty") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
        }
    }

    // MARK: - Helpers

    /// The configured value stays selectable: it may be part of a device name ("Arctis Nova 7"
    /// matches "Arctis Nova 7 Gen 2") or a device that is not connected right now.
    private var microphoneChoices: [String] {
        let current = draft.microphoneName
        if current.isEmpty || microphones.contains(current) {
            return microphones
        }
        return [current] + microphones
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(granted ? "povoleno ✓" : "⚠️ nepovoleno").foregroundStyle(.secondary)
                if !granted {
                    Button("Otevřít Nastavení…", action: action)
                }
            }
        }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            message = "Start po přihlášení nejde změnit: \(error.localizedDescription)"
        }
        loginStatus = LoginItem.status
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Vyber složku Obsidian vaultu"
        if !draft.obsidianVaultPath.isEmpty {
            panel.directoryURL = URL(filePath: (draft.obsidianVaultPath as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            draft.obsidianVaultPath = url.path(percentEncoded: false)
        }
    }

    private func save() {
        do {
            try ConfigStore.write(draft.sanitized(), to: AppPaths.configFile)
            model.reloadConfig()
            draft = model.config
            message = "Nastavení uloženo."
        } catch {
            message = "Nastavení nejde uložit: \(error.localizedDescription)"
        }
    }
}
