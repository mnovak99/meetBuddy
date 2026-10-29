import AppKit
import Foundation
import Observation
import ServiceManagement

/// What the dashboard checklist shows: one row per thing the app needs to work.
nonisolated struct HealthItem: Identifiable, Equatable, Sendable {
    enum State: Sendable {
        case ok, warning, error, info
    }

    enum Action: Equatable, Sendable {
        case permission(PermissionItem.Kind)
        case openSettings(SettingsTab)
        case relaunch
        case openURL(String)
    }

    var id: String
    var title: String
    var detail: String
    var state: State
    var symbolName: String
    var action: Action?
    var actionTitle: String?

    var isProblem: Bool { state == .warning || state == .error }
}

/// Tools and secrets outside the app: found on disk, so the checks run off the main thread
/// and are refreshed on demand (window opened, settings changed), not on every poll.
@Observable
final class EnvironmentStatus {
    private(set) var uvPath: String?
    private(set) var claudePath: String?
    private(set) var pipelineFound = false
    /// `uv sync` has been run (pipeline/.venv exists).
    private(set) var pipelineInstalled = false
    private(set) var huggingFaceTokenStored = false
    private(set) var vaultExists = false
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var refreshedAt: Date?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func refresh(config: AppConfig) {
        refreshTask?.cancel()
        let uv = config.resolvedUVPath()
        let pipeline = config.resolvedPipelinePath()
        let vault = config.vaultURL
        refreshTask = Task {
            let result = await Task.detached(priority: .utility) {
                let manager = FileManager.default
                return Snapshot(
                    uvPath: manager.isExecutableFile(atPath: uv) ? uv : nil,
                    claudePath: AppConfig.resolvedClaudePath(),
                    pipelineFound: manager.fileExists(atPath: pipeline + "/pyproject.toml"),
                    pipelineInstalled: manager.fileExists(atPath: pipeline + "/.venv/bin/python"),
                    tokenStored: HuggingFaceToken.isStored,
                    vaultExists: vault.map { manager.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
                )
            }.value
            guard !Task.isCancelled else { return }
            uvPath = result.uvPath
            claudePath = result.claudePath
            pipelineFound = result.pipelineFound
            pipelineInstalled = result.pipelineInstalled
            huggingFaceTokenStored = result.tokenStored
            vaultExists = result.vaultExists
            loginItemStatus = LoginItem.status
            refreshedAt = .now
        }
    }

    /// Called after the token was stored from the UI.
    func tokenStored() {
        huggingFaceTokenStored = true
    }

    func loginItemChanged() {
        loginItemStatus = LoginItem.status
    }

    private struct Snapshot: Sendable {
        var uvPath: String?
        var claudePath: String?
        var pipelineFound: Bool
        var pipelineInstalled: Bool
        var tokenStored: Bool
        var vaultExists: Bool
    }
}

extension AppModel {
    /// The dashboard checklist: permissions, vault, tools, token, login item. Problems first.
    var healthItems: [HealthItem] {
        var items: [HealthItem] = []
        for permission in permissions.items {
            let (state, detail, actionTitle): (HealthItem.State, String, String?) = switch permission.state {
            case .granted: (.ok, "Povoleno", nil)
            case .unknown: (.info, permission.purpose, nil)
            case .notDetermined: (.warning, "Zatím nepovoleno. " + permission.purpose, "Povolit…")
            case .denied: (.error, "Nepovoleno. " + permission.purpose, "Nastavení systému…")
            case .needsRestart: (.warning, "Povoleno, projeví se po restartu appky.", "Restartovat appku")
            }
            items.append(HealthItem(
                id: "permission-\(permission.kind.rawValue)", title: permission.title, detail: detail,
                state: state, symbolName: permission.symbolName,
                action: .permission(permission.kind), actionTitle: actionTitle))
        }
        if config.obsidianVaultPath.isEmpty {
            items.append(HealthItem(
                id: "vault", title: "Obsidian vault", detail: "Není vybraný: poznámky nevzniknou.",
                state: .error, symbolName: "folder.badge.questionmark",
                action: .openSettings(.general), actionTitle: "Vybrat…"))
        } else if !environment.vaultExists {
            items.append(HealthItem(
                id: "vault", title: "Obsidian vault", detail: "Složka \(config.obsidianVaultPath) neexistuje.",
                state: .error, symbolName: "folder.badge.questionmark",
                action: .openSettings(.general), actionTitle: "Vybrat…"))
        } else {
            items.append(HealthItem(
                id: "vault", title: "Obsidian vault", detail: config.obsidianVaultPath,
                state: .ok, symbolName: "folder", action: .openSettings(.general), actionTitle: nil))
        }
        items.append(HealthItem(
            id: "token", title: "Hugging Face token",
            detail: environment.huggingFaceTokenStored
                ? "Uložen v Klíčence." : "Chybí: mluvčí se nerozliší (poznámka vznikne bez jmen).",
            state: environment.huggingFaceTokenStored ? .ok : .warning, symbolName: "key",
            action: .openSettings(.ai), actionTitle: environment.huggingFaceTokenStored ? nil : "Uložit token…"))
        items.append(HealthItem(
            id: "claude", title: "Claude Code",
            detail: environment.claudePath.map { "Nalezen: \($0)" }
                ?? "Příkaz claude nenalezen (~/.local/bin). Bez něj vznikne poznámka jen s přepisem.",
            state: environment.claudePath == nil ? .warning : .ok, symbolName: "sparkles",
            action: environment.claudePath == nil ? .openURL("https://docs.claude.com/en/docs/claude-code/setup") : nil,
            actionTitle: environment.claudePath == nil ? "Jak nainstalovat" : nil))
        items.append(HealthItem(
            id: "uv", title: "uv a pipeline",
            detail: uvDetail,
            state: environment.uvPath != nil && environment.pipelineFound && environment.pipelineInstalled ? .ok : .error,
            symbolName: "terminal", action: .openSettings(.advanced),
            actionTitle: environment.uvPath != nil && environment.pipelineFound && environment.pipelineInstalled ? nil : "Nastavit…"))
        let login: (HealthItem.State, String, String?) = switch environment.loginItemStatus {
        case .enabled: (.ok, "Zapnuto.", nil)
        case .requiresApproval: (.warning, "Čeká na schválení v Nastavení systému → Přihlašovací položky.", "Otevřít…")
        default: (.info, "Vypnuto. Appka se nespustí sama po přihlášení.", "Zapnout")
        }
        items.append(HealthItem(
            id: "login", title: "Spouštět po přihlášení", detail: login.1, state: login.0,
            symbolName: "power", action: .openSettings(.general), actionTitle: login.2))
        return items.sorted { rank($0.state) < rank($1.state) }
    }

    private var uvDetail: String {
        var parts: [String] = []
        parts.append(environment.uvPath.map { "uv: \($0)" } ?? "uv nenalezen")
        if !environment.pipelineFound {
            parts.append("složka pipeline nenalezena (\(config.resolvedPipelinePath()))")
        } else if !environment.pipelineInstalled {
            parts.append("pipeline není nainstalovaná (spusť `uv sync` ve složce pipeline)")
        } else {
            parts.append("pipeline připravena")
        }
        return parts.joined(separator: " · ")
    }

    private func rank(_ state: HealthItem.State) -> Int {
        switch state {
        case .error: 0
        case .warning: 1
        case .info: 2
        case .ok: 3
        }
    }

    /// Performs a checklist action (permission prompt, settings tab, relaunch, link).
    func perform(_ action: HealthItem.Action) {
        switch action {
        case .permission(let kind):
            permissions.resolve(kind)
        case .openSettings(let tab):
            openSettings(tab)
        case .relaunch:
            AppRelauncher.relaunch()
        case .openURL(let string):
            if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
