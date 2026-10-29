import SwiftUI

/// AI: transcript languages, the Whisper and Claude models, what goes into the note, how much
/// of the Mac the pipeline may use, and the Hugging Face token for speaker diarization.
struct AISettingsTab: View {
    let model: AppModel

    @State private var tokenInput = ""
    @State private var storingToken = false
    @State private var tokenMessage: (tone: Tone, text: String)?
    /// Minutes to restore when "až když Mac nepoužívám" is switched back on.
    @State private var lastIdleMinutes = 10

    private static let languageNames = [
        "cs": "Čeština", "sk": "Slovenština", "en": "Angličtina", "de": "Němčina", "pl": "Polština",
    ]

    private static let whisperPresets = [
        PresetPicker.Preset(label: "large-v3-turbo (výchozí)", value: ""),
        PresetPicker.Preset(label: "large-v3 (přesnější, pomalejší)", value: "mlx-community/whisper-large-v3-mlx"),
        PresetPicker.Preset(label: "medium", value: "mlx-community/whisper-medium-mlx"),
        PresetPicker.Preset(label: "small (nejrychlejší)", value: "mlx-community/whisper-small-mlx"),
    ]

    private static let claudePresets = [
        PresetPicker.Preset(label: "Výchozí Claude Code", value: ""),
        PresetPicker.Preset(label: "sonnet", value: "sonnet"),
        PresetPicker.Preset(label: "opus", value: "opus"),
        PresetPicker.Preset(label: "haiku", value: "haiku"),
    ]

    private static let termsURL = URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!

