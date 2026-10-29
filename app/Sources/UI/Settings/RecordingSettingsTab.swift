import SwiftUI

/// Nahrávání: the microphone track, short recordings and the frames of the meeting window.
struct RecordingSettingsTab: View {
    let model: AppModel

    /// Names of the connected input devices (read once when the tab appears).
    @State private var microphones: [String] = []
    /// The slider edits a local copy and writes to config when the drag ends.
    @State private var changeThreshold = AppConfig().frameChangeThreshold

    private static let frameSizes = [1280, 1600, 1920, 2560]

    var body: some View {
        SettingsPane(model: model) {
            Section {
                Toggle("Nahrávat můj mikrofon", isOn: model.configBinding(\.recordMicrophone))
                Picker("Mikrofon", selection: model.configBinding(\.microphoneName)) {
                    Text("Výchozí vstup systému").tag("")
                    ForEach(microphoneChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!model.config.recordMicrophone)
                if model.config.recordMicrophone, model.permissions.microphoneStatus == .denied {
                    HStack {
                        SettingsNote(tone: .error, text: "Mikrofon není povolený: nahraje se jen zvuk ostatních.")
                        Spacer()
                        Button("Otevřít Nastavení systému…") { model.permissions.resolve(.microphone) }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Mikrofon")
            } footer: {
                SettingsFooter(
                    "Tvůj hlas jde do samostatné stopy mic.m4a, aby přepis věděl, co jsi řekl ty. Při zapnutí "
                        + "si appka vyžádá oprávnění Mikrofon, pokud se systém ještě neptal. Ztlumení řešíš "
                        + "tlačítkem na sluchátkách, appka ho neřeší.")
            }

            Section {
                Stepper(value: model.configBinding(\.minDurationMinutes), in: 0...30, step: 1) {
                    Text("Kratší než \(Int(model.config.minDurationMinutes)) min nabídnout k zahození")
                }
            } header: {
                Text("Krátké záznamy")
            } footer: {
                SettingsFooter(
                    "Po ručním ukončení se krátký záznam nabídne k zahození (Zahodit / Ponechat). Bez odpovědi "
                        + "se ponechá a zpracuje; zahozený jde do Koše. 0 = nenabízet nikdy.")
            }

            Section {
                Stepper(value: model.configBinding(\.frameIntervalSeconds), in: 1...10, step: 0.5) {
                    Text("Kontrolovat každé \(model.config.frameIntervalSeconds.formatted()) s")
                }
                Picker("Největší rozměr", selection: model.configBinding(\.frameMaxDimension)) {
                    ForEach(frameSizeChoices, id: \.self) { size in
                        Text("\(size) px").tag(size)
                    }
                }
                Slider(value: $changeThreshold, in: 0.03...0.3) {
                    Text("Citlivost na změnu")
                } minimumValueLabel: {
                    Text("víc snímků").font(.caption)
                } maximumValueLabel: {
                    Text("méně").font(.caption)
                } onEditingChanged: { editing in
                    if !editing {
                        model.updateConfig { $0.frameChangeThreshold = changeThreshold }
                    }
                }
            } header: {
                Text("Snímky obrazovky")
            } footer: {
                SettingsFooter(
                    "Snímá se jen okno meetingu. Snímek se uloží, až když se obsah výrazně změní a ustálí; "
                        + "zajímá nás sdílený obsah (kód, dashboardy), ne kamery účastníků.")
            }
        }
        .task {
            // Core Audio is asked on the main thread; the list is short and the call is quick.
            microphones = AudioInputDevices.names()
            changeThreshold = model.config.frameChangeThreshold
        }
        .onChange(of: model.config.frameChangeThreshold) { _, value in
            changeThreshold = value
        }
    }

    /// The configured value stays selectable: it may be part of a device name ("Arctis Nova 7"
    /// matches "Arctis Nova 7 Gen 2") or a device that is not connected right now.
    private var microphoneChoices: [String] {
        let current = model.config.microphoneName
        if current.isEmpty || microphones.contains(current) {
            return microphones
        }
        return [current] + microphones
    }

    /// A hand-edited size (say 2000) is kept in the list, otherwise the picker would show nothing.
    private var frameSizeChoices: [Int] {
        let current = model.config.frameMaxDimension
        if Self.frameSizes.contains(current) {
            return Self.frameSizes
        }
        return (Self.frameSizes + [current]).sorted()
    }
}
