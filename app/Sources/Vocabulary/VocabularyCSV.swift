import Foundation

/// CSV import/export of the vocabulary, for editing in Numbers or Excel, backups and sharing
/// with colleagues (a table per entry, like the AWS Transcribe custom vocabulary table).
///
/// Columns: Správně;Typ;Model píše;Význam;Do promptu;Automaticky opravovat
/// Semicolon-separated (the default of Czech Excel), UTF-8 with BOM, aliases separated by ", ".
nonisolated enum VocabularyCSV {
    static let header = ["Správně", "Typ", "Model píše", "Význam", "Do promptu", "Automaticky opravovat"]
    static let delimiter: Character = ";"

    enum ImportError: LocalizedError {
        case missingTermColumn

        var errorDescription: String? {
            "Soubor nemá sloupec „Správně“ (nebo „term“) v prvním řádku."
        }
    }

    static func export(_ terms: [VocabularyTerm]) -> String {
        let rows = [header] + terms.map { term in
            [
                term.term, term.category.label, term.aliases.joined(separator: ", "), term.description,
                term.inPrompt ? "ano" : "ne", term.autoReplace ? "ano" : "ne",
            ]
        }
        return "\u{FEFF}" + rows.map { $0.map(quote).joined(separator: String(delimiter)) }.joined(separator: "\r\n") + "\r\n"
    }

    /// Reads exported (or hand-made) CSV. Column order is taken from the header, Czech or English
    /// names, comma or semicolon as separator.
    static func parse(_ text: String) throws -> [VocabularyTerm] {
        let content = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let firstLine = content.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = firstLine.filter { $0 == ";" }.count >= firstLine.filter { $0 == "," }.count ? ";" : ","
        let rows = rows(content, separator: separator)
        guard let head = rows.first else { return [] }

        let names = head.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ candidates: String...) -> Int? {
            names.firstIndex { candidates.contains($0) }
        }
        guard let termColumn = column("správně", "spravne", "term", "phrase", "displayas") else {
            throw ImportError.missingTermColumn
        }
        let category = column("typ", "category")
        let aliases = column("model píše", "aliases", "soundslike")
        let meaning = column("význam", "description")
        let prompt = column("do promptu", "inprompt")
        let replace = column("automaticky opravovat", "autoreplace")

        func value(_ row: [String], _ index: Int?) -> String {
            guard let index, index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespaces)
        }
        func flag(_ text: String) -> Bool {
            ["ano", "yes", "true", "1", "x", "✓"].contains(text.lowercased())
        }

        return rows.dropFirst().compactMap { row in
            let term = value(row, termColumn)
            guard !term.isEmpty else { return nil }
            return VocabularyTerm(
                term: term,
                category: VocabularyTerm.Category(text: value(row, category)) ?? .term,
                aliases: value(row, aliases).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                description: value(row, meaning),
                inPrompt: flag(value(row, prompt)),
                autoReplace: flag(value(row, replace))
            )
        }
    }

    /// RFC 4180: fields with the separator, quotes or line breaks are quoted, quotes doubled.
    private static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "," }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func rows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let character = pending {
                pending = nil
                return character
            }
            return iterator.next()
        }

        while let character = next() {
            if inQuotes {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == separator {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) {
                    rows.append(row)
                }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) {
            rows.append(row)
        }
        return rows
    }
}
