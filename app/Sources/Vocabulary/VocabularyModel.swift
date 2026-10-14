import Foundation

/// One vocabulary entry (vocabulary.json, schema: shared/vocabulary.schema.json).
///
/// Like custom vocabularies of speech-to-text services: `inPrompt` = keyterm boosting (Whisper's
/// prompt), `aliases` + `autoReplace` = custom spelling (find and replace after transcription),
/// `description` = context for the Claude cleanup.
nonisolated struct VocabularyTerm: Equatable, Identifiable, Sendable {
    enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
        case abbreviation, person, product, company, term

        var id: String { rawValue }

        var label: String {
            switch self {
            case .abbreviation: "Zkratka"
            case .person: "Jméno"
            case .product: "Produkt / nástroj"
            case .company: "Firma"
            case .term: "Odborný termín"
            }
        }

        /// Accepts both the JSON key and the Czech label (CSV edited by hand).
        init?(text: String) {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard let match = Self.allCases.first(where: { $0.rawValue == value || $0.label.lowercased() == value })
            else { return nil }
            self = match
        }
    }

    /// Only for SwiftUI lists; not stored.
    var id = UUID()
    var term: String
    var category: Category = .term
    var aliases: [String] = []
    var description = ""
    var inPrompt = false
    var autoReplace = false
}

nonisolated extension VocabularyTerm: Codable {
    enum CodingKeys: String, CodingKey {
        case term, category, aliases, description, inPrompt, autoReplace, priority
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        category = (try? c.decodeIfPresent(Category.self, forKey: .category)) ?? .term
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        // Older files had "priority" (1 = most important) instead of "inPrompt".
        let legacyPriority = try c.decodeIfPresent(Int.self, forKey: .priority)
        inPrompt = try c.decodeIfPresent(Bool.self, forKey: .inPrompt) ?? (legacyPriority == 1)
        autoReplace = try c.decodeIfPresent(Bool.self, forKey: .autoReplace) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(term, forKey: .term)
        try c.encode(category, forKey: .category)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(description, forKey: .description)
        try c.encode(inPrompt, forKey: .inPrompt)
        try c.encode(autoReplace, forKey: .autoReplace)
    }
}

/// A term proposed by the Claude cleanup, waiting for the user's decision.
nonisolated struct VocabularySuggestion: Codable, Equatable, Identifiable, Sendable {
    var term: String
    var heardAs: [String] = []
    var category: VocabularyTerm.Category = .term
    var description = ""
    /// Recording folder the suggestion came from.
    var source = ""
    var addedAt = ""

    var id: String { term.lowercased() }

    var asTerm: VocabularyTerm {
        VocabularyTerm(
            term: term, category: category, aliases: heardAs, description: description,
            // Names and abbreviations are what Whisper misses most: boost them by default.
            inPrompt: category != .term, autoReplace: false)
    }
}

nonisolated struct VocabularyFile: Codable, Sendable {
    var schemaVersion = 1
    var terms: [VocabularyTerm]
}

nonisolated struct SuggestionsFile: Codable, Sendable {
    var schemaVersion = 1
    var suggestions: [VocabularySuggestion] = []
    var rejected: [String] = []
}

/// Pure helpers, tested without files.
nonisolated enum VocabularyRules {
    /// Whisper keeps the last 224 prompt tokens; the pipeline uses up to 200.
    static let promptTokenBudget = 200
    static let promptIntro = "Na poradě padly pojmy a jména: "

    /// About 2.3 characters per Whisper token for Czech text (measured with its tokenizer).
    static func estimatedTokens(_ text: String) -> Int {
        Int(Double(text.count) / 2.3) + 1
    }

    /// Which `inPrompt` terms fit into the prompt, in vocabulary order (same rule as the pipeline).
    static func promptFit(_ terms: [VocabularyTerm]) -> (fitting: Set<UUID>, tokens: Int) {
        var selected: [String] = []
        var fitting: Set<UUID> = []
        for term in terms where term.inPrompt {
            let candidate = promptIntro + (selected + [term.term]).joined(separator: ", ") + "."
            if estimatedTokens(candidate) > promptTokenBudget { break }
            selected.append(term.term)
            fitting.insert(term.id)
        }
        let used = selected.isEmpty ? 0 : estimatedTokens(promptIntro + selected.joined(separator: ", ") + ".")
        return (fitting, used)
    }

    /// Whole-word, case- and diacritics-insensitive occurrences of `term` in `text`.
    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            let isWord = { (c: Character?) in c.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWord(before) && !isWord(after) {
                count += 1
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }
}
