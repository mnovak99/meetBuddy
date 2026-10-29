import AppKit
import SwiftUI

/// The main window: a sidebar with the sections. Opened from the menu bar panel.
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
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.windowSection {
            case .overview: OverviewView(model: model)
            case .recordings: RecordingsView(model: model)
            case .vocabulary: VocabularyView(store: model.vocabulary)
            case .storage: StorageView(model: model)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
    }

    private func badge(for section: WindowSection) -> Int {
        switch section {
        case .vocabulary: model.vocabulary.suggestions.count
        case .overview: model.healthItems.filter(\.isProblem).count
        default: 0
        }
    }
}
