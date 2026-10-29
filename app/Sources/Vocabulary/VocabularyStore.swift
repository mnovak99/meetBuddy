import Foundation
import Observation

/// The vocabulary shown in the Slovník section: entries, the suggestion queue from the pipeline and
/// how often each term appeared in recent transcripts.
@Observable
final class VocabularyStore {
    private(set) var terms: [VocabularyTerm] = []
    private(set) var suggestions: [VocabularySuggestion] = []
    /// Occurrences per term (lowercased) in transcripts of the last `occurrenceDays` days.
    private(set) var occurrences: [String: Int] = [:]
    private(set) var problem: String?

    static let occurrenceDays = 30

    @ObservationIgnored let vocabularyURL: URL
    @ObservationIgnored let suggestionsURL: URL
    /// Incremented by every `refreshOccurrences`; a count finished for an older call is dropped.
    @ObservationIgnored private var occurrenceGeneration = 0

    init(
        vocabularyURL: URL = AppPaths.supportDirectory.appending(path: "vocabulary.json"),
        suggestionsURL: URL = AppPaths.supportDirectory.appending(path: "vocabulary-suggestions.json")
    ) {
        self.vocabularyURL = vocabularyURL
        self.suggestionsURL = suggestionsURL
    }

    var promptFit: (fitting: Set<UUID>, tokens: Int) {
        VocabularyRules.promptFit(terms)
    }

    func load() {
        problem = nil
        if let data = try? Data(contentsOf: vocabularyURL) {
            do {
                terms = try JSONDecoder().decode(VocabularyFile.self, from: data).terms
            } catch {
                problem = "vocabulary.json nejde přečíst: \(error.localizedDescription)"
                Log.app.error("Invalid vocabulary.json: \(String(describing: error), privacy: .public)")
            }
        } else {
            terms = []
        }
        reloadSuggestions()
    }

    /// The pipeline adds suggestions after each meeting; called when processing finishes.
    func reloadSuggestions() {
        suggestions = readSuggestions().suggestions
    }

    // MARK: - Editing (every change is saved right away)

    /// Adds a new term or replaces the one with the same id. A new term whose name already exists
    /// (any case) updates that entry instead of adding a second one: „Přidat“ with a known term,
    /// or accepting a suggestion for a term that is in the vocabulary already. The new values
    /// win, but nothing the user already had is lost: aliases are merged, an empty description
    /// keeps the old one and `inPrompt` / `autoReplace` stay on when they were on (see `merge`).
    func upsert(_ term: VocabularyTerm) {
        var clean = term
        clean.term = term.term.trimmingCharacters(in: .whitespaces)
        clean.aliases = term.aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.term.isEmpty else { return }
        if let index = terms.firstIndex(where: { $0.id == clean.id }) {
            terms[index] = clean
        } else if let index = terms.firstIndex(where: { $0.term.lowercased() == clean.term.lowercased() }) {
            terms[index] = Self.merge(clean, into: terms[index])
        } else {
            terms.append(clean)
        }
        save()
    }

    /// `existing` updated with `update`: the id stays (SwiftUI selection, no duplicate entry),
    /// the new spelling, category and flags apply, aliases are merged and an empty new description
    /// keeps the old one.
    nonisolated static func merge(_ update: VocabularyTerm, into existing: VocabularyTerm) -> VocabularyTerm {
        var merged = update
        merged.id = existing.id
        let known = Set(existing.aliases.map { $0.lowercased() })
        merged.aliases = existing.aliases + update.aliases.filter { !known.contains($0.lowercased()) }
        if merged.description.isEmpty {
            merged.description = existing.description
        }
        merged.inPrompt = existing.inPrompt || update.inPrompt
        merged.autoReplace = existing.autoReplace || update.autoReplace
        return merged
    }

    func delete(_ ids: Set<UUID>) {
        terms.removeAll { ids.contains($0.id) }
        save()
    }

    /// Accepts a suggestion as it is, or as edited by the user (`term`).
    func accept(_ suggestion: VocabularySuggestion, as term: VocabularyTerm? = nil) {
        upsert(term ?? suggestion.asTerm)
        updateSuggestions { file in
            file.suggestions.removeAll { $0.id == suggestion.id }
        }
    }

