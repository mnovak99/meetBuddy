import AppKit
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    case vocabulary, overview, settings, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vocabulary: "Slovník"
        case .overview: "Přehled"
        case .settings: "Nastavení"
        case .storage: "Úložiště"
        }
    }

    var icon: String {
        switch self {
        case .vocabulary: "character.book.closed"
        case .overview: "list.bullet.rectangle"
        case .settings: "gearshape"
        case .storage: "internaldrive"
        }
    }
}

/// The app window: a sidebar with the sections. Opened from the menu bar.
struct MainWindow: View {
    static let id = "main"

    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { model.windowSection },
                set: { if let section = $0 { model.windowSection = section } }
            )) {
                ForEach(WindowSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(section == .vocabulary ? model.vocabulary.suggestions.count : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.windowSection {
            case .vocabulary: VocabularyView(store: model.vocabulary)
            case .overview: OverviewView(model: model)
            case .settings: SettingsView(model: model)
            case .storage: StorageView(model: model)
            }
        }
        .frame(minWidth: 940, minHeight: 580)
        // A menu bar app has no Dock icon; while the window is open it gets one (and ⌘Tab).
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
