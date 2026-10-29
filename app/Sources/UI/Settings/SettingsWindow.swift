import SwiftUI

/// Nastavení: tabs in the toolbar, every change is saved to config.json right away.
/// Placeholder: the tabs are filled in separately.
struct SettingsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                Form {
                    Text("Sekce \(tab.title) se připravuje.")
                }
                .formStyle(.grouped)
                .tabItem { Label(tab.title, systemImage: tab.icon) }
                .tag(tab)
            }
        }
        .frame(width: 620)
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
    }
}