    /// Rejects a suggestion; the pipeline will not propose it again.
    func reject(_ suggestion: VocabularySuggestion) {
        updateSuggestions { file in
            file.suggestions.removeAll { $0.id == suggestion.id }
            if !file.rejected.contains(where: { $0.lowercased() == suggestion.id }) {
                file.rejected.append(suggestion.term)
            }
        }
    }

    // MARK: - CSV

    /// Imports a CSV: known terms (same spelling, any case) are updated, new ones added.
    @discardableResult
    func importCSV(from url: URL) throws -> Int {
        let imported = try VocabularyCSV.parse(String(contentsOf: url, encoding: .utf8))
        for var term in imported {
            if let existing = terms.first(where: { $0.term.lowercased() == term.term.lowercased() }) {
                term.id = existing.id
            }
            if let index = terms.firstIndex(where: { $0.id == term.id }) {
                terms[index] = term
            } else {
                terms.append(term)
            }
        }
        save()
        return imported.count
    }

    func exportCSV(to url: URL) throws {
        try Data(VocabularyCSV.export(terms).utf8).write(to: url, options: .atomic)
    }

    // MARK: - Occurrences

    /// Counts the terms in the transcripts of recent recordings (cleaned ones when available).
    /// Reading and searching the transcripts can take a while, so it runs off the main thread;
    /// `occurrences` is updated when done. A newer call wins: the result of an older one still
    /// running is dropped. The returned task lets tests wait for the result.
    @discardableResult
    func refreshOccurrences(
        recordingsDirectory: URL = RecordingFolder.recordingsDirectory, now: Date = .now
    ) -> Task<Void, Never> {
        occurrenceGeneration += 1
        let generation = occurrenceGeneration
        let names = terms.map(\.term)
        let since = now.addingTimeInterval(-Double(Self.occurrenceDays) * 24 * 3600)
        // Task.detached = not on the main actor; only plain values (paths, strings) go in.
        return Task.detached(priority: .utility) {
            let texts = Self.transcriptTexts(in: recordingsDirectory, since: since)
            var counts: [String: Int] = [:]
            for name in names {
                counts[name.lowercased()] = texts.reduce(0) { $0 + VocabularyRules.occurrences(of: name, in: $1) }
            }
            // Back to the main actor to touch the observable state.
            await MainActor.run { [counts] in
                guard self.occurrenceGeneration == generation else { return }
                self.occurrences = counts
            }
        }
    }

    nonisolated static func transcriptTexts(in recordingsDirectory: URL, since: Date) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return folders.compactMap { folder in
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (modified ?? .distantPast) >= since else { return nil }
            for (file, key) in [("cleaned.json", "lines"), ("transcript.json", "segments")] {
                guard let data = try? Data(contentsOf: folder.appending(path: file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json[key] as? [[String: Any]]
                else { continue }
                return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return nil
        }
    }

    // MARK: - Files

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: vocabularyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(VocabularyFile(terms: terms)).write(to: vocabularyURL, options: .atomic)
            problem = nil
        } catch {
            problem = "Slovník nejde uložit: \(error.localizedDescription)"
            Log.app.error("Cannot save vocabulary.json: \(String(describing: error), privacy: .public)")
        }
    }

    private func readSuggestions() -> SuggestionsFile {
        guard let data = try? Data(contentsOf: suggestionsURL),
              let file = try? JSONDecoder().decode(SuggestionsFile.self, from: data)
        else { return SuggestionsFile() }
        return file
    }

    /// Re-reads the file right before writing: the pipeline may have added suggestions meanwhile.
    private func updateSuggestions(_ change: (inout SuggestionsFile) -> Void) {
        var file = readSuggestions()
        change(&file)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(file).write(to: suggestionsURL, options: .atomic)
        } catch {
            problem = "Návrhy nejde uložit: \(error.localizedDescription)"
        }
        suggestions = file.suggestions
    }
}