    var body: some View {
        SettingsPane(model: model) {
            Section {
                ForEach(AppConfig.supportedLanguages, id: \.self) { code in
                    Toggle(Self.languageNames[code] ?? code, isOn: languageBinding(code))
                        // The last enabled language cannot be switched off: Whisper needs a fallback.
                        .disabled(model.config.transcriptLanguages == [code])
                }
            } header: {
                Text("Jazyky přepisu")
            } footer: {
                SettingsFooter(
                    "Whisper pozná jazyk sám. Úsek, který určí jako nezaškrtnutý jazyk, se přepíše znovu v "
                        + "záložním jazyce, tím je první zaškrtnutý (teď \(fallbackLanguageName)).")
            }

            Section {
                PresetPicker(
                    title: "Model Whisperu", presets: Self.whisperPresets,
                    value: model.configBinding(\.whisperModel),
                    customFieldTitle: "Repozitář modelu", customPrompt: "mlx-community/whisper-…")
                PresetPicker(
                    title: "Model Clauda", presets: Self.claudePresets,
                    value: model.configBinding(\.claudeModel),
                    customFieldTitle: "Alias modelu", customPrompt: "claude-…")
            } header: {
                Text("Modely")
            } footer: {
                SettingsFooter(
                    "Nový model Whisperu se stáhne při prvním použití (jednotky GB). Claude běží přes Claude "
                        + "Code a tvoje předplatné, bez API klíče.")
            }

            Section {
                Toggle("Přepis do poznámky", isOn: model.configBinding(\.noteIncludeTranscript))
                Toggle("Moje úkoly do „Moje úkoly.md“", isOn: model.configBinding(\.appendTasksToList))
                CommitTextField(
                    "Složka poznámek ve vaultu", value: model.configBinding(\.notesFolder), prompt: "Meetings")
            } header: {
                Text("Poznámka")
            } footer: {
                SettingsFooter(
                    "Poznámky se ukládají do \(model.config.notesFolder)/RRRR/MM, seznam úkolů do "
                        + "\(model.config.notesFolder)/Moje úkoly.md.")
            }

            Section {
                Stepper(value: model.configBinding(\.pipelineThreads), in: 1...16) {
                    Text("Vláken CPU pro modely: \(model.config.pipelineThreads)")
                }
                Toggle("Nezpracovávat během nahrávání", isOn: model.configBinding(\.pauseProcessingWhileRecording))
                Toggle("Zpracovat, až když Mac nepoužívám", isOn: idleBinding)
                Stepper(value: idleMinutesBinding, in: 1...120) {
                    Text("bez klávesnice a myši \(idleMinutesBinding.wrappedValue) min")
                }
                .disabled(model.config.idleBeforeProcessingMinutes == 0)
            } header: {
                Text("Výkon")
            } footer: {
                SettingsFooter(
                    "Nech místo pro VS Code a Docker: zpracování běží s nízkou prioritou a poznámka klidně "
                        + "počká na večer nebo na druhý den.")
            }

            Section {
                LabeledContent("Token") {
                    if model.environment.huggingFaceTokenStored {
                        SettingsNote(tone: .success, text: "Uložen v Klíčence")
                    } else {
                        SettingsNote(tone: .warning, text: "Chybí: poznámka vznikne bez jmen mluvčích")
                    }
                }
                HStack {
                    SecureField("Nový token", text: $tokenInput, prompt: Text("hf_…"))
                    Button("Uložit token") { storeToken() }
                        .disabled(!tokenInput.hasPrefix("hf_") || storingToken)
                    if storingToken {
                        ProgressView().controlSize(.small)
                    }
                }
                if let tokenMessage {
                    SettingsNote(tone: tokenMessage.tone, text: tokenMessage.text)
                }
            } header: {
                Text("Hugging Face (rozlišení mluvčích)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFooter(
                        "Token typu Read z huggingface.co. Model pyannote vyžaduje potvrzené podmínky použití:")
                    Link("huggingface.co/pyannote/speaker-diarization-community-1", destination: Self.termsURL)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Languages

    private var fallbackLanguageName: String {
        let code = model.config.transcriptLanguages.first ?? "cs"
        return Self.languageNames[code] ?? code
    }

    /// Keeps the order of `supportedLanguages` and never lets the list become empty.
    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { model.config.transcriptLanguages.contains(code) },
            set: { enabled in
                let current = model.config.transcriptLanguages
                let updated = AppConfig.supportedLanguages.filter {
                    $0 == code ? enabled : current.contains($0)
                }
                guard !updated.isEmpty else { return }
                model.updateConfig { $0.transcriptLanguages = updated }
            }
        )
    }

    // MARK: - Idle processing

    private var idleBinding: Binding<Bool> {
        Binding(
            get: { model.config.idleBeforeProcessingMinutes > 0 },
            set: { enabled in
                if !enabled, model.config.idleBeforeProcessingMinutes > 0 {
                    lastIdleMinutes = model.config.idleBeforeProcessingMinutes
                }
                let minutes = enabled ? lastIdleMinutes : 0
                model.updateConfig { $0.idleBeforeProcessingMinutes = minutes }
            }
        )
    }

    /// While switched off (0) the stepper shows the minutes that would be used when switched on.
    private var idleMinutesBinding: Binding<Int> {
        Binding(
            get: { model.config.idleBeforeProcessingMinutes > 0 ? model.config.idleBeforeProcessingMinutes : lastIdleMinutes },
            set: { minutes in model.updateConfig { $0.idleBeforeProcessingMinutes = minutes } }
        )
    }

    // MARK: - Token

    /// `HuggingFaceToken.store` runs the `security` tool and waits for it, so it goes to a
    /// background task; the window stays responsive meanwhile.
    private func storeToken() {
        let token = tokenInput
        storingToken = true
        tokenMessage = nil
        Task {
            let stored = await Task.detached(priority: .userInitiated) {
                HuggingFaceToken.store(token)
            }.value
            storingToken = false
            if stored {
                tokenInput = ""
                model.environment.tokenStored()
                tokenMessage = (.success, "Token je uložený v Klíčence.")
            } else {
                tokenMessage = (.error, "Token se nepodařilo uložit do Klíčenky.")
            }
        }
    }
}
