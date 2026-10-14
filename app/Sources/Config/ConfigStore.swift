import Foundation

/// Loads config.json. Creates it with defaults on first launch and never overwrites an existing file
/// (the user edits it by hand until the settings GUI exists).
nonisolated enum ConfigStore {
    struct LoadResult: Sendable {
        var config: AppConfig
        /// Czech message for the menu when the file could not be used.
        var problem: String?
    }

    static func load(from url: URL = AppPaths.configFile) -> LoadResult {
        let path = url.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            let defaults = AppConfig()
            do {
                try write(defaults, to: url)
                Log.config.info("Created \(path, privacy: .public) with default values")
                return LoadResult(config: defaults, problem: nil)
            } catch {
                Log.config.error("Cannot create \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                return LoadResult(config: defaults, problem: "Nejde vytvořit config.json, používám výchozí hodnoty.")
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(AppConfig.self, from: data).sanitized()
            Log.config.info("Loaded \(path, privacy: .public)")
            return LoadResult(config: config, problem: nil)
        } catch {
            Log.config.error("Invalid \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return LoadResult(
                config: AppConfig(),
                problem: "config.json je neplatný, používám výchozí hodnoty. Oprav ho a dej „Znovu načíst nastavení“."
            )
        }
    }

    static func write(_ config: AppConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // .atomic = write to a temp file and rename, so the pipeline never reads half a file.
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
