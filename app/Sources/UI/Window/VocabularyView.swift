import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Slovník: names, abbreviations and terms that speech recognition gets wrong.
struct VocabularyView: View {
    let store: VocabularyStore

    @State private var search = ""
    @State private var categoryFilter: VocabularyTerm.Category?
    @State private var selection = Set<UUID>()
    /// The term in the editor sheet (new, existing or from a suggestion).
    @State private var editing: VocabularyTerm?
    @State private var editingSuggestion: VocabularySuggestion?
    @State private var confirmDelete = false
    @State private var notice: (tone: Tone, text: String)?

    var body: some View {
        let fit = store.promptFit
        VStack(alignment: .leading, spacing: Theme.spacing) {
            header(tokens: fit.tokens)
            if let problem = store.problem {
                Banner(tone: .error, title: "Slovník nejde načíst nebo uložit", message: problem)
            }
            if let notice {
                Banner(tone: notice.tone, title: notice.text, actionTitle: "Zavřít") { self.notice = nil }
            }
            if !store.suggestions.isEmpty {
                suggestionsCard
            }
            table(fitting: fit.fitting)
        }
        .padding(Theme.padding)
        .navigationTitle("Slovník")
        .searchable(text: $search, prompt: "Hledat")
        .toolbar { toolbar }
        .sheet(item: $editing) { term in
            TermEditor(term: term, isNew: !store.terms.contains { $0.id == term.id }) { saved in
                if let suggestion = editingSuggestion {
                    store.accept(suggestion, as: saved)
                } else {
                    store.upsert(saved)
                }
                editingSuggestion = nil
                store.refreshOccurrences()
            } onCancel: {
                editingSuggestion = nil
            }
        }
        .confirmationDialog(
            "Smazat \(selection.count == 1 ? "pojem" : "\(selection.count) pojmy") ze slovníku?",
            isPresented: $confirmDelete
        ) {
            Button("Smazat", role: .destructive) {
                store.delete(selection)
                selection = []
            }
        }
        .onAppear {
            store.load()
            store.refreshOccurrences()
        }
    }

    // MARK: - Header

