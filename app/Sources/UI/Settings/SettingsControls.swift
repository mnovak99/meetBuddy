import AppKit
import SwiftUI

// MARK: - Bindings into config.json

extension AppModel {
    /// A SwiftUI binding for one config key. Reading gives the current value; writing goes
    /// through `updateConfig`, so the change lands in config.json at once and is applied
    /// immediately (the Settings window has no Save button, as macOS apps have it).
    func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.updateConfig { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Frame of a tab

/// What every tab is made of: the config problem banner (when config.json could not be read or
/// written) above a grouped form.
struct SettingsPane<Content: View>: View {
    let model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.configProblem {
                Banner(
                    tone: .error, title: "Problém s nastavením", message: problem,
                    actionTitle: "Znovu načíst", action: { model.reloadConfig() })
                .padding([.horizontal, .top], Theme.padding)
            }
            Form(content: content)
                .formStyle(.grouped)
        }
    }
}

/// Explanation under a section, in plain words.
struct SettingsFooter: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A short note inside a section (state, warning, hint) with a symbol in the tone's colour.
struct SettingsNote: View {
    var tone: Tone
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tone.symbolName)
                .foregroundStyle(tone.color)
            Text(text)
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(.callout)
    }
}

// MARK: - Text fields

/// A text field that writes its value when the user presses Return or leaves the field, not on
/// every keystroke. Keys with sanitising rules ("empty = default", "/" replaced) would otherwise
/// fight the typing: the user clears the field and the default jumps right back in.
struct CommitTextField: View {
    var title: String
    @Binding var value: String
    var prompt: String?

    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ title: String, value: Binding<String>, prompt: String? = nil) {
        self.title = title
        _value = value
        self.prompt = prompt
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if !focused { text = newValue }
            }
    }

    private func commit() {
        guard text != value else { return }
        value = text
        // Show what was really stored (sanitising may have changed it).
        text = value
    }
}

/// A picker with named presets and a "Vlastní…" entry that reveals a text field for any other
/// value (a browser bundle ID, a Hugging Face model repo, a Claude model alias).
struct PresetPicker: View {
    struct Preset: Identifiable {
        var label: String
        var value: String

        var id: String { value }
    }

    var title: String
    var presets: [Preset]
    @Binding var value: String
    var customLabel = "Vlastní…"
    var customFieldTitle = "Vlastní hodnota"
    var customPrompt: String? = nil

    /// The user picked "Vlastní…" but has not typed a value yet (the config keeps the preset).
    @State private var customChosen = false

    private static let customTag = "\u{0}custom"

    private var isPreset: Bool {
        presets.contains { $0.value == value }
    }

    private var showsCustomField: Bool {
        customChosen || !isPreset
    }

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(presets) { preset in
                Text(preset.label).tag(preset.value)
            }
            Divider()
            Text(customLabel).tag(Self.customTag)
        }
        if showsCustomField {
            CommitTextField(customFieldTitle, value: $value, prompt: customPrompt)
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { showsCustomField ? Self.customTag : value },
            set: { tag in
                if tag == Self.customTag {
                    customChosen = true
                } else {
                    customChosen = false
                    value = tag
                }
            }
        )
    }
}

// MARK: - Permissions

/// One permission with its state and the button that fixes it (Obecné and Notifikace).
struct PermissionRow: View {
    var item: PermissionItem
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(symbolName: item.symbolName, tone: tone, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium))
                Text(item.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(item.state.settingsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150, alignment: .trailing)
            if let title = item.state.settingsActionTitle {
                Button(title, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var tone: Tone {
        switch item.state {
        case .granted: .success
        case .unknown: .neutral
        case .notDetermined, .needsRestart: .warning
        case .denied: .error
        }
    }
}

extension PermissionItem.State {
    /// The state as the Settings window and the diagnostics export word it.
    var settingsText: String {
        switch self {
        case .granted: "Povoleno"
        case .denied: "Nepovoleno"
        case .notDetermined: "Zatím nepovoleno"
        case .unknown: "Ptá se systém při prvním nahrávání"
        case .needsRestart: "Povoleno, projeví se po restartu"
        }
    }

    /// The button that moves the state forward, or nil when there is nothing to do.
    var settingsActionTitle: String? {
        switch self {
        case .granted, .unknown: nil
        case .notDetermined: "Povolit…"
        case .denied: "Otevřít Nastavení systému…"
        case .needsRestart: "Restartovat appku"
        }
    }
}

/// Shown when macOS shows the app's notifications as banners that disappear by themselves.
struct NotificationStyleTip: View {
    let model: AppModel

    var body: some View {
        Banner(
            tone: .info, title: "Notifikace mizí samy",
            message: "Styl Bannery nenechá otázku „Nahrávat?“ na obrazovce. V Nastavení systému → "
                + "Notifikace → Meeting Buddy přepni styl na Upozornění.",
            actionTitle: "Otevřít…", action: { model.permissions.resolve(.notifications) })
    }
}

// MARK: - Czech plurals

/// "1 nahrávka", "3 nahrávky", "7 nahrávek": Czech counts need three forms.
nonisolated func czechCount(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    switch count {
    case 1: "1 \(one)"
    case 2...4: "\(count) \(few)"
    default: "\(count) \(many)"
    }
}
