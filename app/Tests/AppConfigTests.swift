import Foundation
import Testing
@testable import MeetingAssistant

struct AppConfigTests {
    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try decode("{}") == AppConfig())
    }

    @Test func missingKeysKeepDefaults() throws {
        let config = try decode(#"{"pollIntervalSeconds": 5, "userName": "Matěj"}"#)
        #expect(config.pollIntervalSeconds == 5)
        #expect(config.userName == "Matěj")
        #expect(config.detectionConfirmSeconds == AppConfig().detectionConfirmSeconds)
    }

    @Test func unknownSourcesAreSkipped() throws {
        #expect(try decode(#"{"enabledSources": ["teams", "zoom"]}"#).enabledSources == [.teams])
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let config = try decode(#"{"pollIntervalSeconds": 0, "endSilenceMinutes": 1000}"#).sanitized()
        #expect(config.pollIntervalSeconds == 1)
        #expect(config.endSilenceMinutes == 60)
    }

    @Test func sharedExampleMatchesSwiftDefaults() throws {
        // app/Tests/AppConfigTests.swift → repo root → shared/config.example.json
        let example = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/config.example.json")
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: example))
        #expect(config == AppConfig())
    }

    // MARK: ConfigStore

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MeetingAssistantTests-\(UUID().uuidString)")
            .appending(path: "config.json")
    }

    @Test func missingFileIsCreatedWithDefaults() throws {
        let url = temporaryConfigURL()
        let result = ConfigStore.load(from: url)
        #expect(result.config == AppConfig())
        #expect(result.problem == nil)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)) == AppConfig())
    }

    @Test func invalidFileGivesDefaultsAndAProblem() throws {
        let url = temporaryConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        let result = ConfigStore.load(from: url)
        #expect(result.config == AppConfig())
        #expect(result.problem != nil)
        // The broken file is left for the user to fix, never overwritten.
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    // MARK: Empty settings are filled in automatically

    @Test func emptyNameComesFromTheMacAccount() {
        #expect(!AppConfig().effectiveUserName.isEmpty)
        var config = AppConfig()
        config.userName = "Matej"
        #expect(config.effectiveUserName == "Matej")
    }

    @Test func uvIsFoundInTheUsualPlaces() {
        let config = AppConfig()
        let found = config.resolvedUVPath(fileExists: { $0 == "/opt/homebrew/bin/uv" })
        #expect(found == "/opt/homebrew/bin/uv")
        var configured = AppConfig()
        configured.uvPath = "~/bin/uv"
        #expect(configured.resolvedUVPath(fileExists: { _ in false }).hasSuffix("/bin/uv"))
        #expect(!configured.resolvedUVPath().contains("~"))
    }

    @Test func pipelineDefaultsToTheRepositoryTheAppWasBuiltFrom() {
        // The test host is the app built from this repository: app/../pipeline.
        let path = AppConfig().resolvedPipelinePath()
        #expect(path.hasSuffix("/pipeline"))
        #expect(!path.contains(".."))
        #expect(FileManager.default.fileExists(atPath: path + "/pyproject.toml"))
    }
}