    private func header(tokens: Int) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text("Jména, zkratky a pojmy, které model nepozná. **Do promptu** = Whisper je dostane předem (jen vzácná slova). **Oprava** = chybné tvary se po přepisu nahradí. **Význam** pomáhá Claudovi s opravami a jmény.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(
                value: Double(min(tokens, VocabularyRules.promptTokenBudget)),
                total: Double(VocabularyRules.promptTokenBudget)
            ) {
                Text("Prompt Whisperu").font(.caption.weight(.medium))
            } currentValueLabel: {
                Text("≈ \(tokens) / \(VocabularyRules.promptTokenBudget) tokenů")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tint(tokens > VocabularyRules.promptTokenBudget ? Theme.warning : .accentColor)
            .frame(width: 220)
            .help("Whisper čte jen posledních 224 tokenů promptu. Pojmy, které se nevejdou, opraví jen Claude.")
        }
    }

    // MARK: - Suggestions

    private var suggestionsCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconCircle(symbolName: "sparkles", tone: .info, size: 26)
                    Text("Návrhy z meetingů").font(.headline)
                    StatusBadge(text: "\(store.suggestions.count)", tone: .info)
                    Spacer()
                }
                Text("Pojmy, které Whisper nepoznal nebo napsal špatně. Přijmi je, uprav, nebo zamítni (zamítnuté se nevrátí).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.suggestions) { suggestion in
                            suggestionRow(suggestion)
                            if suggestion.id != store.suggestions.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                // As tall as the suggestions need, scrolling from four on.
                .frame(height: min(CGFloat(store.suggestions.count) * 48, 180))
            }
        }
    }

    private func suggestionRow(_ suggestion: VocabularySuggestion) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.term).fontWeight(.semibold)
                    Text(suggestion.category.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(suggestionDetail(suggestion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Přijmout") {
                    store.accept(suggestion)
                    store.refreshOccurrences()
                }
                .buttonStyle(.borderedProminent)
                Button("Upravit…") {
                    editingSuggestion = suggestion
                    editing = suggestion.asTerm
                }
                Button("Zamítnout") { store.reject(suggestion) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func suggestionDetail(_ suggestion: VocabularySuggestion) -> String {
        var parts: [String] = []
        if !suggestion.heardAs.isEmpty {
            parts.append("Whisper napsal: \(suggestion.heardAs.joined(separator: ", "))")
        }
        if !suggestion.description.isEmpty {
            parts.append(suggestion.description)
        }
        if !suggestion.source.isEmpty {
            parts.append("z \(suggestion.source)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Table

    private var filteredTerms: [VocabularyTerm] {
        store.terms.filter { term in
            (categoryFilter == nil || term.category == categoryFilter)
                && (search.isEmpty
                    || term.term.localizedCaseInsensitiveContains(search)
                    || term.aliases.contains { $0.localizedCaseInsensitiveContains(search) }
                    || term.description.localizedCaseInsensitiveContains(search))
        }
    }

    private func table(fitting: Set<UUID>) -> some View {
        Table(filteredTerms, selection: $selection) {
            TableColumn("Správně") { term in
                Text(term.term).fontWeight(.medium)
            }
            TableColumn("Typ") { term in
                Text(term.category.label)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Model píše") { term in
                Text(term.aliases.joined(separator: ", ")).foregroundStyle(.secondary)
            }
            TableColumn("Význam") { term in
                Text(term.description).foregroundStyle(.secondary)
            }
            TableColumn("Prompt") { term in
                if term.inPrompt && fitting.contains(term.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.success)
                        .help("V promptu Whisperu")
                } else if term.inPrompt {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .help("Nevejde se do promptu Whisperu: opraví ho jen Claude")
                }
            }
            .width(55)
            TableColumn("Oprava") { term in
                if term.autoReplace {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.success)
                        .help("Chybné tvary se nahradí hned po přepisu")
                }
            }
            .width(55)
            TableColumn("Výskyty") { term in
                Text("\(store.occurrences[term.term.lowercased()] ?? 0)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Kolikrát zazněl v přepisech za posledních \(VocabularyStore.occurrenceDays) dní")
            }
            .width(60)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Upravit…") { edit(ids.first) }
                .disabled(ids.count != 1)
            Button("Smazat…", role: .destructive) {
                selection = ids
                confirmDelete = true
            }
        } primaryAction: { ids in
            edit(ids.first)  // double click
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        .overlay {
            if store.terms.isEmpty {
                ContentUnavailableView(
                    "Slovník je prázdný",
                    systemImage: "character.book.closed",
                    description: Text("Přidej jména kolegů a zákazníků, zkratky a produkty, které Whisper komolí. Návrhy se objeví i samy po meetingech."))
            } else if filteredTerms.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Typ", selection: $categoryFilter) {
                Text("Všechny typy").tag(VocabularyTerm.Category?.none)
                ForEach(VocabularyTerm.Category.allCases) { category in
                    Text(category.label).tag(Optional(category))
                }
            }
        }
        ToolbarItem {
            Button {
                editingSuggestion = nil
                editing = VocabularyTerm(term: "")
            } label: {
                Label("Přidat", systemImage: "plus")
            }
            .help("Přidat pojem")
        }
        ToolbarItem {
            Button {
                confirmDelete = true
            } label: {
                Label("Smazat", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Smazat vybrané pojmy")
        }
        ToolbarItem {
            Menu {
                Button("Importovat CSV…") { importCSV() }
                Button("Exportovat CSV…") { exportCSV() }
            } label: {
                Label("CSV", systemImage: "tablecells")
            }
            .help("Úprava v Numbers nebo Excelu, záloha, sdílení s kolegy")
        }
    }

    // MARK: - Actions

    private func edit(_ id: UUID?) {
        guard let id, let term = store.terms.first(where: { $0.id == id }) else { return }
        editingSuggestion = nil
        editing = term
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Sloupce: Správně;Typ;Model píše;Význam;Do promptu;Automaticky opravovat"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importCSV(from: url)
            notice = (.success, "Import hotový: \(czechCount(count, "pojem", "pojmy", "pojmů")) ze souboru \(url.lastPathComponent).")
            store.refreshOccurrences()
        } catch {
            notice = (.error, "Import se nepovedl: \(error.localizedDescription)")
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "slovnik.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV(to: url)
            notice = (.success, "Slovník uložen do \(url.lastPathComponent).")
        } catch {
            notice = (.error, "Export se nepovedl: \(error.localizedDescription)")
        }
    }
}

/// The editor sheet for one vocabulary entry.
struct TermEditor: View {
    @State var term: VocabularyTerm
    let isNew: Bool
    let onSave: (VocabularyTerm) -> Void
    let onCancel: () -> Void

    @State private var aliases = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconCircle(symbolName: isNew ? "plus" : "pencil", tone: .info, size: 28)
                Text(isNew ? "Nový pojem" : "Upravit pojem").font(.headline)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                Section {
                    TextField("Správně", text: $term.term, prompt: Text("Kubernetes, PR, Mária Kováčová"))
                    Picker("Typ", selection: $term.category) {
                        ForEach(VocabularyTerm.Category.allCases) { category in
                            Text(category.label).tag(category)
                        }
                    }
                } footer: {
                    Text("Jak se to má správně psát.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Model píše", text: $aliases, prompt: Text("kubernetis, kubernetes s"))
                } footer: {
                    Text("Chybné tvary z přepisů, oddělené čárkou.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Význam", text: $term.description, prompt: Text("pull request / PM u zákazníka"), axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("Rozvedení zkratky nebo role člověka. Dostane ho jen Claude.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Do promptu Whisperu", isOn: $term.inPrompt)
                    Toggle("Automaticky opravovat chybné tvary", isOn: $term.autoReplace)
                } footer: {
                    Text("Do promptu dávej jen vzácná slova (jména, produkty, zkratky). Automatickou opravu vypni, pokud je chybný tvar zároveň běžné slovo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Zrušit", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Přidat" : "Uložit") {
                    term.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    onSave(term)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .onAppear {
            aliases = term.aliases.joined(separator: ", ")
        }
    }
}
