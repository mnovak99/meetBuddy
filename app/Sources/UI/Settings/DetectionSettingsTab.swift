import SwiftUI

/// Detekce: which apps are watched, the Meet browser, timing of the question and of the
/// "probably ended" guess, and the optional automatic stop.
struct DetectionSettingsTab: View {
    let model: AppModel

    /// Minutes to restore when "Automaticky ukončit" is switched back on.
    @State private var lastAutoStopMinutes = 10

    private static let browserPresets = MeetBrowser.allCases.map {
        PresetPicker.Preset(label: $0.displayName, value: $0.bundleID)
    }

    var body: some View {
        SettingsPane(model: model) {
            Section {
                ForEach(MeetingSource.allCases, id: \.self) { source in
                    Toggle(model.sourceName(source), isOn: sourceBinding(source))
                }
            } header: {
                Text("Hlídané aplikace")
            } footer: {
                SettingsFooter(
                    "Meeting se pozná podle běžící appky, titulku okna a zvuku. Po detekci se appka vždy "
                        + "zeptá, sama nikdy nenahrává.")
            }

            Section {
                PresetPicker(
                    title: "Prohlížeč pro Google Meet", presets: Self.browserPresets,
                    value: model.configBinding(\.meetBrowserBundleID),
                    customLabel: "Jiný…", customFieldTitle: "Bundle ID prohlížeče",
                    customPrompt: "com.example.Browser")
            } header: {
                Text("Google Meet")
            } footer: {
                SettingsFooter(
                    "Jen prohlížeče na Chromiu. Safari a Firefox detekovat nejde: zvuk hrají procesy s jiným "
                        + "bundle ID. Nahrává se zvuk celého prohlížeče, tedy i ostatních záložek.")
            }

            Section {
                Stepper(value: model.configBinding(\.detectionConfirmSeconds), in: 0...60, step: 3) {
                    Text("Zeptat se po \(Int(model.config.detectionConfirmSeconds)) s signálu")
                }
                Stepper(value: model.configBinding(\.endSilenceMinutes), in: 1...30, step: 1) {
                    Text("Pravděpodobný konec po \(Int(model.config.endSilenceMinutes)) min bez hlavního signálu")
                }
                Stepper(value: model.configBinding(\.endGraceSeconds), in: 10...300, step: 5) {
                    Text("Konec bez jakéhokoli signálu po \(Int(model.config.endGraceSeconds)) s")
                }
                Stepper(value: model.configBinding(\.pollIntervalSeconds), in: 1...30, step: 1) {
                    Text("Kontrolovat každé \(Int(model.config.pollIntervalSeconds)) s")
                }
            } header: {
                Text("Načasování")
            } footer: {
                SettingsFooter(
                    "Hlavní signál je u Teams a Discordu zvuk, u Google Meet okno s meetingem. Delší čekání "
                        + "před otázkou odfiltruje krátké zvuky notifikací.")
            }

            Section {
                Toggle("Automaticky ukončit nahrávání", isOn: autoStopBinding)
                Stepper(value: autoStopMinutesBinding, in: 1...120) {
                    Text("když po pravděpodobném konci nikdo neodpoví \(autoStopMinutesBinding.wrappedValue) min")
                }
                .disabled(model.config.autoStopMinutes == 0)
            } header: {
                Text("Automatické ukončení")
            } footer: {
                SettingsFooter(
                    "Výchozí je vypnuto: po pravděpodobném konci se appka zeptá a nahrává dál, dokud "
                        + "nerozhodneš ty. Se zapnutím se nahrávání ukončí samo, když otázku přehlédneš.")
            }
        }
    }

    // MARK: - Bindings

    /// Keeps the order of `MeetingSource.allCases`, so config.json stays tidy.
    private func sourceBinding(_ source: MeetingSource) -> Binding<Bool> {
        Binding(
            get: { model.config.enabledSources.contains(source) },
            set: { enabled in
                let current = model.config.enabledSources
                model.updateConfig {
                    $0.enabledSources = MeetingSource.allCases.filter {
                        $0 == source ? enabled : current.contains($0)
                    }
                }
            }
        )
    }

    private var autoStopBinding: Binding<Bool> {
        Binding(
            get: { model.config.autoStopMinutes > 0 },
            set: { enabled in
                if !enabled, model.config.autoStopMinutes > 0 {
                    lastAutoStopMinutes = model.config.autoStopMinutes
                }
                let minutes = enabled ? lastAutoStopMinutes : 0
                model.updateConfig { $0.autoStopMinutes = minutes }
            }
        )
    }

    /// While switched off (0) the stepper shows the minutes that would be used when switched on.
    private var autoStopMinutesBinding: Binding<Int> {
        Binding(
            get: { model.config.autoStopMinutes > 0 ? model.config.autoStopMinutes : lastAutoStopMinutes },
            set: { minutes in model.updateConfig { $0.autoStopMinutes = minutes } }
        )
    }
}
