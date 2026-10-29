import SwiftUI

/// Nastavení (⌘,): tabs in the toolbar, as macOS apps have it. There is no Save button: every
/// control writes to config.json right away and the app applies the change immediately.
struct SettingsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(tab)
            }
        }
        .frame(width: 640, height: 620)
        .onAppear {
            model.windowAppeared()
            // Tools, token, vault and login item are checked on disk: refresh them once per opening.
            model.environment.refresh(config: model.config)
        }
        .onDisappear { model.windowDisappeared() }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(model: model)
        case .detection: DetectionSettingsTab(model: model)
        case .recording: RecordingSettingsTab(model: model)
        case .notifications: NotificationsSettingsTab(model: model)
        case .ai: AISettingsTab(model: model)
        case .storage: StorageSettingsTab(model: model)
        case .advanced: AdvancedSettingsTab(model: model)
        }
    }
}

#Preview("Nastavení") {
    SettingsWindow(model: AppModel())
}
