import SwiftUI

/// Everything that needs the user's attention but is not the current meeting: config problems,
/// storage, old audio, vocabulary suggestions, the first health problems and the notification tip.
/// Built as a list first, so the panel can leave out the whole block when there is nothing.
struct PanelWarnings: View {
    let model: AppModel

    /// How many health problems get their own banner; the rest is one "Další" line.
    private static let healthLimit = 2

    var body: some View {
        let warnings = self.warnings
        if !warnings.isEmpty {
            VStack(spacing: 8) {
                ForEach(warnings) { warning in
                    Banner(
                        tone: warning.tone, title: warning.title, message: warning.message,
                        actionTitle: warning.actionTitle, action: warning.action)
                }
            }
        }
    }

    private struct Warning: Identifiable {
        var id: String
        var tone: Tone
        var title: String
        var message: String? = nil
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
    }

    private var warnings: [Warning] {
        var items: [Warning] = []
        if let problem = model.configProblem {
            items.append(Warning(
                id: "config", tone: .error, title: "Problém s nastavením", message: problem,
                actionTitle: "Znovu načíst", action: { model.reloadConfig() }))
        }
        if let storage = model.storageWarning {
            items.append(Warning(
                id: "storage", tone: .warning, title: storage,
                actionTitle: "Uvolnit místo…", action: { model.openMainWindow(.storage) }))
        }
        if model.expiredAudioCount > 0 {
            items.append(Warning(
                id: "expired-audio", tone: .neutral,
                title: "Staré audio ke smazání: \(PanelTexts.recordings(model.expiredAudioCount))",
                actionTitle: "Úložiště…", action: { model.openMainWindow(.storage) }))
        }
        let suggestions = model.vocabulary.suggestions.count
        if suggestions > 0 {
            items.append(Warning(
                id: "vocabulary", tone: .info,
                title: "Slovník: \(PanelTexts.suggestions(suggestions)) z přepisů",
                actionTitle: "Slovník…", action: { model.openMainWindow(.vocabulary) }))
        }
        let problems = model.healthItems.filter(\.isProblem)
        for item in problems.prefix(Self.healthLimit) {
            items.append(Warning(
                id: "health-\(item.id)", tone: item.state.tone, title: item.title, message: item.detail,
                actionTitle: item.actionTitle,
                action: item.action.map { action in { model.perform(action) } }))
        }
        if problems.count > Self.healthLimit {
            items.append(Warning(
                id: "health-more", tone: .neutral,
                title: "Další: \(PanelTexts.problems(problems.count - Self.healthLimit))",
                actionTitle: "Přehled…", action: { model.openMainWindow(.overview) }))
        }
        if model.permissions.notificationAlertStyle == .banner, model.permissions.state(of: .notifications) == .granted {
            items.append(Warning(
                id: "notification-style", tone: .info,
                title: "Tip: styl notifikací „Upozornění“ nezmizí, dokud neodpovíš",
                actionTitle: "Nastavení notifikací…", action: { model.permissions.resolve(.notifications) }))
        }
        return items
    }
}
