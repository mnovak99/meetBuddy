import SwiftUI

/// Přehled: the dashboard (state, checklist, queue). Placeholder: designed separately.
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Card {
                    Text(model.statusTitle).font(.headline)
                    if let detail = model.statusDetail {
                        Text(detail).foregroundStyle(.secondary)
                    }
                }
                SectionHeader("Připravenost")
                ForEach(model.healthItems) { item in
                    HealthRow(item: item) { model.perform($0) }
                }
            }
            .padding(Theme.padding)
        }
        .navigationTitle("Přehled")
        .onAppear { model.environment.refresh(config: model.config) }
    }
}
