import Foundation
import Testing
@testable import MeetingAssistant

struct VocabularyTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var sharedFolder: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared")
    }

    // MARK: File format

    @Test func sharedExampleDecodes() throws {
        let data = try Data(contentsOf: sharedFolder.appending(path: "vocabulary.example.json"))
        let terms = try JSONDecoder().decode(VocabularyFile.self, from: data).terms
        #expect(terms.map(\.term) == ["Kubernetes", "PR", "Mária Kováčová"])
        #expect(terms[2].category == .person)
        #expect(terms[0].inPrompt && terms[0].autoReplace)
    }

    @Test func legacyPriorityBecomesInPrompt() throws {
        let json = #"{"schemaVersion": 1, "terms": [{"term": "A", "priority": 1}, {"term": "B", "priority": 2}]}"#
        let terms = try JSONDecoder().decode(VocabularyFile.self, from: Data(json.utf8)).terms
        #expect(terms.map(\.inPrompt) == [true, false])
        #expect(terms[0].category == .term)
    }

    @Test func encodedFileHasNoInternalIDs() throws {
        let data = try JSONEncoder().encode(VocabularyFile(terms: [VocabularyTerm(term: "Jira", inPrompt: true)]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"id\""))
        #expect(!text.contains("priority"))
        #expect(text.contains("\"inPrompt\":true"))
    }

    // MARK: CSV

    @Test func csvRoundTrip() throws {
        let terms = [
            VocabularyTerm(term: "Mária Kováčová", category: .person, aliases: ["Marie", "Maria"],
                           description: "PM; \"klíčová\" osoba, zákazník", inPrompt: true, autoReplace: false),
            VocabularyTerm(term: "PR", category: .abbreviation, aliases: ["pí ár"], description: "Pull request",
                           inPrompt: true, autoReplace: true),
        ]
        let parsed = try VocabularyCSV.parse(VocabularyCSV.export(terms))
        #expect(parsed.map(\.term) == terms.map(\.term))
        #expect(parsed.map(\.aliases) == terms.map(\.aliases))
        #expect(parsed.map(\.description) == terms.map(\.description))
        #expect(parsed.map(\.category) == terms.map(\.category))
        #expect(parsed.map(\.inPrompt) == [true, true])
        #expect(parsed.map(\.autoReplace) == [false, true])
    }

    @Test func csvWithEnglishHeadersAndCommas() throws {
        let csv = "term,category,aliases,description,inPrompt,autoReplace\nKubernetes,product,\"kubernetis, kubernetes s\",Containers,true,1\n"
        let terms = try VocabularyCSV.parse(csv)
        #expect(terms.count == 1)
        #expect(terms[0].category == .product)
        #expect(terms[0].aliases == ["kubernetis", "kubernetes s"])
        #expect(terms[0].autoReplace)
    }

    @Test func csvWithoutTermColumnIsRejected() {
        #expect(throws: VocabularyCSV.ImportError.self) {
            try VocabularyCSV.parse("foo;bar\n1;2\n")
        }
    }

    // MARK: Rules

    @Test func promptFitStopsAtTheBudget() {
        let terms = (0..<300).map { VocabularyTerm(term: "Pojem\($0)", inPrompt: true) }
        let fit = VocabularyRules.promptFit(terms)
        #expect(fit.tokens <= VocabularyRules.promptTokenBudget)
        #expect(fit.fitting.count < terms.count)
        #expect(fit.fitting.contains(terms[0].id))
        #expect(!fit.fitting.contains(terms[299].id))
    }

    @Test func termsWithoutPromptDoNotCount() {
        let fit = VocabularyRules.promptFit([VocabularyTerm(term: "běžné")])
        #expect(fit.tokens == 0)
        #expect(fit.fitting.isEmpty)
    }

    @Test(arguments: [
        ("Nasadíme to do Kubernetes a kubernetes je OK.", "Kubernetes", 2),
        ("Kubernetesový cluster", "Kubernetes", 0),  // part of another word
        ("Mária Kovacova přijde", "Mária Kováčová", 1),  // diacritics-insensitive
        ("", "PR", 0),
    ])
    func occurrences(text: String, term: String, expected: Int) {
        #expect(VocabularyRules.occurrences(of: term, in: text) == expected)
    }

    // MARK: Store

    @Test func acceptAndRejectSuggestions() throws {
        let folder = try temporaryDirectory()
        let suggestions = folder.appending(path: "vocabulary-suggestions.json")
        let json = #"""
        {"schemaVersion": 1, "rejected": [], "suggestions": [
          {"term": "Grafana", "heardAs": ["grafána"], "category": "product", "description": "Dashboardy", "source": "x", "addedAt": ""},
          {"term": "Foo", "heardAs": [], "category": "term", "description": "", "source": "x", "addedAt": ""}
        ]}
        """#
        try Data(json.utf8).write(to: suggestions)
        let store = VocabularyStore(vocabularyURL: folder.appending(path: "vocabulary.json"), suggestionsURL: suggestions)
        store.load()
        #expect(store.suggestions.count == 2)

        store.accept(store.suggestions[0])
        store.reject(store.suggestions[0])

        #expect(store.terms.map(\.term) == ["Grafana"])
        #expect(store.terms[0].aliases == ["grafána"])
        #expect(store.terms[0].inPrompt)  // products are boosted by default
        #expect(store.suggestions.isEmpty)
        let saved = try JSONDecoder().decode(SuggestionsFile.self, from: Data(contentsOf: suggestions))
        #expect(saved.rejected == ["Foo"])

        // A fresh store reads the saved vocabulary.
        let reloaded = VocabularyStore(vocabularyURL: folder.appending(path: "vocabulary.json"), suggestionsURL: suggestions)
        reloaded.load()
        #expect(reloaded.terms.map(\.term) == ["Grafana"])
    }

    @Test func csvImportUpdatesExistingTerms() throws {
        let folder = try temporaryDirectory()
        let store = VocabularyStore(
            vocabularyURL: folder.appending(path: "vocabulary.json"),
            suggestionsURL: folder.appending(path: "suggestions.json"))
        store.load()
        store.upsert(VocabularyTerm(term: "Jira", description: "old"))
        let csv = folder.appending(path: "import.csv")
        try Data("Správně;Význam\njira;Issue tracker\nConfluence;Wiki\n".utf8).write(to: csv)

        #expect(try store.importCSV(from: csv) == 2)

        #expect(store.terms.map(\.term) == ["jira", "Confluence"])
        #expect(store.terms[0].description == "Issue tracker")
    }
}
