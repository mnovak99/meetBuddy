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

    /// Adds a new term or replaces the one with the same id.
    func upsert(_ term: VocabularyTerm) {
        var clean = term
        clean.term = term.term.trimmingCharacters(in: .whitespaces)
        clean.aliases = term.aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.term.isEmpty else { return }
        if let index = terms.firstIndex(where: { $0.id == clean.id }) {
            terms[index] = clean
        } else {
            terms.append(clean)
        }
        save()
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
    func refreshOccurrences(recordingsDirectory: URL = RecordingFolder.recordingsDirectory, now: Date = .now) {
        let since = now.addingTimeInterval(-Double(Self.occurrenceDays) * 24 * 3600)
        let texts = Self.transcriptTexts(in: recordingsDirectory, since: since)
        var counts: [String: Int] = [:]
        for term in terms {
            counts[term.term.lowercased()] = texts.reduce(0) { $0 + VocabularyRules.occurrences(of: term.term, in: $1) }
        }
        occurrences = counts
    }

    static func transcriptTexts(in recordingsDirectory: URL, since: Date) -> [String] {
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
